"""Internal n8n-controlled publication runtime for Phase 8.3.1.

This service can prepare a real Buffer mutation, but cannot send it. The live
publishing path is intentionally absent from the HTTP API in this phase.
"""
from __future__ import annotations

from datetime import datetime, timezone
from hashlib import sha256
import json
import os
from pathlib import Path
import re
import secrets
import struct
from time import sleep
from typing import Any, Literal
from uuid import UUID

import psycopg
from fastapi import FastAPI, Header, HTTPException
from psycopg.rows import dict_row
from pydantic import BaseModel, ConfigDict, field_validator

from .buffer_client import BufferApiError, BufferApiUncertainError, BufferClient
from .storage import CloudflareR2StorageProvider, MediaStorageError, file_sha256, validate_final_art_path


app = FastAPI(title="Internal Publication Service", docs_url=None, redoc_url=None)
INTERNAL_KEY = os.environ["PUBLICATION_SERVICE_INTERNAL_KEY"]
PROJECT_ROOT = Path(os.getenv("PROJECT_ROOT", "/data"))
ENV_REFERENCE = re.compile(r"^env:([A-Z][A-Z0-9_]*)$")


class PublicationRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    schedule_id: str
    client_id: str
    content_id: str
    version_id: str
    platform: Literal["instagram", "tiktok"]

    @field_validator("schedule_id", "version_id")
    @classmethod
    def valid_uuid(cls, value: str) -> str:
        UUID(value)
        return value

    @field_validator("client_id")
    @classmethod
    def valid_client_id(cls, value: str) -> str:
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}", value):
            raise ValueError("CLIENT_ID_INVALID")
        return value


class LivePublicationRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    publication_job_id: str

    @field_validator("publication_job_id")
    @classmethod
    def valid_job_id(cls, value: str) -> str:
        UUID(value)
        return value

def required_env(name: str) -> str:
    value = os.getenv(name, "").strip()
    if not value:
        raise RuntimeError(f"{name}_MISSING")
    return value


def configured_target_username() -> str:
    return required_env("FIRST_LIVE_TARGET_USERNAME").lstrip("@").lower()


def flag(name: str, default: str) -> bool:
    return os.getenv(name, default).strip().lower() == "true"


def assert_dry_run_runtime() -> None:
    checks = {
        "DEMO_MODE_REQUIRED": flag("DEMO_MODE", "true"),
        "LIVE_MODE_MUST_BE_FALSE": not flag("LIVE_MODE", "false"),
        "SOCIAL_PUBLISH_PROVIDER_MUST_BE_MOCK": os.getenv("SOCIAL_PUBLISH_PROVIDER", "mock").lower() == "mock",
        "BUFFER_PUBLISH_MUST_BE_DISABLED": not flag("BUFFER_PUBLISH_ENABLED", "false"),
        "BUFFER_DRY_RUN_REQUIRED": flag("BUFFER_DRY_RUN", "true"),
        "PUBLICATION_WORKER_MUST_BE_DISABLED": not flag("PUBLICATION_WORKER_ENABLED", "false"),
        "INSTAGRAM_PUBLISH_MUST_BE_DISABLED": not flag("INSTAGRAM_PUBLISH_ENABLED", "false"),
    }
    for error, valid in checks.items():
        if not valid:
            raise RuntimeError(error)


def assert_live_runtime() -> None:
    checks = {
        "DEMO_MODE_MUST_BE_FALSE": not flag("DEMO_MODE", "true"),
        "LIVE_MODE_REQUIRED": flag("LIVE_MODE", "false"),
        "SOCIAL_PUBLISH_PROVIDER_MUST_BE_BUFFER": os.getenv("SOCIAL_PUBLISH_PROVIDER", "mock").lower() == "buffer",
        "BUFFER_PUBLISH_MUST_BE_ENABLED": flag("BUFFER_PUBLISH_ENABLED", "false"),
        "BUFFER_DRY_RUN_MUST_BE_FALSE": not flag("BUFFER_DRY_RUN", "true"),
        "PUBLICATION_WORKER_MUST_BE_DISABLED": not flag("PUBLICATION_WORKER_ENABLED", "false"),
        "INSTAGRAM_PUBLISH_MUST_BE_DISABLED": not flag("INSTAGRAM_PUBLISH_ENABLED", "false"),
    }
    for error, valid in checks.items():
        if not valid:
            raise RuntimeError(error)


def assert_preparation_runtime() -> None:
    """Allow non-publishing preparation in either strict safe mode.

    The preparation and preflight paths only upload/verify the approved media
    and build a Buffer dry-run payload. They never instantiate a live Buffer
    client. Supporting the live-one-shot runtime here lets a single n8n demo
    execution prepare, authorize and then publish one guarded job.
    """
    try:
        assert_dry_run_runtime()
    except RuntimeError:
        assert_live_runtime()


def runtime_mode() -> str:
    try:
        assert_dry_run_runtime()
        return "dry-run"
    except RuntimeError:
        assert_live_runtime()
        return "live-one-shot"


def build_social_post_text(caption: str, hashtags: list[str], platform: str) -> str:
    """Preserve approved copy and append only approved, non-duplicated hashtags."""
    if platform.lower() != "instagram":
        raise RuntimeError("PUBLICATION_PLATFORM_NOT_AUTHORIZED")
    approved_caption = (caption or "").strip()
    if not approved_caption:
        raise RuntimeError("APPROVED_CAPTION_MISSING")
    unique: list[str] = []
    seen: set[str] = set()
    for item in hashtags or []:
        tag = str(item).strip()
        if not tag:
            continue
        key = tag.casefold()
        if key in seen:
            continue
        seen.add(key)
        if re.search(rf"(?<!\w){re.escape(tag)}(?!\w)", approved_caption, re.IGNORECASE):
            continue
        unique.append(tag)
    result = approved_caption if not unique else f"{approved_caption}\n\n{' '.join(unique)}"
    if len(result) > 2200:
        raise RuntimeError("INSTAGRAM_CAPTION_TOO_LONG")
    return result


def validate_png(path: Path, expected_width: int, expected_height: int) -> tuple[int, int]:
    with path.open("rb") as source:
        header = source.read(24)
    if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
        raise MediaStorageError("FINAL_ART_PNG_INVALID")
    width, height = struct.unpack(">II", header[16:24])
    if width != expected_width or height != expected_height:
        raise MediaStorageError("FINAL_ART_DIMENSIONS_MISMATCH")
    return width, height


def final_payload_hash(payload: dict[str, Any]) -> str:
    media = payload["media"][0]
    canonical = {
        "provider": "buffer",
        "platform": payload["platform"],
        "provider_account_id": payload["provider_account_id"],
        "text": payload["caption"],
        "media_checksum": media["checksum"].upper(),
        "media_url": media["url"],
        "mode": payload["provider_mode"],
        "scheduling_type": payload["scheduling_type"],
        "instagram_type": payload.get("instagram_type"),
        "should_share_to_feed": payload.get("should_share_to_feed"),
        "ai_generated": payload.get("ai_generated"),
    }
    return sha256(json.dumps(canonical, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()


def connection() -> psycopg.Connection:
    return psycopg.connect(
        host=required_env("PGHOST"), dbname=required_env("PGDATABASE"),
        user=required_env("PGUSER"), password=required_env("PGPASSWORD"), row_factory=dict_row,
    )


def storage_provider() -> CloudflareR2StorageProvider:
    return CloudflareR2StorageProvider(
        bucket=required_env("R2_BUCKET_NAME"), endpoint=required_env("R2_ENDPOINT"),
        public_base_url=required_env("R2_PUBLIC_BASE_URL"),
        access_key_id=required_env("R2_ACCESS_KEY_ID"), secret_access_key=required_env("R2_SECRET_ACCESS_KEY"),
        max_attempts=int(os.getenv("MEDIA_UPLOAD_MAX_ATTEMPTS", "3")),
        retry_seconds=float(os.getenv("MEDIA_UPLOAD_RETRY_SECONDS", "2")),
    )


def resolve_credential(reference: str) -> str:
    match = ENV_REFERENCE.fullmatch(reference or "")
    if not match:
        raise RuntimeError("CREDENTIAL_REFERENCE_INVALID")
    return required_env(match.group(1))


def require_internal(value: str | None) -> None:
    if not INTERNAL_KEY or not value or not secrets.compare_digest(value, INTERNAL_KEY):
        raise HTTPException(403, "INTERNAL_AUTH_REQUIRED")


def event(cur: psycopg.Cursor, candidate: dict[str, Any], event_type: str, details: dict[str, Any]) -> None:
    cur.execute(
        """INSERT INTO social_media.events(client_id,content_id,event_type,workflow_name,details)
           VALUES(%s,%s,%s,'08 - Social Publication Orchestrator',%s::jsonb)""",
        (candidate["client_id"], candidate["content_id"], event_type, json.dumps(details, default=str)),
    )


def prepare_media(conn: psycopg.Connection, candidate: dict[str, Any], provider: CloudflareR2StorageProvider) -> tuple[dict[str, Any], bool]:
    final_path = validate_final_art_path(PROJECT_ROOT, candidate["client_id"], candidate["final_art_path"])
    checksum = file_sha256(final_path)
    if checksum != str(candidate["checksum_sha256"]).upper():
        raise MediaStorageError("MEDIA_CHECKSUM_MISMATCH")
    uploaded_now = False
    with conn.cursor() as cur:
        cur.execute(
            """SELECT * FROM social_media.publication_media_assets
               WHERE version_id=%s AND storage_provider='r2' FOR UPDATE""", (candidate["version_id"],),
        )
        asset = cur.fetchone()
        if asset and asset["client_id"] != candidate["client_id"]:
            raise RuntimeError("CROSS_CLIENT_PUBLICATION_BLOCKED")
        if asset and asset["checksum_sha256"].upper() != checksum:
            raise MediaStorageError("MEDIA_VERSION_IMMUTABILITY_VIOLATION")
        if asset is None:
            now = datetime.now(timezone.utc)
            object_key = provider.build_object_key(candidate["client_id"], checksum, (now.year, now.month))
            cur.execute(
                """INSERT INTO social_media.publication_media_assets
                   (client_id,content_id,version_id,publication_job_id,storage_provider,bucket,object_key,
                    checksum_sha256,content_type,size_bytes,status,metadata)
                   VALUES(%s,%s,%s,%s,'r2',%s,%s,%s,'image/png',%s,'PENDING_UPLOAD',%s::jsonb)
                   ON CONFLICT(version_id,storage_provider) DO NOTHING""",
                (candidate["client_id"],candidate["content_id"],candidate["version_id"],candidate["publication_job_id"],
                 provider.bucket,object_key,checksum,final_path.stat().st_size,json.dumps({"phase":"8.3.1","immutable":True})),
            )
            cur.execute(
                "SELECT * FROM social_media.publication_media_assets WHERE version_id=%s AND storage_provider='r2' FOR UPDATE",
                (candidate["version_id"],),
            )
            asset = cur.fetchone()
        if asset["publication_job_id"] is None:
            cur.execute("UPDATE social_media.publication_media_assets SET publication_job_id=%s,updated_at=now() WHERE id=%s",
                        (candidate["publication_job_id"], asset["id"]))
        event(cur,candidate,"PUBLICATION_MEDIA_RESOLVED",{
            "publication_job_id":candidate["publication_job_id"],"asset_id":str(asset["id"]),
            "storage_provider":"r2","existing":asset["status"]=="PUBLIC_VERIFIED",
        })
        conn.commit()

    if asset["status"] != "PUBLIC_VERIFIED":
        with conn.cursor() as cur:
            cur.execute("UPDATE social_media.publication_media_assets SET status='UPLOADING',updated_at=now() WHERE id=%s", (asset["id"],))
        conn.commit()
        uploaded = provider.upload_file(final_path, asset["object_key"], checksum)
        uploaded_now = True
        verified = provider.verify_public_url(uploaded["public_url"], checksum)
        with conn.cursor() as cur:
            cur.execute(
                """UPDATE social_media.publication_media_assets SET status='PUBLIC_VERIFIED',public_url=%s,
                   size_bytes=%s,uploaded_at=COALESCE(uploaded_at,now()),verified_at=now(),updated_at=now(),
                   metadata=metadata||%s::jsonb WHERE id=%s RETURNING *""",
                (uploaded["public_url"],uploaded["size_bytes"],json.dumps({"anonymous_http_status":verified["status"],
                 "remote_checksum":verified["checksum"]}),asset["id"]),
            )
            asset = cur.fetchone()
            event(cur,candidate,"PUBLICATION_MEDIA_UPLOADED",{"publication_job_id":candidate["publication_job_id"],"asset_id":str(asset["id"])})
        conn.commit()
    else:
        verified = provider.verify_public_url(asset["public_url"], checksum)
        with conn.cursor() as cur:
            event(cur,candidate,"PUBLICATION_MEDIA_REUSED",{"publication_job_id":candidate["publication_job_id"],"asset_id":str(asset["id"])})
        conn.commit()
    with conn.cursor() as cur:
        event(cur,candidate,"PUBLICATION_MEDIA_VERIFIED",{
            "publication_job_id":candidate["publication_job_id"],"asset_id":str(asset["id"]),
            "http_status":verified["status"],"checksum_verified":True,
        })
    conn.commit()
    return dict(asset), uploaded_now


def execute(request: PublicationRequest) -> dict[str, Any]:
    assert_preparation_runtime()
    provider = storage_provider()
    with connection() as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT social_media.prepare_publication_runtime_job(%s::uuid,%s,%s,%s::uuid,%s) AS result",
            (request.schedule_id,request.client_id,request.content_id,request.version_id,request.platform.lower()),
        )
        candidate = cur.fetchone()["result"]
        if not candidate.get("ok"):
            raise RuntimeError(candidate.get("error", "PUBLICATION_RUNTIME_VALIDATION_FAILED"))
        conn.commit()
        asset, uploaded_now = prepare_media(conn,candidate,provider)
        credential = resolve_credential(candidate["credential_reference"])
        buffer_client = BufferClient(
            api_key=credential, api_url=os.getenv("BUFFER_API_URL", "https://api.buffer.com"),
            selected_provider="buffer", dry_run=True, live_mode=False, publish_enabled=False,
        )
        channel = buffer_client.get_channel(candidate["provider_account_id"])
        if channel.get("isDisconnected") or channel.get("service") != candidate["platform"]:
            raise RuntimeError("BUFFER_CHANNEL_INVALID")
        internal_payload = {
            "publication_job_id":str(candidate["publication_job_id"]),"schedule_id":request.schedule_id,
            "client_id":request.client_id,"content_id":request.content_id,"version_id":request.version_id,
            "platform":candidate["platform"],"provider":"buffer",
            "social_account_id":candidate["social_account_id"],"provider_account_id":candidate["provider_account_id"],
            "caption":candidate["caption"],"hashtags":candidate.get("hashtags",[]),
            "media":[{"storage_provider":"r2","public_url":asset["public_url"],
                      "checksum":asset["checksum_sha256"],"type":"image","mime_type":"image/png","url":asset["public_url"]}],
            "scheduling_type":"automatic","provider_mode":"shareNow",
        }
        prepared = buffer_client.create_post(internal_payload, dry_run=True)
        payload_hash = sha256(json.dumps(prepared["variables"],sort_keys=True,separators=(",",":"),ensure_ascii=False).encode()).hexdigest()
        with conn.cursor() as update:
            update.execute(
                """UPDATE social_media.publication_jobs SET status='DRY_RUN_COMPLETED',dry_run_at=now(),
                   provider_status='DRY_RUN_COMPLETED',provider_payload_hash=%s,updated_at=now(),
                   metadata=metadata||%s::jsonb WHERE id=%s""",
                (payload_hash,json.dumps({"phase":"8.3.1","dry_run":True,"asset_id":str(asset["id"]),
                 "mutation_operation":"CreatePost","mutation_sent":False,"caption_length":len(candidate["caption"])}),candidate["publication_job_id"]),
            )
            event(update,candidate,"BUFFER_DRY_RUN_PREPARED",{
                "publication_job_id":candidate["publication_job_id"],"operation":"CreatePost",
                "provider_payload_hash":payload_hash,"mutation_sent":False,
            })
            event(update,candidate,"PUBLICATION_DRY_RUN_COMPLETED",{
                "publication_job_id":candidate["publication_job_id"],"asset_id":str(asset["id"]),
                "mutation_sent":False,"schedule_status":"READY_TO_PUBLISH",
            })
        conn.commit()
    return {
        "ok":True,"phase":"8.3.1","result":"BUFFER_DRY_RUN_OK","publication_job_id":str(candidate["publication_job_id"]),
        "schedule_id":request.schedule_id,"client_id":request.client_id,"content_id":request.content_id,
        "version_id":request.version_id,"platform":candidate["platform"],"provider":"buffer",
        "social_account_id":candidate["social_account_id"],"channel_username":candidate["username"],
        "asset_id":str(asset["id"]),"media_url":asset["public_url"],"checksum":asset["checksum_sha256"],
        "uploaded_now":uploaded_now,"reused_job":bool(candidate.get("duplicate")),
        "caption_length":len(candidate["caption"]),"provider_payload_hash":payload_hash,
        "mutation_prepared":True,"mutation_sent":False,"provider_post_id_created":False,
        "schedule_status":"READY_TO_PUBLISH","release_status":"HOLD",
    }


def load_live_candidate(conn: psycopg.Connection, job_id: str, lock: bool = False) -> dict[str, Any]:
    suffix = " FOR UPDATE OF pj" if lock else ""
    with conn.cursor() as cur:
        cur.execute(
            """SELECT pj.id AS publication_job_id,pj.schedule_id,pj.client_id,pj.content_id,pj.version_id,
                      pj.social_account_id,pj.platform,pj.provider,pj.status AS job_status,pj.release_status,
                      pj.publication_authorized_at,pj.attempt_count,pj.provider_post_id,pj.provider_status,
                      pj.provider_payload_hash,pj.metadata AS job_metadata,
                      s.status AS schedule_status,c.status AS content_status,c.approval_status,c.approved_version_id,
                      cv.version,cv.copy,cv.final_art_path,
                      r.checksum_sha256,r.width,r.height,
                      sa.username,sa.provider_account_id,sa.credential_reference,sa.is_active,sa.provider_status AS account_status,
                      a.id AS asset_id,a.status AS asset_status,a.public_url,a.checksum_sha256 AS asset_checksum,
                      a.content_type,a.size_bytes,a.metadata AS asset_metadata
               FROM social_media.publication_jobs pj
               JOIN social_media.content_schedule s ON s.id=pj.schedule_id
               JOIN social_media.content_items c ON c.content_id=pj.content_id
               JOIN social_media.content_versions cv ON cv.id=pj.version_id
               JOIN social_media.social_accounts sa ON sa.id=pj.social_account_id
               LEFT JOIN social_media.render_outputs r ON r.version_id=cv.id AND r.final_art_path=cv.final_art_path
               LEFT JOIN social_media.publication_media_assets a ON a.version_id=cv.id AND a.storage_provider='r2'
               WHERE pj.id=%s""" + suffix,
            (job_id,),
        )
        candidate = cur.fetchone()
    if not candidate:
        raise RuntimeError("PUBLICATION_JOB_NOT_FOUND")
    return dict(candidate)


def validate_first_live_candidate(candidate: dict[str, Any], released: bool) -> dict[str, Any]:
    target = configured_target_username()
    if candidate["platform"] != "instagram" or candidate["provider"] != "buffer":
        raise RuntimeError("PUBLICATION_PLATFORM_NOT_AUTHORIZED")
    if (candidate["username"] or "").strip().lstrip("@").lower() != target:
        raise RuntimeError("FIRST_LIVE_TARGET_ACCOUNT_MISMATCH")
    if not candidate["is_active"] or candidate["account_status"] != "connected":
        raise RuntimeError("BUFFER_CHANNEL_INVALID")
    if candidate["schedule_status"] != "READY_TO_PUBLISH":
        raise RuntimeError("PUBLICATION_NOT_READY")
    if candidate["approval_status"] != "APPROVED" or candidate["approved_version_id"] != candidate["version_id"]:
        raise RuntimeError("PUBLICATION_VERSION_NOT_APPROVED")
    if candidate["job_status"] != "DRY_RUN_COMPLETED":
        raise RuntimeError("FIRST_LIVE_JOB_NOT_DRY_RUN_COMPLETED")
    expected_release = "RELEASED" if released else "HOLD"
    if candidate["release_status"] != expected_release:
        raise RuntimeError("FIRST_LIVE_RELEASE_INVALID")
    if released and candidate["publication_authorized_at"] is None:
        raise RuntimeError("FIRST_LIVE_AUTHORIZATION_MISSING")
    if candidate["provider_post_id"] or int(candidate["attempt_count"] or 0) != 0:
        raise RuntimeError("FIRST_LIVE_MUTATION_ALREADY_ATTEMPTED")
    if not candidate["checksum_sha256"] or not candidate["width"] or not candidate["height"]:
        raise MediaStorageError("FINAL_ART_RENDER_EVIDENCE_MISSING")
    if candidate["asset_status"] != "PUBLIC_VERIFIED" or not candidate["public_url"]:
        raise MediaStorageError("R2_ASSET_NOT_PUBLIC_VERIFIED")
    if str(candidate["asset_checksum"]).upper() != str(candidate["checksum_sha256"]).upper():
        raise MediaStorageError("MEDIA_CHECKSUM_MISMATCH")
    copy = candidate.get("copy") or {}
    raw_caption = str(copy.get("caption") or "")
    hashtags = copy.get("hashtags") or []
    if not isinstance(hashtags, list):
        raise RuntimeError("APPROVED_HASHTAGS_INVALID")
    final_text = build_social_post_text(raw_caption, hashtags, candidate["platform"])
    candidate.update({
        "approved_caption": raw_caption.strip(),
        "hashtags": hashtags,
        "caption": final_text,
        "caption_hash": sha256(final_text.encode("utf-8")).hexdigest(),
        "caption_length": len(final_text),
        "hashtags_count": len({str(tag).strip().casefold() for tag in hashtags if str(tag).strip()}),
    })
    final_path = validate_final_art_path(PROJECT_ROOT, candidate["client_id"], candidate["final_art_path"])
    local_checksum = file_sha256(final_path)
    if local_checksum != str(candidate["checksum_sha256"]).upper():
        raise MediaStorageError("MEDIA_CHECKSUM_MISMATCH")
    width, height = validate_png(final_path, int(candidate["width"]), int(candidate["height"]))
    candidate.update({"local_checksum": local_checksum, "validated_width": width, "validated_height": height})
    return candidate


def ensure_unique_prepared_candidate(conn: psycopg.Connection, job_id: str) -> None:
    target = configured_target_username()
    with conn.cursor() as cur:
        cur.execute(
            """SELECT count(*) AS candidate_count
               FROM social_media.publication_jobs pj
               JOIN social_media.content_schedule s ON s.id=pj.schedule_id
               JOIN social_media.content_items c ON c.content_id=pj.content_id
               JOIN social_media.social_accounts sa ON sa.id=pj.social_account_id
               JOIN social_media.publication_media_assets a ON a.version_id=pj.version_id AND a.storage_provider='r2'
               WHERE pj.provider='buffer' AND pj.platform='instagram' AND pj.status='DRY_RUN_COMPLETED'
                 AND pj.release_status='HOLD' AND pj.provider_post_id IS NULL AND pj.attempt_count=0
                 AND s.status='READY_TO_PUBLISH' AND c.approval_status='APPROVED'
                 AND c.approved_version_id=pj.version_id AND sa.is_active=true AND sa.provider_status='connected'
                 AND lower(sa.username)=%s AND a.status='PUBLIC_VERIFIED'""",
            (target,),
        )
        count = int(cur.fetchone()["candidate_count"])
    if count != 1:
        raise RuntimeError("FIRST_LIVE_CANDIDATE_COUNT_INVALID")
    candidate = load_live_candidate(conn, job_id)
    if candidate["job_status"] != "DRY_RUN_COMPLETED" or candidate["release_status"] != "HOLD":
        raise RuntimeError("FIRST_LIVE_CANDIDATE_NOT_SELECTED")


def internal_publication_payload(candidate: dict[str, Any], asset: dict[str, Any]) -> dict[str, Any]:
    return {
        "publication_job_id": str(candidate["publication_job_id"]),
        "schedule_id": str(candidate["schedule_id"]),
        "client_id": candidate["client_id"],
        "content_id": candidate["content_id"],
        "version_id": str(candidate["version_id"]),
        "platform": "instagram",
        "provider": "buffer",
        "social_account_id": str(candidate["social_account_id"]),
        "provider_account_id": candidate["provider_account_id"],
        "caption": candidate["caption"],
        "hashtags": candidate["hashtags"],
        "media": [{
            "storage_provider": "r2", "public_url": asset["public_url"],
            "checksum": str(asset["checksum_sha256"]).upper(), "type": "image",
            "mime_type": "image/png", "url": asset["public_url"],
        }],
        "scheduling_type": "automatic",
        "provider_mode": "shareNow",
        "instagram_type": "post",
        "should_share_to_feed": True,
        "ai_generated": True,
    }


def phase84_preflight(request: LivePublicationRequest) -> dict[str, Any]:
    assert_preparation_runtime()
    provider = storage_provider()
    with connection() as conn:
        ensure_unique_prepared_candidate(conn, request.publication_job_id)
        candidate = validate_first_live_candidate(load_live_candidate(conn, request.publication_job_id), released=False)
        with conn.cursor() as cur:
            event(cur, candidate, "FIRST_LIVE_PREFLIGHT_STARTED", {
                "publication_job_id": request.publication_job_id, "authorized_target": configured_target_username(),
                "mutation_sent": False,
            })
        conn.commit()
        asset, uploaded_now = prepare_media(conn, candidate, provider)
        if uploaded_now:
            raise MediaStorageError("FIRST_LIVE_R2_ASSET_MUST_BE_REUSED")
        verified = provider.verify_public_url(asset["public_url"], candidate["local_checksum"])
        credential = resolve_credential(candidate["credential_reference"])
        client = BufferClient(
            api_key=credential, api_url=os.getenv("BUFFER_API_URL", "https://api.buffer.com"),
            selected_provider="buffer", dry_run=True, live_mode=False, publish_enabled=False, demo_mode=True,
        )
        channel = client.get_channel(candidate["provider_account_id"])
        if channel.get("id") != candidate["provider_account_id"] or channel.get("service") != "instagram" or channel.get("isDisconnected"):
            raise RuntimeError("BUFFER_CHANNEL_INVALID")
        payload = internal_publication_payload(candidate, asset)
        prepared = client.create_post(payload, dry_run=True)
        approved_hash = final_payload_hash(payload)
        variables_hash = sha256(json.dumps(prepared["variables"], sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()
        with conn.cursor() as cur:
            cur.execute(
                """UPDATE social_media.publication_jobs
                   SET provider_payload_hash=%s,dry_run_at=now(),updated_at=now(),
                       metadata=metadata||%s::jsonb WHERE id=%s""",
                (approved_hash, json.dumps({
                    "phase": "8.4", "caption_source": "approved_version",
                    "caption_length": candidate["caption_length"], "hashtags_count": candidate["hashtags_count"],
                    "caption_hash": candidate["caption_hash"], "mutation_variables_sha256": variables_hash,
                    "mutation_operation": "CreatePost", "provider_mode": "shareNow",
                    "dry_run": True, "mutation_sent": False, "r2_http_status": verified["status"],
                    "validated_width": candidate["validated_width"], "validated_height": candidate["validated_height"],
                }), request.publication_job_id),
            )
            event(cur, candidate, "FIRST_LIVE_PREFLIGHT_PASSED", {
                "publication_job_id": request.publication_job_id, "provider_payload_hash": approved_hash,
                "caption_source": "approved_version", "mutation_sent": False,
                "target": configured_target_username(), "platform": "instagram",
            })
        conn.commit()
    return {
        "ok": True, "phase": "8.4", "result": "FIRST_LIVE_PREFLIGHT_OK",
        "publication_job_id": request.publication_job_id, "schedule_id": str(candidate["schedule_id"]),
        "content_id": candidate["content_id"], "version_id": str(candidate["version_id"]),
        "version": candidate["version"], "target": configured_target_username(), "platform": "instagram",
        "provider": "buffer", "caption_source": "approved_version", "caption": candidate["caption"],
        "hashtags": candidate["hashtags"], "caption_length": candidate["caption_length"],
        "hashtags_count": candidate["hashtags_count"], "caption_hash": candidate["caption_hash"],
        "media_url": asset["public_url"], "media_checksum": candidate["local_checksum"],
        "width": candidate["validated_width"], "height": candidate["validated_height"],
        "http_status": verified["status"], "content_type": verified["content_type"],
        "operation": "CreatePost", "mode": "shareNow", "provider_payload_hash": approved_hash,
        "mutation_sent": False, "release_status": "HOLD",
    }


def persist_live_outcome(conn: psycopg.Connection, candidate: dict[str, Any], *, job_status: str,
                         provider_status: str, event_type: str, details: dict[str, Any],
                         provider_post_id: str | None = None, error_message: str | None = None) -> None:
    with conn.cursor() as cur:
        cur.execute(
            """UPDATE social_media.publication_jobs SET status=%s,provider_status=%s,
                   provider_post_id=COALESCE(%s,provider_post_id),error_message=%s,
                   release_status='CONSUMED',updated_at=now(),metadata=metadata||%s::jsonb WHERE id=%s""",
            (job_status, provider_status, provider_post_id, error_message,
             json.dumps({"phase": "8.4", "response_timestamp": datetime.now(timezone.utc).isoformat()}),
             candidate["publication_job_id"]),
        )
        event(cur, candidate, event_type, details)
    conn.commit()


def phase84_publish(request: LivePublicationRequest) -> dict[str, Any]:
    assert_live_runtime()
    provider = storage_provider()
    with connection() as conn:
        candidate = validate_first_live_candidate(load_live_candidate(conn, request.publication_job_id, lock=True), released=True)
        conn.commit()
        asset, uploaded_now = prepare_media(conn, candidate, provider)
        if uploaded_now:
            raise MediaStorageError("FIRST_LIVE_R2_ASSET_MUST_BE_REUSED")
        verified = provider.verify_public_url(asset["public_url"], candidate["local_checksum"])
        credential = resolve_credential(candidate["credential_reference"])
        payload = internal_publication_payload(candidate, asset)
        live_hash = final_payload_hash(payload)
        if not candidate["provider_payload_hash"] or live_hash != candidate["provider_payload_hash"]:
            raise RuntimeError("LIVE_PAYLOAD_DIFFERS_FROM_APPROVED_DRY_RUN")
        read_client = BufferClient(
            api_key=credential, api_url=os.getenv("BUFFER_API_URL", "https://api.buffer.com"),
            selected_provider="buffer", dry_run=True, demo_mode=True,
        )
        channel = read_client.get_channel(candidate["provider_account_id"])
        if channel.get("id") != candidate["provider_account_id"] or channel.get("service") != "instagram" or channel.get("isDisconnected"):
            raise RuntimeError("BUFFER_CHANNEL_INVALID")
        prepared = read_client.create_post(payload, dry_run=True)
        variables_hash = sha256(json.dumps(prepared["variables"], sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()
        provider.verify_public_url(asset["public_url"], candidate["local_checksum"])
        with conn.cursor() as cur:
            locked = load_live_candidate(conn, request.publication_job_id, lock=True)
            if locked["release_status"] != "RELEASED" or locked["provider_post_id"] or int(locked["attempt_count"] or 0) != 0:
                raise RuntimeError("FIRST_LIVE_MUTATION_ALREADY_ATTEMPTED")
            cur.execute(
                """UPDATE social_media.publication_jobs SET status='PUBLISHING',provider_status='MUTATION_STARTED',
                       attempt_count=1,started_at=now(),updated_at=now(),metadata=metadata||%s::jsonb WHERE id=%s""",
                (json.dumps({"phase": "8.4", "mutation_sent": True,
                 "mutation_started_at": datetime.now(timezone.utc).isoformat(),
                 "mutation_variables_sha256": variables_hash}), request.publication_job_id),
            )
            event(cur, candidate, "BUFFER_LIVE_MUTATION_STARTED", {
                "publication_job_id": request.publication_job_id, "attempt": 1,
                "provider_payload_hash": live_hash, "target": configured_target_username(),
            })
        conn.commit()

        live_client = BufferClient(
            api_key=credential, api_url=os.getenv("BUFFER_API_URL", "https://api.buffer.com"),
            selected_provider="buffer", dry_run=False, live_mode=True, publish_enabled=True, demo_mode=False,
        )
        try:
            result = live_client.create_post(payload, dry_run=False)
        except (BufferApiUncertainError, BufferApiError) as exc:
            persist_live_outcome(
                conn, candidate, job_status="PUBLICATION_CONFIRMATION_PENDING", provider_status="UNKNOWN",
                event_type="PUBLICATION_CONFIRMATION_PENDING",
                details={"publication_job_id": request.publication_job_id, "error": str(exc), "mutation_count": 1},
                error_message=str(exc),
            )
            return {"ok": False, "phase": "8.4", "result": "PUBLICATION_CONFIRMATION_PENDING",
                    "publication_job_id": request.publication_job_id, "mutation_count": 1,
                    "provider_post_id": None, "provider_status": "UNKNOWN"}

        post = result.get("post") if isinstance(result, dict) else None
        if result.get("__typename") != "PostActionSuccess" or not post or not post.get("id"):
            message = str(result.get("message") or "BUFFER_MUTATION_ERROR")
            persist_live_outcome(
                conn, candidate, job_status="FAILED", provider_status="error",
                event_type="BUFFER_LIVE_MUTATION_FAILED",
                details={"publication_job_id": request.publication_job_id, "error": message, "mutation_count": 1},
                error_message=message,
            )
            return {"ok": False, "phase": "8.4", "result": "BUFFER_MUTATION_ERROR",
                    "publication_job_id": request.publication_job_id, "mutation_count": 1,
                    "provider_post_id": None, "provider_status": "error", "error": message}

        post_id = str(post["id"])
        initial_status = str(post.get("status") or "created")
        persist_live_outcome(
            conn, candidate, job_status="PUBLISHING", provider_status=initial_status,
            event_type="BUFFER_POST_CREATED",
            details={"publication_job_id": request.publication_job_id, "provider_post_id": post_id,
                     "provider_status": initial_status, "mutation_count": 1},
            provider_post_id=post_id,
        )
        attempts = max(1, min(int(os.getenv("BUFFER_STATUS_POLL_ATTEMPTS", "24")), 60))
        interval = max(1.0, min(float(os.getenv("BUFFER_STATUS_POLL_SECONDS", "5")), 10.0))
        final_status = initial_status
        external_link = post.get("externalLink")
        for index in range(attempts):
            if final_status in {"sent", "error"}:
                break
            if index:
                sleep(interval)
            try:
                current = live_client.get_post(post_id)
                final_status = str(current.get("status") or final_status)
                external_link = current.get("externalLink") or external_link
                with conn.cursor() as cur:
                    cur.execute("UPDATE social_media.publication_jobs SET provider_status=%s,updated_at=now() WHERE id=%s",
                                (final_status, request.publication_job_id))
                    event(cur, candidate, "BUFFER_POST_STATUS_CHECKED", {
                        "publication_job_id": request.publication_job_id, "provider_post_id": post_id,
                        "provider_status": final_status, "poll": index + 1,
                    })
                conn.commit()
            except BufferApiError:
                final_status = "confirmation_pending"
                break

        if final_status == "sent":
            with conn.cursor() as cur:
                cur.execute(
                    """UPDATE social_media.publication_jobs SET status='PUBLISHED',provider_status='sent',
                           published_at=now(),updated_at=now(),metadata=metadata||%s::jsonb WHERE id=%s""",
                    (json.dumps({"phase": "8.4", "external_link": external_link}), request.publication_job_id),
                )
                cur.execute("UPDATE social_media.content_schedule SET status='PUBLISHED',published_at=now(),updated_at=now() WHERE id=%s",
                            (candidate["schedule_id"],))
                cur.execute("UPDATE social_media.content_items SET status='PUBLISHED',published_at=now(),updated_at=now() WHERE content_id=%s",
                            (candidate["content_id"],))
                event(cur, candidate, "CONTENT_PUBLISHED", {
                    "publication_job_id": request.publication_job_id, "provider_post_id": post_id,
                    "provider_status": "sent", "target": configured_target_username(),
                })
            conn.commit()
            outcome = "PUBLISHED"
        elif final_status == "error":
            persist_live_outcome(
                conn, candidate, job_status="FAILED", provider_status="error",
                event_type="BUFFER_LIVE_MUTATION_FAILED",
                details={"publication_job_id": request.publication_job_id, "provider_post_id": post_id,
                         "provider_status": "error", "mutation_count": 1},
                provider_post_id=post_id, error_message="BUFFER_POST_STATUS_ERROR",
            )
            outcome = "FAILED"
        else:
            persist_live_outcome(
                conn, candidate, job_status="PUBLICATION_CONFIRMATION_PENDING", provider_status=final_status,
                event_type="PUBLICATION_CONFIRMATION_PENDING",
                details={"publication_job_id": request.publication_job_id, "provider_post_id": post_id,
                         "provider_status": final_status, "mutation_count": 1},
                provider_post_id=post_id,
            )
            outcome = "PUBLICATION_CONFIRMATION_PENDING"
    return {
        "ok": outcome == "PUBLISHED", "phase": "8.4", "result": outcome,
        "publication_job_id": request.publication_job_id, "content_id": candidate["content_id"],
        "version_id": str(candidate["version_id"]), "target": configured_target_username(),
        "provider": "buffer", "platform": "instagram", "mutation_count": 1,
        "provider_post_id": post_id, "provider_status": final_status,
        "provider_payload_hash": live_hash, "caption": candidate["caption"],
        "media_url": asset["public_url"], "media_checksum": candidate["local_checksum"],
        "http_status": verified["status"], "external_link": external_link,
    }


@app.get("/health")
def health() -> dict[str, Any]:
    mode = runtime_mode()
    with connection() as conn, conn.cursor() as cur:
        cur.execute("SELECT 1 AS ok")
        database_ok = cur.fetchone()["ok"] == 1
    return {"ok": database_ok, "mode": mode, "mutations_enabled": mode == "live-one-shot"}


@app.post("/prepare-publication")
def prepare_publication(request: PublicationRequest, x_internal_key: str | None = Header(default=None)) -> dict[str, Any]:
    require_internal(x_internal_key)
    try:
        return execute(request)
    except (RuntimeError,MediaStorageError) as exc:
        raise HTTPException(409, str(exc)) from exc


@app.post("/preflight-publication")
def preflight_publication(request: LivePublicationRequest, x_internal_key: str | None = Header(default=None)) -> dict[str, Any]:
    require_internal(x_internal_key)
    try:
        return phase84_preflight(request)
    except (RuntimeError, MediaStorageError, BufferApiError) as exc:
        raise HTTPException(409, str(exc)) from exc


@app.post("/publish-authorized")
def publish_authorized(request: LivePublicationRequest, x_internal_key: str | None = Header(default=None)) -> dict[str, Any]:
    require_internal(x_internal_key)
    try:
        return phase84_publish(request)
    except (RuntimeError, MediaStorageError, BufferApiError) as exc:
        raise HTTPException(409, str(exc)) from exc
