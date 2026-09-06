-- Phase 7.1: multi-client schedule preferences, deterministic dayparts and auditable resolution.
CREATE TABLE IF NOT EXISTS social_media.client_schedule_preferences (
  client_id text PRIMARY KEY REFERENCES social_media.clients(client_id),
  timezone text,
  default_platform text,
  enabled_platforms jsonb NOT NULL DEFAULT '[]'::jsonb,
  daypart_times jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (jsonb_typeof(enabled_platforms)='array'),
  CHECK (jsonb_typeof(daypart_times)='object')
);

INSERT INTO social_media.client_schedule_preferences(client_id,timezone,default_platform,enabled_platforms,daypart_times)
VALUES('webtech-demo','America/Sao_Paulo','instagram','["instagram"]'::jsonb,'{}'::jsonb)
ON CONFLICT(client_id) DO UPDATE SET
  timezone=EXCLUDED.timezone,
  default_platform=EXCLUDED.default_platform,
  enabled_platforms=EXCLUDED.enabled_platforms,
  updated_at=now();

ALTER TABLE social_media.content_schedule DROP CONSTRAINT IF EXISTS content_schedule_source_check;

UPDATE social_media.content_schedule SET source=CASE source
  WHEN 'conversation' THEN 'explicit_request'
  WHEN 'approval' THEN 'approval_with_explicit_schedule'
  ELSE source END
WHERE source IN ('conversation','approval');

ALTER TABLE social_media.content_schedule ADD CONSTRAINT content_schedule_source_check CHECK(source IN (
  'explicit_request','editorial_slot','admin','approval_with_explicit_schedule',
  'approval_with_editorial_slot','reschedule_request'
));

CREATE OR REPLACE FUNCTION social_media.next_available_editorial_slot(
  p_client_id text,p_platform text,p_after timestamptz DEFAULT now(),p_exclude_schedule uuid DEFAULT NULL
) RETURNS timestamptz LANGUAGE sql STABLE AS $$
  WITH cfg AS (
    SELECT COALESCE(
      (SELECT timezone FROM social_media.client_schedule_preferences WHERE client_id=p_client_id),
      (SELECT config_value FROM social_media.runtime_config WHERE config_key='default_timezone')
    ) AS timezone
  ), candidates AS (
    SELECT ((d::date+es.local_time) AT TIME ZONE es.timezone) AS candidate
    FROM cfg CROSS JOIN LATERAL generate_series(
      (p_after AT TIME ZONE cfg.timezone)::date,
      (p_after AT TIME ZONE cfg.timezone)::date+84,
      interval '1 day'
    ) d
    JOIN social_media.editorial_slots es
      ON es.client_id=p_client_id AND es.platform=p_platform AND es.active
     AND es.day_of_week=extract(dow FROM d)::int
    WHERE cfg.timezone IS NOT NULL
  )
  SELECT min(candidate) FROM candidates c
  WHERE c.candidate>p_after AND NOT EXISTS(
    SELECT 1 FROM social_media.content_schedule s
    WHERE s.client_id=p_client_id AND s.platform=p_platform
      AND s.scheduled_at=c.candidate AND s.status IN ('SCHEDULED','READY_TO_PUBLISH')
      AND (p_exclude_schedule IS NULL OR s.id<>p_exclude_schedule)
  );
$$;

CREATE OR REPLACE FUNCTION social_media.process_schedule_request(
  p_channel text,p_sender_id text,p_content_id text,p_message text,p_external_message_id text,
  p_action text,p_platform text,p_source text,p_target_date date,p_target_time time,
  p_use_next_slot boolean DEFAULT false,p_requested_version_id uuid DEFAULT NULL,
  p_existing_message_id uuid DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_client text; v_content text; v_approved uuid; v_version uuid; v_art text; v_approval text;
  v_message_id uuid; v_corr uuid; v_existing_message uuid; v_candidates int;
  v_schedule social_media.content_schedule%ROWTYPE; v_target timestamptz; v_old_target timestamptz;
  v_client_tz text; v_target_tz text; v_default_platform text; v_enabled jsonb; v_dayparts jsonb;
  v_platform text; v_platform_explicit boolean:=false; v_daypart text; v_exact_time boolean:=false;
  v_resolution text; v_source text; v_conflict uuid; v_payload jsonb; v_local_date date;
  v_slot_time time; v_slot_tz text; v_pref_time time; v_dow int; v_delta int;
  v_origin text:=CASE WHEN p_source='admin' THEN 'admin' WHEN p_source='approval' THEN 'approval' ELSE 'conversation' END;
BEGIN
  IF p_message ~* '\m(cancele|cancelar|cancela|desmarque|desmarcar)\M' THEN p_action:='cancel';
  ELSIF p_message ~* '\m(reagende|reagendar|reagenda|remarque|remarcar|remarca|adie|adiar)\M' THEN p_action:='reschedule';
  END IF;

  SELECT client_id INTO v_client FROM social_media.channel_identities
  WHERE channel=p_channel AND external_sender_id=p_sender_id AND active;
  IF v_client IS NULL THEN
    v_corr:=gen_random_uuid();
    INSERT INTO social_media.messages(channel,external_message_id,direction,sender_id,body,raw_payload,correlation_id)
    VALUES(p_channel,p_external_message_id,'INBOUND',p_sender_id,p_message,jsonb_build_object('phase','7.1'),v_corr)
    ON CONFLICT(channel,external_message_id) WHERE external_message_id IS NOT NULL DO NOTHING;
    RETURN social_media.emit_schedule_result(v_corr,NULL,NULL,p_channel,'SCHEDULE_IDENTITY_REJECTED',
      'Não consegui identificar o cliente deste canal.',jsonb_build_object('ok',false,'error','IDENTITY_NOT_FOUND','clarification_reason','identity_not_found'),'WARN');
  END IF;

  SELECT COALESCE(pref.timezone,(SELECT config_value FROM social_media.runtime_config WHERE config_key='default_timezone')),
         pref.default_platform,COALESCE(pref.enabled_platforms,'[]'::jsonb),COALESCE(pref.daypart_times,'{}'::jsonb)
  INTO v_client_tz,v_default_platform,v_enabled,v_dayparts
  FROM (SELECT 1) x LEFT JOIN social_media.client_schedule_preferences pref ON pref.client_id=v_client;
  IF v_client_tz IS NULL OR NOT EXISTS(SELECT 1 FROM pg_timezone_names WHERE name=v_client_tz) THEN
    RETURN social_media.emit_schedule_result(gen_random_uuid(),v_client,NULL,p_channel,'SCHEDULE_VALIDATION_FAILED',
      'O fuso horário do cliente não está configurado corretamente.',jsonb_build_object('ok',false,'error','TIMEZONE_NOT_CONFIGURED','clarification_reason','missing_timezone'),'WARN');
  END IF;

  IF p_existing_message_id IS NOT NULL THEN
    SELECT message_id,correlation_id INTO v_message_id,v_corr FROM social_media.messages WHERE message_id=p_existing_message_id;
  ELSE
    SELECT message_id INTO v_existing_message FROM social_media.messages WHERE channel=p_channel AND external_message_id=p_external_message_id;
    IF v_existing_message IS NOT NULL THEN
      SELECT sh.schedule_id,s.content_id,s.version_id,s.scheduled_at,s.status,s.source
      INTO v_schedule.id,v_schedule.content_id,v_schedule.version_id,v_schedule.scheduled_at,v_schedule.status,v_schedule.source
      FROM social_media.schedule_history sh LEFT JOIN social_media.content_schedule s ON s.id=sh.schedule_id
      WHERE sh.message_id=v_existing_message ORDER BY sh.created_at DESC LIMIT 1;
      RETURN jsonb_build_object('ok',true,'duplicate',true,'message_id',v_existing_message,'schedule_id',v_schedule.id,
        'content_id',v_schedule.content_id,'version_id',v_schedule.version_id,'scheduled_at',v_schedule.scheduled_at,
        'status',v_schedule.status,'source',v_schedule.source,'automatic_response','Mensagem de agendamento já processada; nenhuma duplicação foi criada.');
    END IF;
    v_corr:=gen_random_uuid();
    INSERT INTO social_media.messages(client_id,channel,external_message_id,direction,sender_id,body,raw_payload,correlation_id)
    VALUES(v_client,p_channel,p_external_message_id,'INBOUND',p_sender_id,p_message,
      jsonb_build_object('phase','7.1','content_id',p_content_id,'origin',v_origin),v_corr) RETURNING message_id INTO v_message_id;
  END IF;
  IF v_corr IS NULL THEN v_corr:=gen_random_uuid(); END IF;

  IF NULLIF(p_content_id,'') IS NULL THEN
    SELECT count(*),min(content_id) INTO v_candidates,v_content FROM social_media.content_items
    WHERE client_id=v_client AND approval_status='APPROVED' AND status IN ('APPROVED','SCHEDULED');
    IF v_candidates<>1 THEN
      RETURN social_media.emit_schedule_result(v_corr,v_client,NULL,p_channel,'SCHEDULE_CLARIFICATION_REQUIRED',
        'Encontrei mais de um conteúdo aprovado. Informe o Content ID que deseja agendar.',
        jsonb_build_object('ok',false,'error','CONTENT_AMBIGUOUS','clarification_reason','ambiguous_content','candidate_count',v_candidates),'WARN');
    END IF;
  ELSE v_content:=p_content_id; END IF;

  SELECT c.approved_version_id,c.approval_status,v.final_art_path INTO v_approved,v_approval,v_art
  FROM social_media.content_items c LEFT JOIN social_media.content_versions v ON v.id=c.approved_version_id
  WHERE c.content_id=v_content AND c.client_id=v_client;
  IF NOT FOUND THEN
    RETURN social_media.emit_schedule_result(v_corr,v_client,v_content,p_channel,'SCHEDULE_VALIDATION_FAILED',
      'Conteúdo não encontrado para o cliente identificado.',jsonb_build_object('ok',false,'error','CONTENT_NOT_FOUND','clarification_reason','content_not_found'),'WARN');
  END IF;
  v_version:=COALESCE(p_requested_version_id,v_approved);
  IF v_approval<>'APPROVED' OR v_approved IS NULL THEN
    RETURN social_media.emit_schedule_result(v_corr,v_client,v_content,p_channel,'SCHEDULE_VALIDATION_FAILED',
      'Só é possível agendar conteúdo aprovado.',jsonb_build_object('ok',false,'error','CONTENT_NOT_APPROVED','clarification_reason','content_not_approved'),'WARN');
  END IF;
  IF v_version IS DISTINCT FROM v_approved THEN
    RETURN social_media.emit_schedule_result(v_corr,v_client,v_content,p_channel,'SCHEDULE_VALIDATION_FAILED',
      'A versão informada não é a versão aprovada atual.',jsonb_build_object('ok',false,'error','VERSION_NOT_APPROVED','clarification_reason','version_not_approved','approved_version_id',v_approved),'WARN');
  END IF;
  IF v_art IS NULL OR btrim(v_art)='' THEN
    RETURN social_media.emit_schedule_result(v_corr,v_client,v_content,p_channel,'SCHEDULE_VALIDATION_FAILED',
      'A versão aprovada ainda não possui arte final.',jsonb_build_object('ok',false,'error','FINAL_ART_MISSING','clarification_reason','final_art_missing','version_id',v_version),'WARN');
  END IF;

  -- Platform is explicit only when named in the message (or a non-legacy payload value is supplied).
  IF p_message ~* '\m(instagram|insta)\M' THEN v_platform:='instagram';v_platform_explicit:=true;
  ELSIF p_message ~* '\mfacebook\M' THEN v_platform:='facebook';v_platform_explicit:=true;
  ELSIF p_message ~* '\mlinkedin\M' THEN v_platform:='linkedin';v_platform_explicit:=true;
  ELSIF p_message ~* '\m(tiktok|tik tok)\M' THEN v_platform:='tiktok';v_platform_explicit:=true;
  ELSIF NULLIF(lower(p_platform),'') IS NOT NULL AND lower(p_platform)<>'instagram' THEN v_platform:=lower(p_platform);v_platform_explicit:=true;
  ELSE v_platform:=lower(v_default_platform); END IF;

  IF v_platform IS NULL THEN
    RETURN social_media.emit_schedule_result(v_corr,v_client,v_content,p_channel,'SCHEDULE_CLARIFICATION_REQUIRED',
      'Em qual plataforma você quer publicar?',jsonb_build_object('ok',false,'error','PLATFORM_REQUIRED','clarification_reason','missing_platform','enabled_platforms',v_enabled),'WARN');
  END IF;
  IF NOT (v_enabled ? v_platform) THEN
    RETURN social_media.emit_schedule_result(v_corr,v_client,v_content,p_channel,'SCHEDULE_CLARIFICATION_REQUIRED',
      'Essa plataforma não está configurada para este cliente.',jsonb_build_object('ok',false,'error','PLATFORM_NOT_CONFIGURED','clarification_reason','platform_not_configured','platform',v_platform,'enabled_platforms',v_enabled),'WARN');
  END IF;

  SELECT * INTO v_schedule FROM social_media.content_schedule
  WHERE content_id=v_content AND platform=v_platform AND status IN ('SCHEDULED','READY_TO_PUBLISH')
  ORDER BY created_at DESC LIMIT 1 FOR UPDATE;

  IF p_action='cancel' THEN
    IF v_schedule.id IS NULL THEN
      RETURN social_media.emit_schedule_result(v_corr,v_client,v_content,p_channel,'SCHEDULE_VALIDATION_FAILED',
        'Não há agendamento ativo para cancelar.',jsonb_build_object('ok',false,'error','ACTIVE_SCHEDULE_NOT_FOUND','clarification_reason','active_schedule_not_found'),'WARN');
    END IF;
    UPDATE social_media.content_schedule SET status='CANCELLED',cancelled_at=now(),updated_at=now(),request_message_id=v_message_id WHERE id=v_schedule.id;
    UPDATE social_media.content_items SET status='APPROVED',scheduled_at=NULL,updated_at=now() WHERE content_id=v_content;
    INSERT INTO social_media.schedule_history(schedule_id,content_id,version_id,message_id,action,old_scheduled_at,old_status,new_status,requested_by,details)
    VALUES(v_schedule.id,v_content,v_version,v_message_id,'CANCELLED',v_schedule.scheduled_at,v_schedule.status,'CANCELLED',p_sender_id,jsonb_build_object('source',v_schedule.source));
    RETURN social_media.emit_schedule_result(v_corr,v_client,v_content,p_channel,'CONTENT_SCHEDULE_CANCELLED',
      'Agendamento cancelado. O conteúdo continua aprovado.',jsonb_build_object('ok',true,'action','cancel','schedule_id',v_schedule.id,'content_id',v_content,'version_id',v_version,'status','CANCELLED','source',v_schedule.source));
  END IF;

  IF p_action='reschedule' AND v_schedule.id IS NULL THEN
    RETURN social_media.emit_schedule_result(v_corr,v_client,v_content,p_channel,'SCHEDULE_VALIDATION_FAILED',
      'Não há agendamento ativo para reagendar.',jsonb_build_object('ok',false,'error','ACTIVE_SCHEDULE_NOT_FOUND','clarification_reason','active_schedule_not_found'),'WARN');
  ELSIF p_action='schedule' AND v_schedule.id IS NOT NULL THEN
    RETURN social_media.emit_schedule_result(v_corr,v_client,v_content,p_channel,'SCHEDULE_CONFLICT_DETECTED',
      'Este conteúdo já possui um agendamento ativo. Peça para reagendar ou cancelar.',
      jsonb_build_object('ok',false,'error','CONTENT_ALREADY_SCHEDULED','clarification_reason','schedule_conflict','schedule_id',v_schedule.id,'scheduled_at',v_schedule.scheduled_at),'WARN');
  END IF;

  -- Resolve weekday relative to the client's IANA timezone, never the host offset.
  IF p_message ~* '\mdomingo\M' THEN v_dow:=0;
  ELSIF p_message ~* '\msegunda\M' THEN v_dow:=1;
  ELSIF p_message ~* '\m(terça|terca)\M' THEN v_dow:=2;
  ELSIF p_message ~* '\mquarta\M' THEN v_dow:=3;
  ELSIF p_message ~* '\mquinta\M' THEN v_dow:=4;
  ELSIF p_message ~* '\msexta\M' THEN v_dow:=5;
  ELSIF p_message ~* '\m(sábado|sabado)\M' THEN v_dow:=6; END IF;
  IF v_dow IS NOT NULL THEN
    v_local_date:=(now() AT TIME ZONE v_client_tz)::date;
    v_delta:=(v_dow-extract(dow FROM v_local_date)::int+7)%7;
    IF v_delta=0 OR p_message ~* '(que vem|próxim|proxim)' THEN v_delta:=CASE WHEN v_delta=0 THEN 7 ELSE v_delta END; END IF;
    p_target_date:=v_local_date+v_delta;
  END IF;

  IF p_message ~* '\m(almoço|almoco)\M' THEN v_daypart:='lunch';
  ELSIF p_message ~* '\m(manhã|manha)\M' THEN v_daypart:='morning';
  ELSIF p_message ~* '\m(tarde)\M' THEN v_daypart:='afternoon';
  ELSIF p_message ~* '(fim do dia|entardecer)' THEN v_daypart:='evening';
  ELSIF p_message ~* '\m(noite)\M' THEN v_daypart:='night'; END IF;
  v_exact_time:=p_message ~* '((às|as|para|pelas?)\s*[0-2]?[0-9]([:h][0-5][0-9])?\s*h?)|([0-2]?[0-9]:[0-5][0-9])|([0-2]?[0-9]h([0-5][0-9])?)';
  IF v_daypart IS NOT NULL AND NOT v_exact_time THEN p_target_time:=NULL; END IF;

  IF p_use_next_slot THEN
    v_target:=social_media.next_available_editorial_slot(v_client,v_platform,now(),v_schedule.id);
    v_resolution:='editorial_slot';
    SELECT es.timezone INTO v_target_tz FROM social_media.editorial_slots es
    WHERE es.client_id=v_client AND es.platform=v_platform AND es.active
      AND ((v_target AT TIME ZONE es.timezone)::date+es.local_time) AT TIME ZONE es.timezone=v_target LIMIT 1;
  ELSIF v_daypart IS NOT NULL AND NOT v_exact_time THEN
    IF p_target_date IS NOT NULL THEN
      SELECT es.local_time,es.timezone INTO v_slot_time,v_slot_tz FROM social_media.editorial_slots es
      WHERE es.client_id=v_client AND es.platform=v_platform AND es.active
        AND es.day_of_week=extract(dow FROM p_target_date)::int
        AND CASE v_daypart
          WHEN 'morning' THEN es.local_time>=time '05:00' AND es.local_time<time '12:00'
          WHEN 'lunch' THEN es.local_time>=time '11:00' AND es.local_time<=time '14:00'
          WHEN 'afternoon' THEN es.local_time>=time '12:00' AND es.local_time<time '18:00'
          WHEN 'evening' THEN es.local_time>=time '17:00' AND es.local_time<time '21:00'
          WHEN 'night' THEN es.local_time>=time '18:00' AND es.local_time<=time '23:59:59'
        END ORDER BY es.local_time LIMIT 1;
    END IF;
    IF v_slot_time IS NOT NULL THEN
      v_target_tz:=v_slot_tz;v_target:=(p_target_date+v_slot_time) AT TIME ZONE v_target_tz;v_resolution:='editorial_slot';
    ELSIF v_dayparts ? v_daypart THEN
      BEGIN v_pref_time:=(v_dayparts->>v_daypart)::time; EXCEPTION WHEN others THEN v_pref_time:=NULL; END;
      IF v_pref_time IS NOT NULL THEN
        IF p_target_date IS NULL THEN
          p_target_date:=(now() AT TIME ZONE v_client_tz)::date;
          IF (p_target_date+v_pref_time) AT TIME ZONE v_client_tz<=now() THEN p_target_date:=p_target_date+1; END IF;
        END IF;
        v_target_tz:=v_client_tz;v_target:=(p_target_date+v_pref_time) AT TIME ZONE v_target_tz;v_resolution:='client_daypart_preference';
      END IF;
    END IF;
    IF v_target IS NULL THEN
      RETURN social_media.emit_schedule_result(v_corr,v_client,v_content,p_channel,'SCHEDULE_CLARIFICATION_REQUIRED',
        CASE WHEN p_target_date IS NOT NULL THEN 'Qual horário você prefere para essa data?' ELSE 'Qual horário você prefere?' END,
        jsonb_build_object('ok',false,'error','DAYPART_AMBIGUOUS','clarification_reason','ambiguous_daypart','daypart',v_daypart,'target_date',p_target_date,'platform',v_platform),'WARN');
    END IF;
  ELSIF p_target_date IS NOT NULL AND p_target_time IS NOT NULL THEN
    v_target_tz:=v_client_tz;v_target:=(p_target_date+p_target_time) AT TIME ZONE v_target_tz;v_resolution:='explicit_time';
  ELSIF p_target_date IS NOT NULL THEN
    SELECT es.local_time,es.timezone INTO v_slot_time,v_slot_tz FROM social_media.editorial_slots es
    WHERE es.client_id=v_client AND es.platform=v_platform AND es.active AND es.day_of_week=extract(dow FROM p_target_date)::int
    ORDER BY es.local_time LIMIT 1;
    IF v_slot_time IS NOT NULL THEN
      v_target_tz:=v_slot_tz;v_target:=(p_target_date+v_slot_time) AT TIME ZONE v_target_tz;v_resolution:='editorial_slot';
    END IF;
  END IF;
  v_target_tz:=COALESCE(v_target_tz,v_client_tz);
  IF v_target IS NULL THEN
    RETURN social_media.emit_schedule_result(v_corr,v_client,v_content,p_channel,'SCHEDULE_CLARIFICATION_REQUIRED',
      'Preciso de uma data e horário válidos, ou você pode pedir o próximo horário disponível.',
      jsonb_build_object('ok',false,'error','DATE_TIME_REQUIRED','clarification_reason','missing_time','platform',v_platform),'WARN');
  END IF;
  IF v_target<=now() THEN
    RETURN social_media.emit_schedule_result(v_corr,v_client,v_content,p_channel,'SCHEDULE_VALIDATION_FAILED',
      'O horário precisa estar no futuro.',jsonb_build_object('ok',false,'error','SCHEDULE_IN_PAST','clarification_reason','schedule_in_past','scheduled_at',v_target),'WARN');
  END IF;

  SELECT id INTO v_conflict FROM social_media.content_schedule WHERE client_id=v_client AND platform=v_platform
    AND scheduled_at=v_target AND status IN ('SCHEDULED','READY_TO_PUBLISH') AND (v_schedule.id IS NULL OR id<>v_schedule.id) LIMIT 1;
  IF v_conflict IS NOT NULL THEN
    RETURN social_media.emit_schedule_result(v_corr,v_client,v_content,p_channel,'SCHEDULE_CONFLICT_DETECTED',
      'Esse horário já está ocupado. Posso usar o próximo horário disponível.',
      jsonb_build_object('ok',false,'error','SLOT_CONFLICT','clarification_reason','schedule_conflict','conflict_schedule_id',v_conflict,
        'requested_at',v_target,'next_available_at',social_media.next_available_editorial_slot(v_client,v_platform,v_target,NULL)),'WARN');
  END IF;

  v_source:=CASE
    WHEN v_origin='admin' THEN 'admin'
    WHEN p_action='reschedule' THEN 'reschedule_request'
    WHEN v_origin='approval' AND v_resolution='editorial_slot' THEN 'approval_with_editorial_slot'
    WHEN v_origin='approval' THEN 'approval_with_explicit_schedule'
    WHEN v_resolution='editorial_slot' THEN 'editorial_slot'
    ELSE 'explicit_request' END;

  INSERT INTO social_media.events(correlation_id,client_id,content_id,event_type,workflow_name,details)
  VALUES(v_corr,v_client,v_content,'SCHEDULE_RESOLVED','07 - Orquestrador de Agendamento',
    jsonb_build_object('source',v_source,'platform',v_platform,'platform_explicit',v_platform_explicit,'timezone',v_target_tz,
      'scheduled_at',v_target,'resolution_method',v_resolution,'daypart',v_daypart));

  IF p_action='reschedule' THEN
    v_old_target:=v_schedule.scheduled_at;
    UPDATE social_media.content_schedule SET scheduled_at=v_target,scheduled_date=(v_target AT TIME ZONE v_target_tz)::date,
      scheduled_time=(v_target AT TIME ZONE v_target_tz)::time,timezone=v_target_tz,status='SCHEDULED',source=v_source,
      request_message_id=v_message_id,updated_at=now(),metadata=metadata||jsonb_build_object('last_action','reschedule','resolution_method',v_resolution,'daypart',v_daypart)
    WHERE id=v_schedule.id RETURNING * INTO v_schedule;
    INSERT INTO social_media.schedule_history(schedule_id,content_id,version_id,message_id,action,old_scheduled_at,new_scheduled_at,old_status,new_status,requested_by,details)
    VALUES(v_schedule.id,v_content,v_version,v_message_id,'RESCHEDULED',v_old_target,v_target,'SCHEDULED','SCHEDULED',p_sender_id,
      jsonb_build_object('source',v_source,'resolution_method',v_resolution,'timezone',v_target_tz));
    v_payload:=jsonb_build_object('ok',true,'action','reschedule','schedule_id',v_schedule.id,'content_id',v_content,'version_id',v_version,
      'scheduled_at',v_target,'timezone',v_target_tz,'status','SCHEDULED','platform',v_platform,'source',v_source,'resolution_method',v_resolution);
    RETURN social_media.emit_schedule_result(v_corr,v_client,v_content,p_channel,'CONTENT_RESCHEDULED','Conteúdo reagendado com sucesso.',v_payload);
  ELSE
    INSERT INTO social_media.content_schedule(content_id,client_id,version_id,platform,scheduled_date,scheduled_time,scheduled_at,timezone,status,source,request_message_id,metadata)
    VALUES(v_content,v_client,v_version,v_platform,(v_target AT TIME ZONE v_target_tz)::date,(v_target AT TIME ZONE v_target_tz)::time,
      v_target,v_target_tz,'SCHEDULED',v_source,v_message_id,jsonb_build_object('demo_mode',true,'live_mode',false,'resolution_method',v_resolution,'daypart',v_daypart,'platform_explicit',v_platform_explicit)) RETURNING * INTO v_schedule;
    UPDATE social_media.content_items SET status='SCHEDULED',scheduled_at=v_target,updated_at=now() WHERE content_id=v_content;
    INSERT INTO social_media.schedule_history(schedule_id,content_id,version_id,message_id,action,new_scheduled_at,new_status,requested_by,details)
    VALUES(v_schedule.id,v_content,v_version,v_message_id,'CREATED',v_target,'SCHEDULED',p_sender_id,
      jsonb_build_object('source',v_source,'resolution_method',v_resolution,'timezone',v_target_tz,'platform',v_platform));
    v_payload:=jsonb_build_object('ok',true,'action','schedule','schedule_id',v_schedule.id,'content_id',v_content,'version_id',v_version,
      'scheduled_at',v_target,'timezone',v_target_tz,'status','SCHEDULED','platform',v_platform,'source',v_source,'resolution_method',v_resolution,'daypart',v_daypart);
    INSERT INTO social_media.events(correlation_id,client_id,content_id,event_type,workflow_name,details)
    VALUES(v_corr,v_client,v_content,'SCHEDULE_CREATED','07 - Orquestrador de Agendamento',v_payload);
    RETURN social_media.emit_schedule_result(v_corr,v_client,v_content,p_channel,'CONTENT_SCHEDULED','Conteúdo agendado com sucesso.',v_payload);
  END IF;
END; $$;
