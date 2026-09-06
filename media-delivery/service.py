import hashlib
import os
import secrets
from datetime import datetime, timedelta, timezone
from pathlib import Path

import psycopg
from fastapi import FastAPI, Header, HTTPException
from fastapi.responses import FileResponse
from PIL import Image
from pydantic import BaseModel

app = FastAPI(title="Restricted Media Delivery", docs_url=None, redoc_url=None)
MEDIA_ROOT = Path(os.getenv("MEDIA_ROOT", "/data")).resolve()
ALLOWED_ROOT = (MEDIA_ROOT / "assets" / "generated").resolve()
INTERNAL_KEY = os.environ["MEDIA_DELIVERY_INTERNAL_KEY"]
PUBLIC_BASE = os.getenv("PUBLIC_MEDIA_BASE_URL", "http://media-delivery:8080").rstrip("/")
DEFAULT_TTL = int(os.getenv("MEDIA_URL_TTL_MINUTES", "30"))


def connection():
    return psycopg.connect(
        host=os.environ["PGHOST"], dbname=os.environ["PGDATABASE"],
        user=os.environ["PGUSER"], password=os.environ["PGPASSWORD"]
    )


def require_internal(value: str | None):
    if not value or not secrets.compare_digest(value, INTERNAL_KEY):
        raise HTTPException(403, "INTERNAL_AUTH_REQUIRED")


def safe_final_path(relative: str) -> Path:
    if not relative or Path(relative).is_absolute() or ".." in Path(relative).parts:
        raise HTTPException(400, "PATH_TRAVERSAL_BLOCKED")
    full = (MEDIA_ROOT / relative).resolve()
    try:
        full.relative_to(ALLOWED_ROOT)
    except ValueError as exc:
        raise HTTPException(400, "ASSET_OUTSIDE_GENERATED") from exc
    if "rendered" not in full.parts:
        raise HTTPException(400, "ONLY_FINAL_ART_ALLOWED")
    if not full.is_file():
        raise HTTPException(404, "FINAL_ART_NOT_FOUND")
    return full


def checksum(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


class TokenRequest(BaseModel):
    publication_job_id: str
    ttl_minutes: int | None = None


@app.get("/health")
def health():
    return {"ok": True, "publicly_exposed": False}


@app.post("/internal/tokens")
def create_token(request: TokenRequest, x_internal_key: str | None = Header(default=None)):
    require_internal(x_internal_key)
    ttl = request.ttl_minutes or DEFAULT_TTL
    if ttl < 1 or ttl > 60:
        raise HTTPException(400, "TTL_OUT_OF_RANGE")
    with connection() as conn, conn.cursor() as cur:
        cur.execute("""
          SELECT j.id,j.provider,s.status,c.approval_status,c.approved_version_id,j.version_id,
                 v.final_art_path,r.checksum_sha256
          FROM social_media.publication_jobs j
          JOIN social_media.content_schedule s ON s.id=j.schedule_id
          JOIN social_media.content_items c ON c.content_id=j.content_id
          JOIN social_media.content_versions v ON v.id=j.version_id
          LEFT JOIN social_media.render_outputs r ON r.version_id=j.version_id AND r.final_art_path=v.final_art_path
          WHERE j.id=%s
          ORDER BY r.created_at DESC NULLS LAST LIMIT 1
        """, (request.publication_job_id,))
        row = cur.fetchone()
        if not row:
            raise HTTPException(404, "PUBLICATION_JOB_NOT_FOUND")
        _, provider, schedule_status, approval, approved_version, version_id, relative, expected = row
        if schedule_status != "READY_TO_PUBLISH":
            raise HTTPException(409, "SCHEDULE_NOT_READY")
        if approval != "APPROVED" or approved_version != version_id:
            raise HTTPException(409, "VERSION_NOT_APPROVED")
        path = safe_final_path(relative)
        with Image.open(path) as image:
            image.verify()
        actual = checksum(path)
        if not expected:
            raise HTTPException(409, "CHECKSUM_NOT_PERSISTED")
        if actual.lower() != expected.lower():
            raise HTTPException(409, "CHECKSUM_MISMATCH")
        suffix = path.suffix.lower()
        meta_compatible = suffix in (".jpg", ".jpeg")
        if provider == "instagram" and not meta_compatible:
            raise HTTPException(409, "INSTAGRAM_IMAGE_REQUIRES_JPEG")
        token = secrets.token_urlsafe(32)
        token_hash = hashlib.sha256(token.encode()).hexdigest()
        expires = datetime.now(timezone.utc) + timedelta(minutes=ttl)
        cur.execute("""
          INSERT INTO social_media.media_delivery_tokens
            (publication_job_id,token_hash,final_art_path,file_checksum,expires_at,metadata)
          VALUES(%s,%s,%s,%s,%s,%s::jsonb)
        """, (request.publication_job_id, token_hash, relative, actual, expires,
              '{"phase":"8.1","scope":"single_final_art"}'))
        cur.execute("UPDATE social_media.publication_jobs SET status='MEDIA_EXPOSING',file_checksum=%s,updated_at=now() WHERE id=%s",
                    (actual, request.publication_job_id))
    return {"ok": True, "media_url": f"{PUBLIC_BASE}/media/{token}", "expires_at": expires.isoformat(),
            "checksum": actual, "meta_compatible": meta_compatible,
            "required_delivery_format": "image/jpeg", "provider": provider}


@app.get("/media/{token}")
def deliver(token: str):
    token_hash = hashlib.sha256(token.encode()).hexdigest()
    with connection() as conn, conn.cursor() as cur:
        cur.execute("SELECT id,final_art_path,file_checksum,expires_at,revoked_at FROM social_media.media_delivery_tokens WHERE token_hash=%s", (token_hash,))
        row = cur.fetchone()
        if not row:
            raise HTTPException(404, "MEDIA_TOKEN_NOT_FOUND")
        token_id, relative, expected, expires, revoked = row
        if revoked:
            raise HTTPException(410, "MEDIA_TOKEN_REVOKED")
        if expires <= datetime.now(timezone.utc):
            raise HTTPException(410, "MEDIA_TOKEN_EXPIRED")
        path = safe_final_path(relative)
        if checksum(path).lower() != expected.lower():
            raise HTTPException(409, "CHECKSUM_MISMATCH")
        cur.execute("UPDATE social_media.media_delivery_tokens SET last_accessed_at=now() WHERE id=%s", (token_id,))
    media_type = "image/jpeg" if path.suffix.lower() in (".jpg", ".jpeg") else "image/png"
    return FileResponse(path, media_type=media_type, filename="approved-final-art" + path.suffix.lower(),
                        headers={"Cache-Control": "private, no-store", "X-Content-Type-Options": "nosniff"})


@app.post("/internal/tokens/{token}/revoke")
def revoke(token: str, x_internal_key: str | None = Header(default=None)):
    require_internal(x_internal_key)
    token_hash = hashlib.sha256(token.encode()).hexdigest()
    with connection() as conn, conn.cursor() as cur:
        cur.execute("UPDATE social_media.media_delivery_tokens SET revoked_at=now() WHERE token_hash=%s AND revoked_at IS NULL RETURNING id", (token_hash,))
        if not cur.fetchone():
            raise HTTPException(404, "MEDIA_TOKEN_NOT_FOUND")
    return {"ok": True, "revoked": True}
