-- Phase 8.4: one-shot Buffer release for the first controlled Instagram publication.
-- This migration never releases a job by itself.

ALTER TABLE social_media.publication_jobs
  DROP CONSTRAINT IF EXISTS publication_jobs_status_check;
ALTER TABLE social_media.publication_jobs
  ADD CONSTRAINT publication_jobs_status_check CHECK(status IN (
    'QUEUED','VALIDATING','VALIDATED','MEDIA_EXPOSING','CONTAINER_CREATING','CONTAINER_CREATED',
    'CONTAINER_PROCESSING','READY_FOR_PUBLISH','PUBLISHING','MOCK_PUBLISHED','PUBLISHED','FAILED',
    'RETRYABLE','CANCELLED','DRY_RUN_READY','DRY_RUN_COMPLETED','PUBLICATION_CONFIRMATION_PENDING'
  ));

INSERT INTO social_media.runtime_config(config_key,config_value) VALUES
 ('demo_mode','true'),
 ('live_mode','false'),
 ('social_publish_provider','mock'),
 ('buffer_publish_enabled','false'),
 ('buffer_dry_run','true'),
 ('publication_worker_enabled','false'),
 ('instagram_publish_enabled','false')
ON CONFLICT(config_key) DO UPDATE
SET config_value=EXCLUDED.config_value,updated_at=now();

CREATE OR REPLACE FUNCTION social_media.authorize_first_live_publication(p_publication_job_id uuid)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v record;v_candidates integer;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended(p_publication_job_id::text,840));
  SELECT pj.*,s.status AS schedule_status,c.approval_status,c.approved_version_id,
         sa.username,sa.is_active,sa.provider_status AS account_status
  INTO v
  FROM social_media.publication_jobs pj
  JOIN social_media.content_schedule s ON s.id=pj.schedule_id
  JOIN social_media.content_items c ON c.content_id=pj.content_id
  JOIN social_media.social_accounts sa ON sa.id=pj.social_account_id
  WHERE pj.id=p_publication_job_id
  FOR UPDATE OF pj;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','PUBLICATION_JOB_NOT_FOUND'); END IF;
  IF v.provider<>'buffer' OR v.platform<>'instagram' THEN
    RETURN jsonb_build_object('ok',false,'error','PUBLICATION_PLATFORM_NOT_AUTHORIZED');
  END IF;
  IF NULLIF(btrim(v.username),'') IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error','FIRST_LIVE_TARGET_ACCOUNT_MISSING');
  END IF;
  IF v.is_active IS DISTINCT FROM true OR v.account_status<>'connected' THEN
    RETURN jsonb_build_object('ok',false,'error','BUFFER_CHANNEL_INVALID');
  END IF;
  IF v.schedule_status<>'READY_TO_PUBLISH' OR v.approval_status<>'APPROVED'
     OR v.approved_version_id IS DISTINCT FROM v.version_id THEN
    RETURN jsonb_build_object('ok',false,'error','PUBLICATION_VERSION_NOT_APPROVED');
  END IF;
  IF v.status<>'DRY_RUN_COMPLETED' OR v.release_status<>'HOLD' THEN
    RETURN jsonb_build_object('ok',false,'error','FIRST_LIVE_RELEASE_INVALID');
  END IF;
  IF v.provider_post_id IS NOT NULL OR v.attempt_count<>0 THEN
    RETURN jsonb_build_object('ok',false,'error','FIRST_LIVE_MUTATION_ALREADY_ATTEMPTED');
  END IF;
  IF v.provider_payload_hash IS NULL OR btrim(v.provider_payload_hash)='' THEN
    RETURN jsonb_build_object('ok',false,'error','FIRST_LIVE_PREFLIGHT_MISSING');
  END IF;

  SELECT count(*) INTO v_candidates
  FROM social_media.publication_jobs pj
  JOIN social_media.content_schedule s ON s.id=pj.schedule_id
  JOIN social_media.content_items c ON c.content_id=pj.content_id
  JOIN social_media.social_accounts sa ON sa.id=pj.social_account_id
  JOIN social_media.publication_media_assets a ON a.version_id=pj.version_id AND a.storage_provider='r2'
  WHERE pj.provider='buffer' AND pj.platform='instagram' AND pj.status='DRY_RUN_COMPLETED'
    AND pj.release_status='HOLD' AND pj.provider_post_id IS NULL AND pj.attempt_count=0
    AND s.status='READY_TO_PUBLISH' AND c.approval_status='APPROVED'
    AND c.approved_version_id=pj.version_id AND sa.is_active=true AND sa.provider_status='connected'
    AND pj.social_account_id=v.social_account_id AND a.status='PUBLIC_VERIFIED';
  IF v_candidates<>1 THEN
    RETURN jsonb_build_object('ok',false,'error','FIRST_LIVE_CANDIDATE_COUNT_INVALID','candidate_count',v_candidates);
  END IF;

  UPDATE social_media.publication_jobs
  SET release_status='RELEASED',publication_authorized_at=now(),updated_at=now(),
      metadata=metadata||jsonb_build_object(
        'phase','8.4','authorized_by','user','authorized_scope','single_instagram_publication',
        'authorized_target',v.username,'authorized_at',now(),'one_shot',true)
  WHERE id=p_publication_job_id;
  INSERT INTO social_media.events(client_id,content_id,event_type,workflow_name,details)
  VALUES(v.client_id,v.content_id,'FIRST_LIVE_PUBLICATION_AUTHORIZED','08.4 - First Live Publication',
    jsonb_build_object('publication_job_id',p_publication_job_id,'authorized_by','user',
      'authorized_scope','single_instagram_publication','authorized_target',v.username));
  RETURN jsonb_build_object('ok',true,'publication_job_id',p_publication_job_id,
    'release_status','RELEASED','authorized_scope','single_instagram_publication',
    'authorized_target',v.username);
END; $$;

COMMENT ON FUNCTION social_media.authorize_first_live_publication(uuid) IS
  'Explicit one-shot release. Reexecution is blocked after release or any mutation attempt.';
