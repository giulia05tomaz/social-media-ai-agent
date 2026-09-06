"""Interchangeable immutable media storage providers for publication assets."""
from __future__ import annotations

from dataclasses import dataclass
from hashlib import sha256
from pathlib import Path
from time import sleep
from typing import Any, Callable, Protocol
from urllib.parse import quote, urlparse
from urllib.request import Request, urlopen
import mimetypes
import uuid


class MediaStorageError(RuntimeError):
    pass


class MediaStorageProvider(Protocol):
    def upload_file(self, path: Path, object_key: str, expected_checksum: str) -> dict[str, Any]: ...
    def verify_public_url(self, public_url: str, expected_checksum: str) -> dict[str, Any]: ...
    def delete_object(self, object_key: str) -> None: ...
    def get_public_url(self, object_key: str) -> str: ...


def file_sha256(path: Path) -> str:
    digest = sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest().upper()


def validate_final_art_path(project_root: Path, client_id: str, stored_path: str) -> Path:
    if Path(stored_path).is_absolute() or ".." in Path(stored_path).parts:
        raise MediaStorageError("FINAL_ART_PATH_NOT_ALLOWED")
    candidate = (project_root / stored_path).resolve()
    allowed_root = (project_root / "assets" / "generated" / client_id).resolve()
    try:
        relative = candidate.relative_to(allowed_root)
    except ValueError as exc:
        raise MediaStorageError("FINAL_ART_PATH_NOT_ALLOWED") from exc
    if "rendered" not in relative.parts or any(part.lower() in {"source", "spec", "specs"} for part in relative.parts):
        raise MediaStorageError("FINAL_ART_PATH_NOT_ALLOWED")
    if not candidate.is_file():
        raise MediaStorageError("FINAL_ART_MISSING")
    return candidate


@dataclass
class LocalMediaStorageProvider:
    project_root: Path

    def upload_file(self, path: Path, object_key: str, expected_checksum: str) -> dict[str, Any]:
        actual = file_sha256(path)
        if actual != expected_checksum.upper():
            raise MediaStorageError("MEDIA_CHECKSUM_MISMATCH")
        return {"object_key": object_key, "checksum": actual, "size_bytes": path.stat().st_size}

    def verify_public_url(self, public_url: str, expected_checksum: str) -> dict[str, Any]:
        raise MediaStorageError("LOCAL_STORAGE_NOT_PUBLIC")

    def delete_object(self, object_key: str) -> None:
        raise MediaStorageError("LOCAL_DELETE_NOT_SUPPORTED")

    def get_public_url(self, object_key: str) -> str:
        raise MediaStorageError("LOCAL_STORAGE_NOT_PUBLIC")


@dataclass
class CloudflareR2StorageProvider:
    bucket: str
    endpoint: str
    public_base_url: str
    access_key_id: str
    secret_access_key: str
    max_attempts: int = 3
    retry_seconds: float = 2.0
    cache_control: str = "public, max-age=604800, immutable"
    s3_client: Any | None = None
    opener: Callable[..., Any] = urlopen

    def __post_init__(self) -> None:
        if not all((self.bucket, self.endpoint, self.public_base_url, self.access_key_id, self.secret_access_key)):
            raise MediaStorageError("R2_CREDENTIALS_MISSING")
        parsed = urlparse(self.public_base_url)
        if parsed.scheme != "https" or parsed.query or parsed.fragment:
            raise MediaStorageError("R2_PUBLIC_BASE_URL_INVALID")
        if self.s3_client is None:
            try:
                import boto3
            except ImportError as exc:  # pragma: no cover - container owns the dependency
                raise MediaStorageError("BOTO3_NOT_AVAILABLE") from exc
            self.s3_client = boto3.client(
                "s3", region_name="auto", endpoint_url=self.endpoint,
                aws_access_key_id=self.access_key_id,
                aws_secret_access_key=self.secret_access_key,
            )

    @staticmethod
    def build_object_key(client_id: str, checksum: str, now_parts: tuple[int, int], random_id: str | None = None) -> str:
        normalized_client = client_id.strip().lower()
        if not normalized_client or any(char not in "abcdefghijklmnopqrstuvwxyz0123456789-_" for char in normalized_client):
            raise MediaStorageError("CLIENT_ID_INVALID")
        year, month = now_parts
        opaque = random_id or str(uuid.uuid4())
        return f"{normalized_client}/{year:04d}/{month:02d}/{opaque}-{checksum[:12].lower()}/final.png"

    @staticmethod
    def _validate_object_key(object_key: str) -> None:
        path = Path(object_key)
        if path.is_absolute() or ".." in path.parts or "\\" in object_key or not object_key.endswith("/final.png"):
            raise MediaStorageError("R2_OBJECT_KEY_INVALID")

    def connection_ok(self) -> bool:
        self.s3_client.head_bucket(Bucket=self.bucket)
        return True

    def get_public_url(self, object_key: str) -> str:
        self._validate_object_key(object_key)
        encoded = "/".join(quote(part, safe="-_.~") for part in object_key.split("/"))
        return f"{self.public_base_url.rstrip('/')}/{encoded}"

    @staticmethod
    def _is_retryable(exc: Exception) -> bool:
        response = getattr(exc, "response", None) or {}
        status = response.get("ResponseMetadata", {}).get("HTTPStatusCode")
        return status is not None and int(status) >= 500

    def upload_file(self, path: Path, object_key: str, expected_checksum: str) -> dict[str, Any]:
        self._validate_object_key(object_key)
        actual = file_sha256(path)
        if actual != expected_checksum.upper():
            raise MediaStorageError("MEDIA_CHECKSUM_MISMATCH")
        content_type = mimetypes.guess_type(path.name)[0]
        if content_type != "image/png":
            raise MediaStorageError("MEDIA_CONTENT_TYPE_UNSUPPORTED")
        body = path.read_bytes()
        for attempt in range(1, self.max_attempts + 1):
            try:
                self.s3_client.put_object(
                    Bucket=self.bucket, Key=object_key, Body=body,
                    ContentType=content_type, CacheControl=self.cache_control,
                    Metadata={"sha256": actual.lower()},
                )
                break
            except Exception as exc:
                if attempt >= self.max_attempts or not self._is_retryable(exc):
                    raise MediaStorageError("R2_UPLOAD_FAILED") from exc
                sleep(self.retry_seconds)
        head = self.head_object(object_key)
        return {
            "object_key": object_key,
            "public_url": self.get_public_url(object_key),
            "checksum": actual,
            "size_bytes": len(body),
            "content_type": content_type,
            "head_content_type": head.get("ContentType"),
            "head_content_length": head.get("ContentLength"),
        }

    def head_object(self, object_key: str) -> dict[str, Any]:
        self._validate_object_key(object_key)
        return self.s3_client.head_object(Bucket=self.bucket, Key=object_key)

    def verify_public_url(self, public_url: str, expected_checksum: str) -> dict[str, Any]:
        parsed = urlparse(public_url)
        base = urlparse(self.public_base_url)
        if parsed.scheme != "https" or parsed.netloc != base.netloc or parsed.query or parsed.fragment:
            raise MediaStorageError("MEDIA_PUBLIC_URL_INVALID")
        request = Request(public_url, method="GET", headers={"User-Agent": "social-media-ai-agent-phase83/1"})
        with self.opener(request, timeout=30) as response:
            body = response.read()
            status = response.status
            content_type = response.headers.get_content_type()
            content_length = response.headers.get("Content-Length")
        remote_checksum = sha256(body).hexdigest().upper()
        if status != 200 or content_type != "image/png":
            raise MediaStorageError("MEDIA_PUBLIC_HTTP_INVALID")
        if remote_checksum != expected_checksum.upper():
            raise MediaStorageError("MEDIA_REMOTE_CHECKSUM_MISMATCH")
        return {
            "status": status, "content_type": content_type,
            "content_length": int(content_length or len(body)),
            "checksum": remote_checksum,
        }

    def delete_object(self, object_key: str) -> None:
        self._validate_object_key(object_key)
        self.s3_client.delete_object(Bucket=self.bucket, Key=object_key)
