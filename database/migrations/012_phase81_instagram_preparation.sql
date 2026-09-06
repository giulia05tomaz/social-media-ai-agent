-- Phase 8.1: safe Instagram publication preparation. No external calls or real publishing.
CREATE TABLE IF NOT EXISTS social_media.social_accounts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id text NOT NULL REFERENCES social_media.clients(client_id),
  platform text NOT NULL,
  external_account_id text,
  username text,
  account_type text,
  credential_reference text,
  is_active boolean NOT NULL DEFAULT false,
  is_default boolean NOT NULL DEFAULT false,
  capabilities jsonb NOT NULL DEFAULT '{"image_post":true,"carousel":"future","reels":"future","stories":"future"}'::jsonb,
  token_type text,
  token_expires_at timestamptz,
  refresh_strategy text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK(platform IN ('instagram')),
  CHECK(account_type IS NULL OR account_type IN ('BUSINESS','CREATOR','PERSONAL','MOCK'))
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_social_account_external ON social_media.social_accounts(platform,external_account_id) WHERE external_account_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_social_account_default ON social_media.social_accounts(client_id,platform) WHERE is_default AND is_active;

CREATE TABLE IF NOT EXISTS social_media.publication_jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  schedule_id uuid NOT NULL REFERENCES social_media.content_schedule(id),
  client_id text NOT NULL REFERENCES social_media.clients(client_id),
  content_id text NOT NULL REFERENCES social_media.content_items(content_id),
  version_id uuid NOT NULL REFERENCES social_media.content_versions(id),
  social_account_id uuid NOT NULL REFERENCES social_media.social_accounts(id),
  platform text NOT NULL,
  provider text NOT NULL,
  status text NOT NULL DEFAULT 'QUEUED',
  attempt_count integer NOT NULL DEFAULT 0,
  media_container_id text,
  external_media_id text,
  media_url text,
  file_checksum text,
  error_code text,
  error_message text,
  next_attempt_at timestamptz,
  started_at timestamptz,
  published_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  CHECK(status IN ('QUEUED','VALIDATING','VALIDATED','MEDIA_EXPOSING','CONTAINER_CREATING','CONTAINER_CREATED','CONTAINER_PROCESSING','READY_FOR_PUBLISH','PUBLISHING','MOCK_PUBLISHED','PUBLISHED','FAILED','RETRYABLE','CANCELLED')),
  UNIQUE(schedule_id,version_id,platform,social_account_id)
);
CREATE INDEX IF NOT EXISTS idx_publication_jobs_status ON social_media.publication_jobs(status,next_attempt_at,created_at);

CREATE TABLE IF NOT EXISTS social_media.media_delivery_tokens (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  publication_job_id uuid NOT NULL REFERENCES social_media.publication_jobs(id),
  token_hash text NOT NULL UNIQUE,
  final_art_path text NOT NULL,
  file_checksum text NOT NULL,
  expires_at timestamptz NOT NULL,
  revoked_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  last_accessed_at timestamptz,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX IF NOT EXISTS idx_media_delivery_expiry ON social_media.media_delivery_tokens(expires_at) WHERE revoked_at IS NULL;

INSERT INTO social_media.runtime_config(config_key,config_value) VALUES
 ('social_publish_provider','mock'),
 ('instagram_publish_enabled','false'),
 ('instagram_api_version','v26.0'),
 ('media_url_ttl_minutes','30'),
 ('publish_max_attempts','3'),
 ('publish_retry_base_seconds','60')
ON CONFLICT(config_key) DO UPDATE SET config_value=CASE
  WHEN EXCLUDED.config_key IN ('social_publish_provider','instagram_publish_enabled') THEN EXCLUDED.config_value
  ELSE social_media.runtime_config.config_value END,updated_at=now();

CREATE OR REPLACE FUNCTION social_media.build_instagram_caption(p_caption text,p_hashtags jsonb)
RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE v_caption text:=btrim(COALESCE(p_caption,''));v_tag text;v_result text;
BEGIN
  v_result:=v_caption;
  IF jsonb_typeof(COALESCE(p_hashtags,'[]'::jsonb))='array' THEN
    FOR v_tag IN SELECT btrim(value) FROM jsonb_array_elements_text(p_hashtags) LOOP
      IF v_tag<>'' AND position(lower(v_tag) in lower(v_result))=0 THEN
        v_result:=v_result||CASE WHEN v_result='' THEN '' ELSE E'\n\n' END||v_tag;
      END IF;
    END LOOP;
  END IF;
  IF char_length(v_result)>2200 THEN RAISE EXCEPTION 'CAPTION_TOO_LONG' USING ERRCODE='22001'; END IF;
  RETURN v_result;
END; $$;

CREATE OR REPLACE FUNCTION social_media.validate_publication_candidate(p_schedule_id uuid,p_social_account_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE v record;v_caption text;
BEGIN
  SELECT s.*,c.approval_status,c.approved_version_id,cv.final_art_path,cv.copy,a.is_active,a.account_type,a.external_account_id,a.credential_reference
  INTO v FROM social_media.content_schedule s
  JOIN social_media.content_items c ON c.content_id=s.content_id
  JOIN social_media.content_versions cv ON cv.id=s.version_id
  LEFT JOIN social_media.social_accounts a ON a.id=p_social_account_id AND a.client_id=s.client_id AND a.platform=s.platform
  WHERE s.id=p_schedule_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','SCHEDULE_NOT_FOUND'); END IF;
  IF v.status<>'READY_TO_PUBLISH' THEN RETURN jsonb_build_object('ok',false,'error','SCHEDULE_NOT_READY'); END IF;
  IF v.approval_status<>'APPROVED' THEN RETURN jsonb_build_object('ok',false,'error','CONTENT_NOT_APPROVED'); END IF;
  IF v.approved_version_id IS DISTINCT FROM v.version_id THEN RETURN jsonb_build_object('ok',false,'error','VERSION_NOT_APPROVED'); END IF;
  IF v.final_art_path IS NULL OR btrim(v.final_art_path)='' THEN RETURN jsonb_build_object('ok',false,'error','FINAL_ART_MISSING'); END IF;
  IF v.platform<>'instagram' THEN RETURN jsonb_build_object('ok',false,'error','PLATFORM_NOT_SUPPORTED'); END IF;
  IF v.is_active IS DISTINCT FROM true THEN RETURN jsonb_build_object('ok',false,'error','SOCIAL_ACCOUNT_INACTIVE'); END IF;
  IF v.account_type NOT IN ('BUSINESS','CREATOR','MOCK') THEN RETURN jsonb_build_object('ok',false,'error','INSTAGRAM_ACCOUNT_NOT_PROFESSIONAL'); END IF;
  BEGIN v_caption:=social_media.build_instagram_caption(v.copy->>'caption',v.copy->'hashtags');
  EXCEPTION WHEN string_data_right_truncation THEN RETURN jsonb_build_object('ok',false,'error','CAPTION_TOO_LONG'); END;
  RETURN jsonb_build_object('ok',true,'schedule_id',v.id,'client_id',v.client_id,'content_id',v.content_id,
    'version_id',v.version_id,'platform',v.platform,'social_account_id',p_social_account_id,
    'instagram_user_id',v.external_account_id,'caption',v_caption,'final_art_path',v.final_art_path,
    'credential_reference',v.credential_reference);
END; $$;

CREATE OR REPLACE FUNCTION social_media.prepare_publication_job(p_schedule_id uuid,p_social_account_id uuid,p_provider text DEFAULT 'mock')
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_validation jsonb;v_job social_media.publication_jobs%ROWTYPE;v_corr uuid:=gen_random_uuid();
BEGIN
  PERFORM 1 FROM social_media.content_schedule WHERE id=p_schedule_id FOR UPDATE;
  v_validation:=social_media.validate_publication_candidate(p_schedule_id,p_social_account_id);
  IF NOT COALESCE((v_validation->>'ok')::boolean,false) THEN RETURN v_validation; END IF;
  INSERT INTO social_media.publication_jobs(schedule_id,client_id,content_id,version_id,social_account_id,platform,provider,status,metadata)
  VALUES(p_schedule_id,v_validation->>'client_id',v_validation->>'content_id',(v_validation->>'version_id')::uuid,p_social_account_id,
    v_validation->>'platform',lower(COALESCE(p_provider,'mock')),'VALIDATED',jsonb_build_object('phase','8.1','mock_only',true))
  ON CONFLICT(schedule_id,version_id,platform,social_account_id) DO UPDATE SET updated_at=now()
  RETURNING * INTO v_job;
  INSERT INTO social_media.events(correlation_id,client_id,content_id,event_type,workflow_name,details)
  VALUES(v_corr,v_job.client_id,v_job.content_id,'PUBLICATION_VALIDATED','08 - Instagram Publication Orchestrator',
    jsonb_build_object('publication_job_id',v_job.id,'schedule_id',p_schedule_id,'provider',v_job.provider,'status',v_job.status))
  ON CONFLICT DO NOTHING;
  RETURN v_validation||jsonb_build_object('publication_job_id',v_job.id,'job_status',v_job.status,'provider',v_job.provider,
    'duplicate',v_job.created_at<v_job.updated_at);
END; $$;

CREATE OR REPLACE FUNCTION social_media.evaluate_instagram_publish_guard(p_credentials_available boolean)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE v_provider text;v_live boolean;v_enabled boolean;
BEGIN
  SELECT config_value INTO v_provider FROM social_media.runtime_config WHERE config_key='social_publish_provider';
  SELECT config_value::boolean INTO v_live FROM social_media.runtime_config WHERE config_key='live_mode';
  SELECT config_value::boolean INTO v_enabled FROM social_media.runtime_config WHERE config_key='instagram_publish_enabled';
  IF v_provider<>'instagram' THEN RETURN jsonb_build_object('ok',false,'error','SOCIAL_PUBLISH_PROVIDER_NOT_INSTAGRAM','external_request_allowed',false); END IF;
  IF NOT COALESCE(v_live,false) THEN RETURN jsonb_build_object('ok',false,'error','LIVE_MODE_DISABLED','external_request_allowed',false); END IF;
  IF NOT COALESCE(v_enabled,false) THEN RETURN jsonb_build_object('ok',false,'error','INSTAGRAM_PUBLISH_DISABLED','external_request_allowed',false); END IF;
  IF NOT COALESCE(p_credentials_available,false) THEN RETURN jsonb_build_object('ok',false,'error','INSTAGRAM_CREDENTIALS_MISSING','external_request_allowed',false); END IF;
  RETURN jsonb_build_object('ok',true,'external_request_allowed',true);
END; $$;

CREATE OR REPLACE FUNCTION social_media.advance_mock_publication(p_job_id uuid,p_media_url text,p_checksum text,p_fail_after_container boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_job social_media.publication_jobs%ROWTYPE;v_container text;v_external text;v_recovered boolean:=false;v_corr uuid:=gen_random_uuid();
BEGIN
  SELECT * INTO v_job FROM social_media.publication_jobs WHERE id=p_job_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','PUBLICATION_JOB_NOT_FOUND'); END IF;
  IF v_job.provider<>'mock' THEN RETURN jsonb_build_object('ok',false,'error','MOCK_PROVIDER_REQUIRED'); END IF;
  IF v_job.status='MOCK_PUBLISHED' THEN RETURN jsonb_build_object('ok',true,'duplicate',true,'publication_job_id',v_job.id,'status',v_job.status,'external_media_id',v_job.external_media_id); END IF;
  v_container:=v_job.media_container_id;
  IF v_container IS NULL THEN v_container:='mock-container-'||replace(gen_random_uuid()::text,'-','');
  ELSE v_recovered:=true; END IF;
  UPDATE social_media.publication_jobs SET status='CONTAINER_CREATED',attempt_count=attempt_count+1,started_at=COALESCE(started_at,now()),
    media_container_id=v_container,media_url=p_media_url,file_checksum=p_checksum,updated_at=now(),metadata=metadata||jsonb_build_object('provider','mock') WHERE id=p_job_id;
  IF p_fail_after_container THEN
    RETURN jsonb_build_object('ok',false,'retryable',true,'error','MOCK_INTERRUPTED_AFTER_CONTAINER','publication_job_id',p_job_id,'media_container_id',v_container,'status','CONTAINER_CREATED');
  END IF;
  v_external:='mock-media-'||replace(gen_random_uuid()::text,'-','');
  UPDATE social_media.publication_jobs SET status='MOCK_PUBLISHED',external_media_id=v_external,published_at=now(),updated_at=now() WHERE id=p_job_id;
  INSERT INTO social_media.events(correlation_id,client_id,content_id,event_type,workflow_name,details)
  VALUES(v_corr,v_job.client_id,v_job.content_id,'MOCK_CONTENT_PUBLISHED','08 - Instagram Publication Orchestrator',
    jsonb_build_object('publication_job_id',p_job_id,'provider','mock','media_container_id',v_container,'external_media_id',v_external,'recovered',v_recovered));
  RETURN jsonb_build_object('ok',true,'publication_job_id',p_job_id,'status','MOCK_PUBLISHED','provider','mock',
    'media_container_id',v_container,'external_media_id',v_external,'recovered',v_recovered,'real_published',false);
END; $$;

COMMENT ON TABLE social_media.publication_jobs IS 'Phase 8 publication state; MOCK_PUBLISHED never changes schedule/content to PUBLISHED.';
