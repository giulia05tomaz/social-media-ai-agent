-- Phase 8.2: Buffer GraphQL provider preparation. No post mutation is executed here.
ALTER TABLE social_media.social_accounts
  ADD COLUMN IF NOT EXISTS provider text NOT NULL DEFAULT 'meta_direct',
  ADD COLUMN IF NOT EXISTS provider_account_id text,
  ADD COLUMN IF NOT EXISTS provider_status text;

ALTER TABLE social_media.social_accounts DROP CONSTRAINT IF EXISTS social_accounts_platform_check;
ALTER TABLE social_media.social_accounts ADD CONSTRAINT social_accounts_platform_check
  CHECK(platform IN ('instagram','tiktok'));
ALTER TABLE social_media.social_accounts DROP CONSTRAINT IF EXISTS social_accounts_account_type_check;
ALTER TABLE social_media.social_accounts ADD CONSTRAINT social_accounts_account_type_check
  CHECK(account_type IS NULL OR account_type IN ('BUSINESS','CREATOR','PERSONAL','ACCOUNT','PROFESSIONAL','MOCK'));
ALTER TABLE social_media.social_accounts DROP CONSTRAINT IF EXISTS social_accounts_provider_check;
ALTER TABLE social_media.social_accounts ADD CONSTRAINT social_accounts_provider_check
  CHECK(provider IN ('mock','buffer','meta_direct','tiktok_direct'));

UPDATE social_media.social_accounts SET provider='mock',updated_at=now()
WHERE metadata->>'phase81_fixture'='true' AND provider<>'mock';

CREATE UNIQUE INDEX IF NOT EXISTS idx_social_account_provider_account
  ON social_media.social_accounts(provider,provider_account_id) WHERE provider_account_id IS NOT NULL;

ALTER TABLE social_media.publication_jobs
  ADD COLUMN IF NOT EXISTS provider_post_id text,
  ADD COLUMN IF NOT EXISTS provider_status text;
CREATE UNIQUE INDEX IF NOT EXISTS idx_publication_job_provider_post
  ON social_media.publication_jobs(provider,provider_post_id) WHERE provider_post_id IS NOT NULL;

INSERT INTO social_media.runtime_config(config_key,config_value) VALUES
 ('buffer_publish_enabled','false'),('buffer_api_url','https://api.buffer.com')
ON CONFLICT(config_key) DO UPDATE SET config_value=CASE
  WHEN EXCLUDED.config_key='buffer_publish_enabled' THEN 'false'
  ELSE social_media.runtime_config.config_value END,updated_at=now();

CREATE OR REPLACE FUNCTION social_media.evaluate_buffer_publish_guard(p_credentials_available boolean)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE v_provider text;v_live boolean;v_enabled boolean;
BEGIN
  SELECT config_value INTO v_provider FROM social_media.runtime_config WHERE config_key='social_publish_provider';
  SELECT config_value::boolean INTO v_live FROM social_media.runtime_config WHERE config_key='live_mode';
  SELECT config_value::boolean INTO v_enabled FROM social_media.runtime_config WHERE config_key='buffer_publish_enabled';
  IF v_provider<>'buffer' THEN RETURN jsonb_build_object('ok',false,'error','SOCIAL_PUBLISH_PROVIDER_NOT_BUFFER','external_mutation_allowed',false); END IF;
  IF NOT COALESCE(v_live,false) THEN RETURN jsonb_build_object('ok',false,'error','LIVE_MODE_DISABLED','external_mutation_allowed',false); END IF;
  IF NOT COALESCE(v_enabled,false) THEN RETURN jsonb_build_object('ok',false,'error','BUFFER_PUBLISH_DISABLED','external_mutation_allowed',false); END IF;
  IF NOT COALESCE(p_credentials_available,false) THEN RETURN jsonb_build_object('ok',false,'error','BUFFER_CREDENTIALS_MISSING','external_mutation_allowed',false); END IF;
  RETURN jsonb_build_object('ok',true,'external_mutation_allowed',true);
END; $$;

CREATE OR REPLACE FUNCTION social_media.validate_buffer_publication_candidate(p_schedule_id uuid,p_social_account_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE v record;v_caption text;
BEGIN
  SELECT s.*,c.approval_status,c.approved_version_id,cv.final_art_path,cv.copy,
    a.is_active,a.provider,a.provider_account_id,a.credential_reference,a.provider_status
  INTO v FROM social_media.content_schedule s
  JOIN social_media.content_items c ON c.content_id=s.content_id
  JOIN social_media.content_versions cv ON cv.id=s.version_id
  LEFT JOIN social_media.social_accounts a ON a.id=p_social_account_id
    AND a.client_id=s.client_id AND a.platform=s.platform
  WHERE s.id=p_schedule_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','SCHEDULE_NOT_FOUND'); END IF;
  IF v.status<>'READY_TO_PUBLISH' THEN RETURN jsonb_build_object('ok',false,'error','SCHEDULE_NOT_READY'); END IF;
  IF v.approval_status<>'APPROVED' THEN RETURN jsonb_build_object('ok',false,'error','CONTENT_NOT_APPROVED'); END IF;
  IF v.approved_version_id IS DISTINCT FROM v.version_id THEN RETURN jsonb_build_object('ok',false,'error','VERSION_NOT_APPROVED'); END IF;
  IF v.final_art_path IS NULL OR btrim(v.final_art_path)='' THEN RETURN jsonb_build_object('ok',false,'error','FINAL_ART_MISSING'); END IF;
  IF v.platform NOT IN ('instagram','tiktok') THEN RETURN jsonb_build_object('ok',false,'error','PLATFORM_NOT_SUPPORTED'); END IF;
  IF v.is_active IS DISTINCT FROM true THEN RETURN jsonb_build_object('ok',false,'error','SOCIAL_ACCOUNT_INACTIVE'); END IF;
  IF v.provider IS DISTINCT FROM 'buffer' THEN RETURN jsonb_build_object('ok',false,'error','BUFFER_ACCOUNT_REQUIRED'); END IF;
  IF v.provider_account_id IS NULL OR btrim(v.provider_account_id)='' THEN RETURN jsonb_build_object('ok',false,'error','BUFFER_CHANNEL_ID_MISSING'); END IF;
  IF COALESCE(v.provider_status,'connected')<>'connected' THEN RETURN jsonb_build_object('ok',false,'error','BUFFER_CHANNEL_DISCONNECTED'); END IF;
  v_caption:=social_media.build_instagram_caption(v.copy->>'caption',v.copy->'hashtags');
  RETURN jsonb_build_object('ok',true,'schedule_id',v.id,'client_id',v.client_id,'content_id',v.content_id,
    'version_id',v.version_id,'platform',v.platform,'social_account_id',p_social_account_id,'provider','buffer',
    'provider_account_id',v.provider_account_id,'caption',v_caption,'final_art_path',v.final_art_path,
    'credential_reference',v.credential_reference);
END; $$;

CREATE OR REPLACE FUNCTION social_media.prepare_buffer_publication_job(p_schedule_id uuid,p_social_account_id uuid)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_validation jsonb;v_job social_media.publication_jobs%ROWTYPE;v_corr uuid:=gen_random_uuid();
BEGIN
  PERFORM 1 FROM social_media.content_schedule WHERE id=p_schedule_id FOR UPDATE;
  v_validation:=social_media.validate_buffer_publication_candidate(p_schedule_id,p_social_account_id);
  IF NOT COALESCE((v_validation->>'ok')::boolean,false) THEN RETURN v_validation; END IF;
  INSERT INTO social_media.publication_jobs(schedule_id,client_id,content_id,version_id,social_account_id,platform,provider,status,metadata)
  VALUES(p_schedule_id,v_validation->>'client_id',v_validation->>'content_id',(v_validation->>'version_id')::uuid,
    p_social_account_id,v_validation->>'platform','buffer','VALIDATED',jsonb_build_object('phase','8.2','dry_run_only',true))
  ON CONFLICT(schedule_id,version_id,platform,social_account_id) DO UPDATE SET updated_at=now()
  RETURNING * INTO v_job;
  INSERT INTO social_media.events(correlation_id,client_id,content_id,event_type,workflow_name,details)
  VALUES(v_corr,v_job.client_id,v_job.content_id,'BUFFER_PUBLICATION_VALIDATED','08.2 - Buffer Provider',
    jsonb_build_object('publication_job_id',v_job.id,'schedule_id',p_schedule_id,'provider','buffer','status',v_job.status,'mutation_executed',false));
  RETURN v_validation||jsonb_build_object('publication_job_id',v_job.id,'job_status',v_job.status,
    'duplicate',v_job.created_at<v_job.updated_at);
END; $$;

COMMENT ON COLUMN social_media.social_accounts.provider_account_id IS 'Provider channel/account ID; never an access token.';
COMMENT ON COLUMN social_media.publication_jobs.provider_post_id IS 'Idempotency anchor returned by providers such as Buffer.';
