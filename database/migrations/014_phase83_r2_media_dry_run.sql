-- Phase 8.3: immutable public media assets and Buffer dry-run. No external mutation.
CREATE TABLE IF NOT EXISTS social_media.publication_media_assets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id text NOT NULL REFERENCES social_media.clients(client_id),
  content_id text NOT NULL REFERENCES social_media.content_items(content_id),
  version_id uuid NOT NULL REFERENCES social_media.content_versions(id),
  publication_job_id uuid REFERENCES social_media.publication_jobs(id),
  storage_provider text NOT NULL CHECK(storage_provider IN ('local','r2','s3','cloudinary')),
  bucket text NOT NULL,
  object_key text NOT NULL,
  public_url text,
  checksum_sha256 text NOT NULL CHECK(checksum_sha256 ~ '^[A-Fa-f0-9]{64}$'),
  content_type text NOT NULL,
  size_bytes bigint NOT NULL CHECK(size_bytes >= 0),
  status text NOT NULL DEFAULT 'PENDING_UPLOAD'
    CHECK(status IN ('PENDING_UPLOAD','UPLOADING','UPLOADED','PUBLIC_VERIFIED','FAILED','RETIRED','DELETED')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  uploaded_at timestamptz,
  verified_at timestamptz,
  deleted_at timestamptz,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  UNIQUE(version_id,storage_provider),
  UNIQUE(storage_provider,bucket,object_key)
);

CREATE INDEX IF NOT EXISTS idx_publication_media_assets_job
  ON social_media.publication_media_assets(publication_job_id,status);
CREATE INDEX IF NOT EXISTS idx_publication_media_assets_content
  ON social_media.publication_media_assets(content_id,version_id);

INSERT INTO social_media.runtime_config(config_key,config_value) VALUES
 ('media_storage_provider','local'),
 ('buffer_dry_run','true'),
 ('media_upload_max_attempts','3'),
 ('media_upload_retry_seconds','2'),
 ('published_media_retention_days','7')
ON CONFLICT(config_key) DO UPDATE SET config_value=CASE
  WHEN EXCLUDED.config_key='buffer_dry_run' THEN 'true'
  ELSE social_media.runtime_config.config_value END,updated_at=now();

CREATE OR REPLACE FUNCTION social_media.validate_publication_media_version(p_version_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE v record;
BEGIN
  SELECT c.client_id,c.content_id,c.approval_status,c.approved_version_id,
    cv.id version_id,cv.final_art_path,cv.copy,r.checksum_sha256,r.width,r.height
  INTO v
  FROM social_media.content_versions cv
  JOIN social_media.content_items c ON c.content_id=cv.content_id
  LEFT JOIN social_media.render_outputs r ON r.version_id=cv.id AND r.final_art_path=cv.final_art_path
  WHERE cv.id=p_version_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','VERSION_NOT_FOUND'); END IF;
  IF v.approval_status<>'APPROVED' OR v.approved_version_id IS DISTINCT FROM v.version_id THEN
    RETURN jsonb_build_object('ok',false,'error','VERSION_NOT_APPROVED');
  END IF;
  IF v.final_art_path IS NULL OR v.final_art_path !~ '^assets/generated/[^/]+/.+/rendered/[^/]+$' THEN
    RETURN jsonb_build_object('ok',false,'error','FINAL_ART_PATH_NOT_ALLOWED');
  END IF;
  IF lower(v.final_art_path) ~ '(^|/)(source|specs?)(/|\.)' THEN
    RETURN jsonb_build_object('ok',false,'error','FINAL_ART_PATH_NOT_ALLOWED');
  END IF;
  IF v.checksum_sha256 IS NULL OR v.checksum_sha256 !~ '^[A-Fa-f0-9]{64}$' THEN
    RETURN jsonb_build_object('ok',false,'error','MEDIA_CHECKSUM_MISSING');
  END IF;
  RETURN jsonb_build_object('ok',true,'client_id',v.client_id,'content_id',v.content_id,
    'version_id',v.version_id,'final_art_path',v.final_art_path,
    'checksum_sha256',upper(v.checksum_sha256),'copy',v.copy,'width',v.width,'height',v.height);
END; $$;

CREATE OR REPLACE FUNCTION social_media.validate_buffer_dry_run_candidate(
  p_schedule_id uuid,p_social_account_id uuid,p_asset_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE v_candidate jsonb;v_asset social_media.publication_media_assets%ROWTYPE;
BEGIN
  v_candidate:=social_media.validate_buffer_publication_candidate(p_schedule_id,p_social_account_id);
  IF NOT COALESCE((v_candidate->>'ok')::boolean,false) THEN RETURN v_candidate; END IF;
  SELECT * INTO v_asset FROM social_media.publication_media_assets WHERE id=p_asset_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','MEDIA_ASSET_NOT_FOUND'); END IF;
  IF v_asset.version_id IS DISTINCT FROM (v_candidate->>'version_id')::uuid THEN
    RETURN jsonb_build_object('ok',false,'error','MEDIA_VERSION_MISMATCH');
  END IF;
  IF v_asset.status<>'PUBLIC_VERIFIED' THEN
    RETURN jsonb_build_object('ok',false,'error','MEDIA_NOT_PUBLIC_VERIFIED');
  END IF;
  IF v_asset.public_url IS NULL OR v_asset.public_url !~ '^https://[^?]+$' THEN
    RETURN jsonb_build_object('ok',false,'error','MEDIA_PUBLIC_URL_INVALID');
  END IF;
  RETURN v_candidate||jsonb_build_object('asset_id',v_asset.id,'media_url',v_asset.public_url,
    'media_checksum',upper(v_asset.checksum_sha256),'content_type',v_asset.content_type,
    'size_bytes',v_asset.size_bytes,'dry_run',true,'external_mutation_allowed',false);
END; $$;

CREATE OR REPLACE FUNCTION social_media.evaluate_buffer_mutation_guard(
  p_credentials_available boolean,p_candidate_valid boolean,p_media_verified boolean,p_idempotency_ok boolean)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE v_provider text;v_live boolean;v_enabled boolean;v_dry boolean;
BEGIN
  SELECT config_value INTO v_provider FROM social_media.runtime_config WHERE config_key='social_publish_provider';
  SELECT config_value::boolean INTO v_live FROM social_media.runtime_config WHERE config_key='live_mode';
  SELECT config_value::boolean INTO v_enabled FROM social_media.runtime_config WHERE config_key='buffer_publish_enabled';
  SELECT config_value::boolean INTO v_dry FROM social_media.runtime_config WHERE config_key='buffer_dry_run';
  IF v_provider<>'buffer' THEN RETURN jsonb_build_object('ok',false,'error','SOCIAL_PUBLISH_PROVIDER_NOT_BUFFER','external_mutation_allowed',false); END IF;
  IF NOT COALESCE(v_live,false) THEN RETURN jsonb_build_object('ok',false,'error','LIVE_MODE_DISABLED','external_mutation_allowed',false); END IF;
  IF NOT COALESCE(v_enabled,false) THEN RETURN jsonb_build_object('ok',false,'error','BUFFER_PUBLISH_DISABLED','external_mutation_allowed',false); END IF;
  IF COALESCE(v_dry,true) THEN RETURN jsonb_build_object('ok',false,'error','BUFFER_DRY_RUN_ACTIVE','external_mutation_allowed',false); END IF;
  IF NOT COALESCE(p_credentials_available,false) THEN RETURN jsonb_build_object('ok',false,'error','BUFFER_CREDENTIALS_MISSING','external_mutation_allowed',false); END IF;
  IF NOT COALESCE(p_candidate_valid,false) THEN RETURN jsonb_build_object('ok',false,'error','PUBLICATION_CANDIDATE_INVALID','external_mutation_allowed',false); END IF;
  IF NOT COALESCE(p_media_verified,false) THEN RETURN jsonb_build_object('ok',false,'error','MEDIA_NOT_PUBLIC_VERIFIED','external_mutation_allowed',false); END IF;
  IF NOT COALESCE(p_idempotency_ok,false) THEN RETURN jsonb_build_object('ok',false,'error','IDEMPOTENCY_GUARD_FAILED','external_mutation_allowed',false); END IF;
  RETURN jsonb_build_object('ok',true,'external_mutation_allowed',true);
END; $$;

COMMENT ON TABLE social_media.publication_media_assets IS
  'Immutable copies of approved final art prepared for social distribution; never stores storage credentials.';
