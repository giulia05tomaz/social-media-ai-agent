"""Phase 8.3 R2 upload and Buffer GraphQL dry-run orchestrator."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
from hashlib import sha256
import json
import os
from pathlib import Path
import re
from urllib.error import HTTPError
from urllib.request import Request, urlopen

import psycopg
from psycopg.rows import dict_row

from .buffer_client import BufferClient
from .storage import CloudflareR2StorageProvider, MediaStorageError, file_sha256, validate_final_art_path


def env_required(name: str) -> str:
    value = os.getenv(name, "").strip()
    if not value:
        raise RuntimeError(f"{name}_MISSING")
    return value


def resolve_credential(reference: str) -> str:
    match = re.fullmatch(r"env:([A-Z][A-Z0-9_]*)", reference or "")
    if not match:
        raise RuntimeError("CREDENTIAL_REFERENCE_INVALID")
    return env_required(match.group(1))


def public_root_not_listable(base_url: str) -> tuple[bool, int]:
    try:
        with urlopen(Request(base_url.rstrip("/") + "/", method="GET"), timeout=20) as response:
            body = response.read(8192).lower()
            return response.status in (403, 404) or b"<listbucketresult" not in body, response.status
    except HTTPError as exc:
        return exc.code in (403, 404), exc.code


def run(content_id: str, evidence_path: Path) -> dict:
    project_root = Path(os.getenv("PROJECT_ROOT", "/data"))
    provider = CloudflareR2StorageProvider(
        bucket=env_required("R2_BUCKET_NAME"),
        endpoint=env_required("R2_ENDPOINT"),
        public_base_url=env_required("R2_PUBLIC_BASE_URL"),
        access_key_id=env_required("R2_ACCESS_KEY_ID"),
        secret_access_key=env_required("R2_SECRET_ACCESS_KEY"),
        max_attempts=int(os.getenv("MEDIA_UPLOAD_MAX_ATTEMPTS", "3")),
        retry_seconds=float(os.getenv("MEDIA_UPLOAD_RETRY_SECONDS", "2")),
    )
    if not provider.connection_ok():
        raise RuntimeError("R2_CONNECTION_FAILED")

    connection = psycopg.connect(
        host=env_required("PGHOST"), dbname=env_required("PGDATABASE"),
        user=env_required("PGUSER"), password=env_required("PGPASSWORD"),
        row_factory=dict_row,
    )
    uploaded_now = False
    with connection:
        with connection.cursor() as cursor:
            cursor.execute("SELECT client_id,approved_version_id FROM social_media.content_items WHERE content_id=%s", (content_id,))
            version_row = cursor.fetchone()
            if not version_row or not version_row["approved_version_id"]:
                raise RuntimeError("VERSION_NOT_APPROVED")
            version_id = version_row["approved_version_id"]
            cursor.execute("SELECT social_media.validate_publication_media_version(%s)", (version_id,))
            candidate = cursor.fetchone()["validate_publication_media_version"]
            if not candidate.get("ok"):
                raise RuntimeError(candidate.get("error", "MEDIA_CANDIDATE_INVALID"))

            final_path = validate_final_art_path(project_root, candidate["client_id"], candidate["final_art_path"])
            local_checksum = file_sha256(final_path)
            if local_checksum != candidate["checksum_sha256"].upper():
                raise MediaStorageError("MEDIA_CHECKSUM_MISMATCH")

            cursor.execute("""SELECT id FROM social_media.content_schedule
                WHERE content_id=%s AND version_id=%s AND platform='instagram' AND status='READY_TO_PUBLISH'
                ORDER BY updated_at DESC LIMIT 1""", (content_id, version_id))
            schedule = cursor.fetchone()
            if not schedule:
                raise RuntimeError("READY_TO_PUBLISH_SCHEDULE_NOT_FOUND")
            cursor.execute("SELECT social_media.resolve_social_account(%s,'instagram','buffer') AS account", (candidate["client_id"],))
            account_resolution = cursor.fetchone()["account"]
            if not account_resolution.get("ok"):
                raise RuntimeError(account_resolution.get("error", "BUFFER_INSTAGRAM_CHANNEL_NOT_FOUND"))
            cursor.execute("""SELECT id,provider_account_id,username,credential_reference
                FROM social_media.social_accounts WHERE id=%s""", (account_resolution["social_account_id"],))
            account = cursor.fetchone()
            if not account:
                raise RuntimeError("BUFFER_INSTAGRAM_CHANNEL_NOT_FOUND")
            cursor.execute("SELECT social_media.prepare_buffer_publication_job(%s,%s)", (schedule["id"], account["id"]))
            job = cursor.fetchone()["prepare_buffer_publication_job"]
            if not job.get("ok"):
                raise RuntimeError(job.get("error", "BUFFER_JOB_INVALID"))
            publication_job_id = job["publication_job_id"]

            cursor.execute("""SELECT * FROM social_media.publication_media_assets
                WHERE version_id=%s AND storage_provider='r2' FOR UPDATE""", (version_id,))
            asset = cursor.fetchone()
            if asset and asset["checksum_sha256"].upper() != local_checksum:
                raise MediaStorageError("MEDIA_VERSION_IMMUTABILITY_VIOLATION")
            if asset is None:
                now = datetime.now(timezone.utc)
                object_key = provider.build_object_key(candidate["client_id"], local_checksum, (now.year, now.month))
                cursor.execute("""INSERT INTO social_media.publication_media_assets
                    (client_id,content_id,version_id,publication_job_id,storage_provider,bucket,object_key,
                     checksum_sha256,content_type,size_bytes,status,metadata)
                    VALUES(%s,%s,%s,%s,'r2',%s,%s,%s,'image/png',%s,'PENDING_UPLOAD',%s) RETURNING *""",
                    (candidate["client_id"],content_id,version_id,publication_job_id,provider.bucket,object_key,
                     local_checksum,final_path.stat().st_size,json.dumps({"phase":"8.3","immutable":True})))
                asset = cursor.fetchone()
            elif asset["publication_job_id"] is None:
                cursor.execute("UPDATE social_media.publication_media_assets SET publication_job_id=%s,updated_at=now() WHERE id=%s",
                               (publication_job_id,asset["id"]))
            connection.commit()

            if asset["status"] != "PUBLIC_VERIFIED":
                cursor.execute("UPDATE social_media.publication_media_assets SET status='UPLOADING',updated_at=now() WHERE id=%s", (asset["id"],))
                connection.commit()
                try:
                    uploaded = provider.upload_file(final_path, asset["object_key"], local_checksum)
                    uploaded_now = True
                    cursor.execute("""UPDATE social_media.publication_media_assets
                        SET status='UPLOADED',public_url=%s,size_bytes=%s,uploaded_at=now(),updated_at=now(),
                            metadata=metadata||%s::jsonb WHERE id=%s RETURNING *""",
                        (uploaded["public_url"],uploaded["size_bytes"],json.dumps({"cache_control":provider.cache_control}),asset["id"]))
                    asset = cursor.fetchone()
                    connection.commit()
                    verified = provider.verify_public_url(asset["public_url"], local_checksum)
                    cursor.execute("""UPDATE social_media.publication_media_assets
                        SET status='PUBLIC_VERIFIED',verified_at=now(),updated_at=now(),metadata=metadata||%s::jsonb
                        WHERE id=%s RETURNING *""",
                        (json.dumps({"anonymous_http_status":verified["status"],"remote_checksum":verified["checksum"]}),asset["id"]))
                    asset = cursor.fetchone()
                    connection.commit()
                except Exception as exc:
                    cursor.execute("UPDATE social_media.publication_media_assets SET status='FAILED',updated_at=now(),metadata=metadata||%s::jsonb WHERE id=%s",
                                   (json.dumps({"error":str(exc)}),asset["id"]))
                    connection.commit()
                    raise
            else:
                verified = provider.verify_public_url(asset["public_url"], local_checksum)

            cursor.execute("SELECT social_media.validate_buffer_dry_run_candidate(%s,%s,%s)",
                           (schedule["id"],account["id"],asset["id"]))
            dry_candidate = cursor.fetchone()["validate_buffer_dry_run_candidate"]
            if not dry_candidate.get("ok"):
                raise RuntimeError(dry_candidate.get("error", "BUFFER_DRY_RUN_CANDIDATE_INVALID"))
            cursor.execute("SELECT social_media.build_instagram_caption(copy->>'caption',copy->'hashtags') caption FROM social_media.content_versions WHERE id=%s", (version_id,))
            caption = cursor.fetchone()["caption"]

            buffer_client = BufferClient(
                api_key=resolve_credential(account["credential_reference"]), api_url=os.getenv("BUFFER_API_URL","https://api.buffer.com"),
                selected_provider="buffer", dry_run=True,
            )
            live_channel = buffer_client.get_channel(account["provider_account_id"])
            if live_channel.get("isDisconnected") or live_channel.get("service") != "instagram":
                raise RuntimeError("BUFFER_INSTAGRAM_CHANNEL_INVALID")
            payload = {
                "provider_account_id": account["provider_account_id"],
                "caption": caption,
                "media": [{"type":"image","mime_type":"image/png","url":asset["public_url"]}],
                "scheduling_type": "automatic", "provider_mode": "shareNow",
            }
            prepared = buffer_client.prepare_create_post(payload)
            mutation_hash = sha256(json.dumps(prepared["variables"],sort_keys=True,separators=(",",":"),ensure_ascii=False).encode()).hexdigest()
            cursor.execute("""UPDATE social_media.publication_jobs SET provider_status='DRY_RUN_VALIDATED',updated_at=now(),
                metadata=metadata||%s::jsonb WHERE id=%s AND attempt_count=0 AND release_status='HOLD'
                AND provider_post_id IS NULL""",
                (json.dumps({"phase":"8.3","dry_run":True,"asset_id":str(asset["id"]),"mutation_variables_sha256":mutation_hash}),publication_job_id))
            cursor.execute("""INSERT INTO social_media.events(client_id,content_id,event_type,workflow_name,details)
                VALUES(%s,%s,'BUFFER_DRY_RUN_VALIDATED','08.3 - R2 Buffer Dry Run',%s::jsonb)""",
                (candidate["client_id"],content_id,json.dumps({"publication_job_id":str(publication_job_id),"asset_id":str(asset["id"]),"mutation_executed":False,"mode":"shareNow"})))
            cursor.execute("UPDATE social_media.runtime_config SET config_value='r2',updated_at=now() WHERE config_key='media_storage_provider'")
            connection.commit()

    root_not_listable, root_status = public_root_not_listable(provider.public_base_url)
    evidence = {
        "phase":"8.3","result":"BUFFER_DRY_RUN_OK","provider":"buffer","storage_provider":"r2",
        "platform":"instagram","channel_username":account["username"],"platform_isolated":True,
        "content_id":content_id,"version_id":str(version_id),"publication_job_id":str(publication_job_id),
        "asset_id":str(asset["id"]),"media_url":asset["public_url"],"media_checksum":local_checksum,
        "remote_checksum":verified["checksum"],"content_type":"image/png","size_bytes":asset["size_bytes"],
        "caption_length":len(caption),"mutation_operation_name":prepared["operation_name"],
        "mutation_variables_sha256":mutation_hash,"scheduling_mode":"shareNow","dry_run":True,
        "mutation_prepared":True,"mutation_sent":False,"provider_post_id_created":False,
        "uploaded_now":uploaded_now,"public_http_status":verified["status"],
        "bucket_root_status":root_status,"bucket_root_listable":not root_not_listable,
        "warning":"TEST_ACCOUNT_MAPPING",
    }
    evidence_path.parent.mkdir(parents=True,exist_ok=True)
    evidence_path.write_text(json.dumps(evidence,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    return evidence


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--content-id",required=True)
    parser.add_argument("--evidence-path",default="/app/docs/phase83-dry-run.json")
    args = parser.parse_args()
    result = run(args.content_id,Path(args.evidence_path))
    print(json.dumps({
        "result":result["result"],"r2_connection":"OK","upload":"OK" if result["uploaded_now"] else "REUSED",
        "public_http_status":result["public_http_status"],"checksums_equal":result["media_checksum"]==result["remote_checksum"],
        "buffer_mutation_sent":False,"provider_post_id_created":False,
    }))


if __name__ == "__main__":
    main()
