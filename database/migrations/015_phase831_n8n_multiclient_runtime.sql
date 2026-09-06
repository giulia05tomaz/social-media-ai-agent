-- Phase 8.3.1: generic multi-client publication runtime. Dry-run only.
ALTER TABLE social_media.publication_jobs
  ADD COLUMN IF NOT EXISTS release_status text NOT NULL DEFAULT 'HOLD',
  ADD COLUMN IF NOT EXISTS publication_authorized_at timestamptz,
  ADD COLUMN IF NOT EXISTS dry_run_at timestamptz,
  ADD COLUMN IF NOT EXISTS provider_payload_hash text,
  ADD COLUMN IF NOT EXISTS claimed_at timestamptz,
  ADD COLUMN IF NOT EXISTS claim_token uuid;

ALTER TABLE social_media.publication_jobs
  DROP CONSTRAINT IF EXISTS publication_jobs_status_check;
ALTER TABLE social_media.publication_jobs
  ADD CONSTRAINT publication_jobs_status_check CHECK(status IN (
    'QUEUED','VALIDATING','VALIDATED','MEDIA_EXPOSING','CONTAINER_CREATING','CONTAINER_CREATED',
    'CONTAINER_PROCESSING','READY_FOR_PUBLISH','PUBLISHING','MOCK_PUBLISHED','PUBLISHED','FAILED',
    'RETRYABLE','CANCELLED','DRY_RUN_READY','DRY_RUN_COMPLETED'
  ));
ALTER TABLE social_media.publication_jobs
  DROP CONSTRAINT IF EXISTS publication_jobs_release_status_check;
ALTER TABLE social_media.publication_jobs
  ADD CONSTRAINT publication_jobs_release_status_check
  CHECK(release_status IN ('HOLD','RELEASED','CONSUMED','REVOKED'));

CREATE INDEX IF NOT EXISTS idx_publication_jobs_release
  ON social_media.publication_jobs(release_status,status,created_at);

INSERT INTO social_media.runtime_config(config_key,config_value) VALUES
 ('publication_worker_enabled','false'),
 ('buffer_dry_run','true')
ON CONFLICT(config_key) DO UPDATE SET config_value=CASE
  WHEN EXCLUDED.config_key IN ('publication_worker_enabled','buffer_dry_run') THEN EXCLUDED.config_value
  ELSE social_media.runtime_config.config_value END,updated_at=now();

CREATE OR REPLACE FUNCTION social_media.resolve_social_account(
  p_client_id text,p_platform text,p_provider text DEFAULT 'buffer')
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE v_count integer;v_default_count integer;v social_media.social_accounts%ROWTYPE;
BEGIN
  SELECT count(*),count(*) FILTER(WHERE is_default)
  INTO v_count,v_default_count
  FROM social_media.social_accounts
  WHERE client_id=p_client_id AND platform=lower(p_platform) AND provider=lower(p_provider)
    AND is_active=true AND COALESCE(provider_status,'connected')='connected';
  IF v_count=0 THEN
    RETURN jsonb_build_object('ok',false,'error','SOCIAL_ACCOUNT_NOT_AVAILABLE');
  END IF;
  IF v_count>1 AND v_default_count<>1 THEN
    RETURN jsonb_build_object('ok',false,'error','SOCIAL_ACCOUNT_AMBIGUOUS');
  END IF;
  SELECT * INTO v FROM social_media.social_accounts
  WHERE client_id=p_client_id AND platform=lower(p_platform) AND provider=lower(p_provider)
    AND is_active=true AND COALESCE(provider_status,'connected')='connected'
  ORDER BY is_default DESC
  LIMIT 1;
  RETURN jsonb_build_object(
    'ok',true,'social_account_id',v.id,'client_id',v.client_id,'platform',v.platform,
    'provider',v.provider,'provider_account_id',v.provider_account_id,'username',v.username,
    'credential_reference',v.credential_reference,'is_default',v.is_default
  );
END; $$;

CREATE OR REPLACE FUNCTION social_media.validate_publication_runtime_input(
  p_schedule_id uuid,p_client_id text,p_content_id text,p_version_id uuid,p_platform text)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE v record;v_account jsonb;v_media jsonb;v_caption text;
BEGIN
  SELECT s.id,s.client_id schedule_client_id,s.content_id schedule_content_id,s.version_id schedule_version_id,
    s.platform,s.status,c.client_id content_client_id,c.approval_status,c.approved_version_id,
    cv.content_id version_content_id,cv.copy
  INTO v
  FROM social_media.content_schedule s
  JOIN social_media.content_items c ON c.content_id=s.content_id
  JOIN social_media.content_versions cv ON cv.id=s.version_id
  WHERE s.id=p_schedule_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','SCHEDULE_NOT_FOUND'); END IF;
  IF v.schedule_client_id<>p_client_id OR v.content_client_id<>p_client_id THEN
    RETURN jsonb_build_object('ok',false,'error','CROSS_CLIENT_PUBLICATION_BLOCKED');
  END IF;
  IF v.schedule_content_id<>p_content_id OR v.version_content_id<>p_content_id OR v.schedule_version_id<>p_version_id THEN
    RETURN jsonb_build_object('ok',false,'error','PUBLICATION_RELATION_MISMATCH');
  END IF;
  IF v.platform<>lower(p_platform) THEN RETURN jsonb_build_object('ok',false,'error','PUBLICATION_PLATFORM_MISMATCH'); END IF;
  IF v.status<>'READY_TO_PUBLISH' THEN RETURN jsonb_build_object('ok',false,'error','PUBLICATION_NOT_READY'); END IF;
  IF v.approval_status<>'APPROVED' OR v.approved_version_id IS DISTINCT FROM p_version_id THEN
    RETURN jsonb_build_object('ok',false,'error','PUBLICATION_VERSION_NOT_APPROVED');
  END IF;
  v_account:=social_media.resolve_social_account(p_client_id,p_platform,'buffer');
  IF NOT COALESCE((v_account->>'ok')::boolean,false) THEN RETURN v_account; END IF;
  IF lower(p_platform)='tiktok' THEN
    RETURN jsonb_build_object('ok',false,'error','TIKTOK_MEDIA_NOT_SUPPORTED_YET',
      'client_id',p_client_id,'platform','tiktok','social_account_id',v_account->>'social_account_id');
  END IF;
  v_media:=social_media.validate_publication_media_version(p_version_id);
  IF NOT COALESCE((v_media->>'ok')::boolean,false) THEN RETURN v_media; END IF;
  IF v_media->>'client_id'<>p_client_id THEN
    RETURN jsonb_build_object('ok',false,'error','CROSS_CLIENT_PUBLICATION_BLOCKED');
  END IF;
  v_caption:=social_media.build_instagram_caption(v.copy->>'caption',v.copy->'hashtags');
  RETURN v_media||v_account||jsonb_build_object(
    'ok',true,'schedule_id',p_schedule_id,'content_id',p_content_id,'version_id',p_version_id,
    'client_id',p_client_id,'platform',lower(p_platform),'caption',v_caption,
    'hashtags',COALESCE(v.copy->'hashtags','[]'::jsonb),'provider','buffer'
  );
END; $$;

CREATE OR REPLACE FUNCTION social_media.prepare_publication_runtime_job(
  p_schedule_id uuid,p_client_id text,p_content_id text,p_version_id uuid,p_platform text)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_validation jsonb;v_job social_media.publication_jobs%ROWTYPE;v_account_id uuid;v_duplicate boolean;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended(p_schedule_id::text,831));
  PERFORM 1 FROM social_media.content_schedule WHERE id=p_schedule_id FOR UPDATE;
  v_validation:=social_media.validate_publication_runtime_input(
    p_schedule_id,p_client_id,p_content_id,p_version_id,p_platform);
  IF NOT COALESCE((v_validation->>'ok')::boolean,false) THEN RETURN v_validation; END IF;
  v_account_id:=(v_validation->>'social_account_id')::uuid;
  SELECT * INTO v_job FROM social_media.publication_jobs
  WHERE schedule_id=p_schedule_id AND version_id=p_version_id AND platform=lower(p_platform)
    AND social_account_id=v_account_id
  FOR UPDATE;
  IF FOUND AND (v_job.attempt_count>0 OR v_job.release_status<>'HOLD' OR v_job.provider_post_id IS NOT NULL) THEN
    RETURN jsonb_build_object('ok',false,'error','PUBLICATION_JOB_TERMINAL',
      'publication_job_id',v_job.id,'job_status',v_job.status,'release_status',v_job.release_status);
  END IF;
  SELECT EXISTS(SELECT 1 FROM social_media.publication_jobs
    WHERE schedule_id=p_schedule_id AND version_id=p_version_id AND platform=lower(p_platform)
      AND social_account_id=v_account_id) INTO v_duplicate;
  INSERT INTO social_media.publication_jobs(
    schedule_id,client_id,content_id,version_id,social_account_id,platform,provider,status,
    release_status,claimed_at,claim_token,metadata)
  VALUES(p_schedule_id,p_client_id,p_content_id,p_version_id,v_account_id,lower(p_platform),'buffer',
    'DRY_RUN_READY','HOLD',now(),gen_random_uuid(),jsonb_build_object('phase','8.3.1','dry_run_only',true))
  ON CONFLICT(schedule_id,version_id,platform,social_account_id) DO UPDATE SET
    claimed_at=now(),claim_token=COALESCE(social_media.publication_jobs.claim_token,gen_random_uuid()),updated_at=now()
  RETURNING * INTO v_job;
  INSERT INTO social_media.events(client_id,content_id,event_type,workflow_name,details)
  VALUES(p_client_id,p_content_id,'PUBLICATION_RUNTIME_STARTED','08 - Social Publication Orchestrator',
    jsonb_build_object('publication_job_id',v_job.id,'schedule_id',p_schedule_id,'platform',lower(p_platform),'duplicate',v_duplicate));
  INSERT INTO social_media.events(client_id,content_id,event_type,workflow_name,details)
  VALUES(p_client_id,p_content_id,'PUBLICATION_ACCOUNT_RESOLVED','08 - Social Publication Orchestrator',
    jsonb_build_object('publication_job_id',v_job.id,'social_account_id',v_account_id,'provider','buffer'));
  RETURN v_validation||jsonb_build_object('publication_job_id',v_job.id,'job_status',v_job.status,
    'release_status',v_job.release_status,'duplicate',v_duplicate);
END; $$;

CREATE OR REPLACE FUNCTION social_media.enforce_publication_job_tenant()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_schedule_client text;v_schedule_content text;v_schedule_version uuid;v_schedule_platform text;
  v_content_client text;v_version_content text;v_account_client text;v_account_platform text;
BEGIN
  SELECT client_id,content_id,version_id,platform INTO v_schedule_client,v_schedule_content,v_schedule_version,v_schedule_platform
  FROM social_media.content_schedule WHERE id=NEW.schedule_id;
  SELECT client_id INTO v_content_client FROM social_media.content_items WHERE content_id=NEW.content_id;
  SELECT content_id INTO v_version_content FROM social_media.content_versions WHERE id=NEW.version_id;
  SELECT client_id,platform INTO v_account_client,v_account_platform FROM social_media.social_accounts WHERE id=NEW.social_account_id;
  IF NEW.client_id IS DISTINCT FROM v_schedule_client OR NEW.client_id IS DISTINCT FROM v_content_client
    OR NEW.client_id IS DISTINCT FROM v_account_client OR NEW.content_id IS DISTINCT FROM v_schedule_content
    OR NEW.content_id IS DISTINCT FROM v_version_content OR NEW.version_id IS DISTINCT FROM v_schedule_version
    OR NEW.platform IS DISTINCT FROM v_schedule_platform OR NEW.platform IS DISTINCT FROM v_account_platform THEN
    RAISE EXCEPTION 'CROSS_CLIENT_PUBLICATION_BLOCKED' USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS trg_publication_job_tenant ON social_media.publication_jobs;
CREATE TRIGGER trg_publication_job_tenant BEFORE INSERT OR UPDATE OF
  schedule_id,client_id,content_id,version_id,social_account_id,platform
ON social_media.publication_jobs FOR EACH ROW EXECUTE FUNCTION social_media.enforce_publication_job_tenant();

COMMENT ON COLUMN social_media.publication_jobs.release_status IS
  'Explicit release gate. READY_TO_PUBLISH alone never authorizes the first live publication.';
