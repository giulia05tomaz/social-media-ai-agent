-- Phase 7: internal editorial calendar and publication queue (no external publishing).
ALTER TABLE social_media.content_schedule
  ADD COLUMN IF NOT EXISTS version_id uuid REFERENCES social_media.content_versions(id),
  ADD COLUMN IF NOT EXISTS scheduled_at timestamptz,
  ADD COLUMN IF NOT EXISTS source text NOT NULL DEFAULT 'conversation',
  ADD COLUMN IF NOT EXISTS request_message_id uuid REFERENCES social_media.messages(message_id),
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS published_at timestamptz,
  ADD COLUMN IF NOT EXISTS metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS failure_reason text;

UPDATE social_media.content_schedule
SET scheduled_at = (scheduled_date + scheduled_time) AT TIME ZONE timezone
WHERE scheduled_at IS NULL;

UPDATE social_media.content_schedule s
SET version_id = COALESCE(c.approved_version_id,c.current_version_id)
FROM social_media.content_items c
WHERE c.content_id=s.content_id AND s.version_id IS NULL;

ALTER TABLE social_media.content_schedule
  ALTER COLUMN version_id SET NOT NULL,
  ALTER COLUMN scheduled_at SET NOT NULL;

ALTER TABLE social_media.content_schedule DROP CONSTRAINT IF EXISTS content_schedule_content_id_platform_key;
ALTER TABLE social_media.content_schedule DROP CONSTRAINT IF EXISTS content_schedule_status_check;
ALTER TABLE social_media.content_schedule ADD CONSTRAINT content_schedule_status_check
  CHECK (status IN ('SCHEDULED','READY_TO_PUBLISH','CANCELLED','MISSED','FAILED','PUBLISHED'));
ALTER TABLE social_media.content_schedule DROP CONSTRAINT IF EXISTS content_schedule_source_check;
ALTER TABLE social_media.content_schedule ADD CONSTRAINT content_schedule_source_check
  -- Keep the predecessor migration replay-safe after Phase 7.1 has classified
  -- existing rows more precisely. Migration 010 normalizes legacy values and
  -- installs the same final constraint after replacing the domain functions.
  CHECK (source IN (
    'conversation','approval','explicit_request','editorial_slot','admin',
    'approval_with_explicit_schedule','approval_with_editorial_slot','reschedule_request'
  ));

DROP INDEX IF EXISTS social_media.idx_schedule_due;
CREATE INDEX IF NOT EXISTS idx_schedule_due_at
  ON social_media.content_schedule(status,scheduled_at);
CREATE INDEX IF NOT EXISTS idx_schedule_content_version
  ON social_media.content_schedule(content_id,version_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_schedule_active_content_platform
  ON social_media.content_schedule(content_id,platform)
  WHERE status IN ('SCHEDULED','READY_TO_PUBLISH');
CREATE UNIQUE INDEX IF NOT EXISTS idx_schedule_active_slot
  ON social_media.content_schedule(client_id,platform,scheduled_at)
  WHERE status IN ('SCHEDULED','READY_TO_PUBLISH');

CREATE TABLE IF NOT EXISTS social_media.editorial_slots (
  slot_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id text NOT NULL REFERENCES social_media.clients(client_id),
  platform text NOT NULL,
  day_of_week smallint NOT NULL CHECK(day_of_week BETWEEN 0 AND 6),
  local_time time NOT NULL,
  timezone text NOT NULL DEFAULT 'America/Sao_Paulo',
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(client_id,platform,day_of_week,local_time)
);

CREATE TABLE IF NOT EXISTS social_media.schedule_history (
  history_id bigserial PRIMARY KEY,
  schedule_id uuid REFERENCES social_media.content_schedule(id),
  content_id text NOT NULL REFERENCES social_media.content_items(content_id),
  version_id uuid REFERENCES social_media.content_versions(id),
  message_id uuid REFERENCES social_media.messages(message_id),
  action text NOT NULL CHECK(action IN ('CREATED','RESCHEDULED','CANCELLED','READY_TO_PUBLISH','MISSED','FAILED')),
  old_scheduled_at timestamptz,
  new_scheduled_at timestamptz,
  old_status text,
  new_status text,
  requested_by text,
  reason text,
  details jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_schedule_history_content ON social_media.schedule_history(content_id,created_at DESC);

INSERT INTO social_media.editorial_slots(client_id,platform,day_of_week,local_time,timezone)
VALUES
 ('webtech-demo','instagram',1,'12:00','America/Sao_Paulo'),
 ('webtech-demo','instagram',3,'18:00','America/Sao_Paulo'),
 ('webtech-demo','instagram',5,'18:00','America/Sao_Paulo')
ON CONFLICT(client_id,platform,day_of_week,local_time) DO UPDATE
SET timezone=EXCLUDED.timezone,active=true,updated_at=now();

INSERT INTO social_media.channel_identities(client_id,channel,external_sender_id)
VALUES ('webtech-demo','admin','demo-admin')
ON CONFLICT(channel,external_sender_id) DO UPDATE SET client_id=EXCLUDED.client_id,active=true;

INSERT INTO social_media.runtime_config(config_key,config_value)
VALUES
 ('schedule_ai_provider','mock'),
 ('schedule_ai_model','mock-schedule-v1'),
 ('schedule_late_tolerance_minutes','30'),
 ('default_timezone','America/Sao_Paulo'),
 ('demo_mode','true'),
 ('live_mode','false')
ON CONFLICT(config_key) DO UPDATE SET config_value=EXCLUDED.config_value,updated_at=now();

CREATE OR REPLACE FUNCTION social_media.next_available_editorial_slot(
  p_client_id text,p_platform text,p_after timestamptz DEFAULT now(),p_exclude_schedule uuid DEFAULT NULL
) RETURNS timestamptz LANGUAGE sql STABLE AS $$
  WITH candidates AS (
    SELECT ((d::date + es.local_time) AT TIME ZONE es.timezone) AS candidate
    FROM generate_series(
      (p_after AT TIME ZONE 'America/Sao_Paulo')::date,
      (p_after AT TIME ZONE 'America/Sao_Paulo')::date + 84,
      interval '1 day'
    ) d
    JOIN social_media.editorial_slots es
      ON es.client_id=p_client_id AND es.platform=p_platform AND es.active
     AND es.day_of_week=extract(dow FROM d)::int
  )
  SELECT min(candidate) FROM candidates c
  WHERE c.candidate>p_after
    AND NOT EXISTS (
      SELECT 1 FROM social_media.content_schedule s
      WHERE s.client_id=p_client_id AND s.platform=p_platform
        AND s.scheduled_at=c.candidate AND s.status IN ('SCHEDULED','READY_TO_PUBLISH')
        AND (p_exclude_schedule IS NULL OR s.id<>p_exclude_schedule)
    );
$$;

CREATE OR REPLACE VIEW social_media.phase8_publication_queue AS
SELECT s.id AS schedule_id,s.content_id,s.version_id,s.client_id,s.platform,s.scheduled_at,s.timezone,
       v.copy->>'caption' AS caption,COALESCE(v.copy->'hashtags','[]'::jsonb) AS hashtags,
       v.final_art_path,c.approved_version_id,c.approval_status,s.metadata,s.updated_at
FROM social_media.content_schedule s
JOIN social_media.content_items c ON c.content_id=s.content_id
JOIN social_media.content_versions v ON v.id=s.version_id
WHERE s.status='READY_TO_PUBLISH'
  AND c.approval_status='APPROVED' AND c.approved_version_id=s.version_id
  AND v.final_art_path IS NOT NULL;

COMMENT ON VIEW social_media.phase8_publication_queue IS
'Read-only payload for Phase 8. Phase 7 never calls Instagram/Meta and never marks PUBLISHED.';

CREATE OR REPLACE FUNCTION social_media.emit_schedule_result(
  p_correlation_id uuid,p_client_id text,p_content_id text,p_channel text,
  p_event_type text,p_message text,p_payload jsonb,p_severity text DEFAULT 'INFO'
) RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO social_media.events(correlation_id,client_id,content_id,event_type,workflow_name,severity,details)
  VALUES(p_correlation_id,p_client_id,p_content_id,p_event_type,'07 - Orquestrador de Agendamento',p_severity,p_payload);
  INSERT INTO social_media.messages(correlation_id,client_id,channel,direction,sender_id,body,raw_payload)
  VALUES(p_correlation_id,p_client_id,p_channel,'OUTBOUND','social-media-ai-agent',p_message,p_payload);
  RETURN p_payload || jsonb_build_object('automatic_response',p_message,'persisted',true,'event_type',p_event_type);
END; $$;

CREATE OR REPLACE FUNCTION social_media.process_schedule_request(
  p_channel text,p_sender_id text,p_content_id text,p_message text,p_external_message_id text,
  p_action text,p_platform text,p_source text,p_target_date date,p_target_time time,
  p_use_next_slot boolean DEFAULT false,p_requested_version_id uuid DEFAULT NULL,
  p_existing_message_id uuid DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_client text; v_content text; v_approved uuid; v_current uuid; v_version uuid;
  v_art text; v_approval text; v_content_status text; v_message_id uuid; v_corr uuid;
  v_schedule social_media.content_schedule%ROWTYPE; v_target timestamptz; v_old_target timestamptz; v_tz text;
  v_existing_message uuid; v_candidates int; v_conflict uuid; v_payload jsonb;
  v_source text:=CASE WHEN p_source IN ('admin','approval') THEN p_source ELSE 'conversation' END;
  v_platform text:=lower(COALESCE(NULLIF(p_platform,''),'instagram'));
BEGIN
  -- Normalize common imperative forms even if an upstream deterministic parser
  -- classifies them conservatively. This keeps every channel on the same rule.
  IF p_message ~* '\m(cancele|cancelar|cancela|desmarque|desmarcar)\M' THEN
    p_action:='cancel';
  ELSIF p_message ~* '\m(reagende|reagendar|reagenda|remarque|remarcar|remarca|adie|adiar)\M' THEN
    p_action:='reschedule';
  END IF;
  SELECT client_id INTO v_client FROM social_media.channel_identities
   WHERE channel=p_channel AND external_sender_id=p_sender_id AND active;
  IF v_client IS NULL THEN
    v_corr:=gen_random_uuid();
    INSERT INTO social_media.messages(channel,external_message_id,direction,sender_id,body,raw_payload,correlation_id)
    VALUES(p_channel,p_external_message_id,'INBOUND',p_sender_id,p_message,jsonb_build_object('phase',7),v_corr)
    ON CONFLICT(channel,external_message_id) WHERE external_message_id IS NOT NULL DO NOTHING;
    RETURN social_media.emit_schedule_result(v_corr,NULL,NULL,p_channel,'SCHEDULE_IDENTITY_REJECTED',
      'Não consegui identificar o cliente deste canal.',jsonb_build_object('ok',false,'error','IDENTITY_NOT_FOUND'),'WARN');
  END IF;

  IF p_existing_message_id IS NOT NULL THEN
    SELECT message_id,correlation_id INTO v_message_id,v_corr FROM social_media.messages WHERE message_id=p_existing_message_id;
  ELSE
    SELECT message_id INTO v_existing_message FROM social_media.messages
      WHERE channel=p_channel AND external_message_id=p_external_message_id;
    IF v_existing_message IS NOT NULL THEN
      SELECT sh.schedule_id,s.content_id,s.version_id,s.scheduled_at,s.status INTO v_schedule.id,v_schedule.content_id,v_schedule.version_id,v_schedule.scheduled_at,v_schedule.status
      FROM social_media.schedule_history sh LEFT JOIN social_media.content_schedule s ON s.id=sh.schedule_id
      WHERE sh.message_id=v_existing_message ORDER BY sh.created_at DESC LIMIT 1;
      RETURN jsonb_build_object('ok',true,'duplicate',true,'message_id',v_existing_message,'schedule_id',v_schedule.id,
        'content_id',v_schedule.content_id,'version_id',v_schedule.version_id,'scheduled_at',v_schedule.scheduled_at,
        'status',v_schedule.status,'automatic_response','Mensagem de agendamento já processada; nenhuma duplicação foi criada.');
    END IF;
    v_corr:=gen_random_uuid();
    INSERT INTO social_media.messages(client_id,channel,external_message_id,direction,sender_id,body,raw_payload,correlation_id)
    VALUES(v_client,p_channel,p_external_message_id,'INBOUND',p_sender_id,p_message,
      jsonb_build_object('phase',7,'content_id',p_content_id,'source',v_source),v_corr)
    RETURNING message_id INTO v_message_id;
  END IF;
  IF v_corr IS NULL THEN v_corr:=gen_random_uuid(); END IF;
  INSERT INTO social_media.events(correlation_id,client_id,content_id,event_type,workflow_name,details)
  VALUES(v_corr,v_client,NULLIF(p_content_id,''),'SCHEDULE_REQUEST_RECEIVED','07 - Orquestrador de Agendamento',
    jsonb_build_object('message_id',v_message_id,'action',p_action,'source',v_source,'platform',v_platform));

  IF NULLIF(p_content_id,'') IS NULL THEN
    SELECT count(*),min(content_id) INTO v_candidates,v_content FROM social_media.content_items
    WHERE client_id=v_client AND approval_status='APPROVED' AND status IN ('APPROVED','SCHEDULED');
    IF v_candidates<>1 THEN
      RETURN social_media.emit_schedule_result(v_corr,v_client,NULL,p_channel,'SCHEDULE_CLARIFICATION_REQUESTED',
        'Encontrei mais de um conteúdo aprovado. Informe o Content ID que deseja agendar.',
        jsonb_build_object('ok',false,'error','CONTENT_AMBIGUOUS','candidate_count',v_candidates),'WARN');
    END IF;
  ELSE v_content:=p_content_id; END IF;

  SELECT c.approved_version_id,c.current_version_id,c.approval_status,c.status,v.final_art_path
    INTO v_approved,v_current,v_approval,v_content_status,v_art
  FROM social_media.content_items c LEFT JOIN social_media.content_versions v ON v.id=c.approved_version_id
  WHERE c.content_id=v_content AND c.client_id=v_client;
  IF NOT FOUND THEN
    RETURN social_media.emit_schedule_result(v_corr,v_client,v_content,p_channel,'SCHEDULE_VALIDATION_FAILED',
      'Conteúdo não encontrado para o cliente identificado.',jsonb_build_object('ok',false,'error','CONTENT_NOT_FOUND'),'WARN');
  END IF;
  v_version:=COALESCE(p_requested_version_id,v_approved);
  IF v_approval<>'APPROVED' OR v_approved IS NULL THEN
    RETURN social_media.emit_schedule_result(v_corr,v_client,v_content,p_channel,'SCHEDULE_VALIDATION_FAILED',
      'Só é possível agendar conteúdo aprovado.',jsonb_build_object('ok',false,'error','CONTENT_NOT_APPROVED'),'WARN');
  END IF;
  IF v_version IS DISTINCT FROM v_approved THEN
    RETURN social_media.emit_schedule_result(v_corr,v_client,v_content,p_channel,'SCHEDULE_VALIDATION_FAILED',
      'A versão informada não é a versão aprovada atual.',jsonb_build_object('ok',false,'error','VERSION_NOT_APPROVED','approved_version_id',v_approved),'WARN');
  END IF;
  IF v_art IS NULL OR btrim(v_art)='' THEN
    RETURN social_media.emit_schedule_result(v_corr,v_client,v_content,p_channel,'SCHEDULE_VALIDATION_FAILED',
      'A versão aprovada ainda não possui arte final.',jsonb_build_object('ok',false,'error','FINAL_ART_MISSING','version_id',v_version),'WARN');
  END IF;

  SELECT * INTO v_schedule FROM social_media.content_schedule
   WHERE content_id=v_content AND platform=v_platform AND status IN ('SCHEDULED','READY_TO_PUBLISH')
   ORDER BY created_at DESC LIMIT 1 FOR UPDATE;

  IF p_action='cancel' THEN
    IF v_schedule.id IS NULL THEN
      RETURN social_media.emit_schedule_result(v_corr,v_client,v_content,p_channel,'SCHEDULE_VALIDATION_FAILED',
        'Não há agendamento ativo para cancelar.',jsonb_build_object('ok',false,'error','ACTIVE_SCHEDULE_NOT_FOUND'),'WARN');
    END IF;
    UPDATE social_media.content_schedule SET status='CANCELLED',cancelled_at=now(),updated_at=now(),request_message_id=v_message_id
      WHERE id=v_schedule.id;
    UPDATE social_media.content_items SET status='APPROVED',scheduled_at=NULL,updated_at=now() WHERE content_id=v_content;
    INSERT INTO social_media.schedule_history(schedule_id,content_id,version_id,message_id,action,old_scheduled_at,old_status,new_status,requested_by)
      VALUES(v_schedule.id,v_content,v_version,v_message_id,'CANCELLED',v_schedule.scheduled_at,v_schedule.status,'CANCELLED',p_sender_id);
    RETURN social_media.emit_schedule_result(v_corr,v_client,v_content,p_channel,'CONTENT_SCHEDULE_CANCELLED',
      'Agendamento cancelado. O conteúdo continua aprovado.',jsonb_build_object('ok',true,'action','cancel','schedule_id',v_schedule.id,'content_id',v_content,'version_id',v_version,'status','CANCELLED'));
  END IF;

  IF p_action='reschedule' AND v_schedule.id IS NULL THEN
    RETURN social_media.emit_schedule_result(v_corr,v_client,v_content,p_channel,'SCHEDULE_VALIDATION_FAILED',
      'Não há agendamento ativo para reagendar.',jsonb_build_object('ok',false,'error','ACTIVE_SCHEDULE_NOT_FOUND'),'WARN');
  ELSIF p_action='schedule' AND v_schedule.id IS NOT NULL THEN
    RETURN social_media.emit_schedule_result(v_corr,v_client,v_content,p_channel,'SCHEDULE_CONFLICT_DETECTED',
      'Este conteúdo já possui um agendamento ativo. Peça para reagendar ou cancelar.',
      jsonb_build_object('ok',false,'error','CONTENT_ALREADY_SCHEDULED','schedule_id',v_schedule.id,'scheduled_at',v_schedule.scheduled_at),'WARN');
  END IF;

  SELECT COALESCE((SELECT config_value FROM social_media.runtime_config WHERE config_key='default_timezone'),'America/Sao_Paulo') INTO v_tz;
  IF p_use_next_slot THEN
    v_target:=social_media.next_available_editorial_slot(v_client,v_platform,now(),v_schedule.id);
  ELSIF p_target_date IS NOT NULL AND p_target_time IS NOT NULL THEN
    v_target:=(p_target_date+p_target_time) AT TIME ZONE v_tz;
  ELSIF p_target_date IS NOT NULL THEN
    SELECT (p_target_date+local_time) AT TIME ZONE timezone INTO v_target
    FROM social_media.editorial_slots
    WHERE client_id=v_client AND platform=v_platform AND active AND day_of_week=extract(dow FROM p_target_date)::int
    ORDER BY local_time LIMIT 1;
  END IF;
  IF v_target IS NULL THEN
    RETURN social_media.emit_schedule_result(v_corr,v_client,v_content,p_channel,'SCHEDULE_CLARIFICATION_REQUESTED',
      'Preciso de uma data e horário válidos, ou você pode pedir o próximo horário disponível.',
      jsonb_build_object('ok',false,'error','DATE_TIME_REQUIRED'),'WARN');
  END IF;
  IF v_target<=now() THEN
    RETURN social_media.emit_schedule_result(v_corr,v_client,v_content,p_channel,'SCHEDULE_VALIDATION_FAILED',
      'O horário precisa estar no futuro.',jsonb_build_object('ok',false,'error','SCHEDULE_IN_PAST','scheduled_at',v_target),'WARN');
  END IF;
  SELECT id INTO v_conflict FROM social_media.content_schedule
    WHERE client_id=v_client AND platform=v_platform AND scheduled_at=v_target
      AND status IN ('SCHEDULED','READY_TO_PUBLISH') AND (v_schedule.id IS NULL OR id<>v_schedule.id) LIMIT 1;
  IF v_conflict IS NOT NULL THEN
    RETURN social_media.emit_schedule_result(v_corr,v_client,v_content,p_channel,'SCHEDULE_CONFLICT_DETECTED',
      'Esse horário já está ocupado. Posso usar o próximo horário disponível.',
      jsonb_build_object('ok',false,'error','SLOT_CONFLICT','conflict_schedule_id',v_conflict,'requested_at',v_target,
        'next_available_at',social_media.next_available_editorial_slot(v_client,v_platform,v_target,NULL)),'WARN');
  END IF;

  IF p_action='reschedule' THEN
    v_old_target:=v_schedule.scheduled_at;
    UPDATE social_media.content_schedule SET scheduled_at=v_target,scheduled_date=(v_target AT TIME ZONE v_tz)::date,
      scheduled_time=(v_target AT TIME ZONE v_tz)::time,timezone=v_tz,status='SCHEDULED',source=v_source,
      request_message_id=v_message_id,updated_at=now(),metadata=metadata||jsonb_build_object('last_action','reschedule')
    WHERE id=v_schedule.id RETURNING * INTO v_schedule;
    INSERT INTO social_media.schedule_history(schedule_id,content_id,version_id,message_id,action,old_scheduled_at,new_scheduled_at,old_status,new_status,requested_by)
      VALUES(v_schedule.id,v_content,v_version,v_message_id,'RESCHEDULED',v_old_target,v_target,'SCHEDULED','SCHEDULED',p_sender_id);
    v_payload:=jsonb_build_object('ok',true,'action','reschedule','schedule_id',v_schedule.id,'content_id',v_content,'version_id',v_version,'scheduled_at',v_target,'timezone',v_tz,'status','SCHEDULED','platform',v_platform);
    RETURN social_media.emit_schedule_result(v_corr,v_client,v_content,p_channel,'CONTENT_RESCHEDULED',
      'Conteúdo reagendado com sucesso.',v_payload);
  ELSE
    INSERT INTO social_media.content_schedule(content_id,client_id,version_id,platform,scheduled_date,scheduled_time,scheduled_at,timezone,status,source,request_message_id,metadata)
    VALUES(v_content,v_client,v_version,v_platform,(v_target AT TIME ZONE v_tz)::date,(v_target AT TIME ZONE v_tz)::time,
      v_target,v_tz,'SCHEDULED',v_source,v_message_id,jsonb_build_object('demo_mode',true,'live_mode',false)) RETURNING * INTO v_schedule;
    UPDATE social_media.content_items SET status='SCHEDULED',scheduled_at=v_target,updated_at=now() WHERE content_id=v_content;
    INSERT INTO social_media.schedule_history(schedule_id,content_id,version_id,message_id,action,new_scheduled_at,new_status,requested_by)
      VALUES(v_schedule.id,v_content,v_version,v_message_id,'CREATED',v_target,'SCHEDULED',p_sender_id);
    v_payload:=jsonb_build_object('ok',true,'action','schedule','schedule_id',v_schedule.id,'content_id',v_content,'version_id',v_version,'scheduled_at',v_target,'timezone',v_tz,'status','SCHEDULED','platform',v_platform,'source',v_source);
    RETURN social_media.emit_schedule_result(v_corr,v_client,v_content,p_channel,'CONTENT_SCHEDULED',
      'Conteúdo agendado com sucesso.',v_payload);
  END IF;
END; $$;
