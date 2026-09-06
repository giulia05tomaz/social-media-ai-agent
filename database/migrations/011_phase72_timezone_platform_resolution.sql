-- Phase 7.2: client-timezone relative dates and explicit platform provenance.
-- This is an additive compatibility layer over the Phase 7.1 scheduling domain.

CREATE OR REPLACE FUNCTION social_media.get_effective_timezone(
  p_client_id text,
  p_context_timezone text DEFAULT NULL,
  p_platform text DEFAULT NULL
) RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE v_timezone text;
BEGIN
  IF NULLIF(btrim(p_context_timezone),'') IS NOT NULL
     AND EXISTS(SELECT 1 FROM pg_timezone_names WHERE name=p_context_timezone) THEN
    RETURN p_context_timezone;
  END IF;

  SELECT timezone INTO v_timezone
  FROM social_media.client_schedule_preferences
  WHERE client_id=p_client_id
    AND timezone IS NOT NULL
    AND EXISTS(SELECT 1 FROM pg_timezone_names WHERE name=timezone);
  IF v_timezone IS NOT NULL THEN RETURN v_timezone; END IF;

  SELECT es.timezone INTO v_timezone
  FROM social_media.editorial_slots es
  WHERE es.client_id=p_client_id AND es.active
    AND (p_platform IS NULL OR es.platform=p_platform)
    AND EXISTS(SELECT 1 FROM pg_timezone_names WHERE name=es.timezone)
  ORDER BY es.updated_at DESC,es.slot_id LIMIT 1;
  IF v_timezone IS NOT NULL THEN RETURN v_timezone; END IF;

  SELECT config_value INTO v_timezone FROM social_media.runtime_config
  WHERE config_key='default_timezone'
    AND EXISTS(SELECT 1 FROM pg_timezone_names WHERE name=config_value);
  RETURN v_timezone;
END; $$;

CREATE OR REPLACE FUNCTION social_media.resolve_relative_date(
  p_expression text,
  p_reference_now timestamptz,
  p_timezone text
) RETURNS date LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_expression text:=lower(btrim(COALESCE(p_expression,'')));
  v_local_date date;
  v_dow int;
  v_delta int;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM pg_timezone_names WHERE name=p_timezone) THEN RETURN NULL; END IF;
  v_local_date:=(COALESCE(p_reference_now,now()) AT TIME ZONE p_timezone)::date;
  IF v_expression IN ('today','hoje') THEN RETURN v_local_date; END IF;
  IF v_expression IN ('tomorrow','amanha','amanhã') THEN RETURN v_local_date+1; END IF;
  IF v_expression IN ('day_after_tomorrow','depois de amanha','depois de amanhã') THEN RETURN v_local_date+2; END IF;
  IF v_expression ~ '^weekday_[0-6]$' THEN
    v_dow:=right(v_expression,1)::int;
    v_delta:=(v_dow-extract(dow FROM v_local_date)::int+7)%7;
    IF v_delta=0 THEN v_delta:=7; END IF;
    RETURN v_local_date+v_delta;
  END IF;
  RETURN NULL;
END; $$;

CREATE OR REPLACE FUNCTION social_media.resolve_schedule_platform(
  p_client_id text,
  p_payload_platform text,
  p_message text,
  p_source text
) RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_payload text:=NULLIF(lower(btrim(p_payload_platform)),'');
  v_message text;
  v_default text;
  v_enabled jsonb;
  v_platform text;
  v_method text;
  v_trusted boolean:=lower(COALESCE(p_source,'')) IN ('admin','internal','api');
BEGIN
  IF p_message ~* '\m(instagram|insta)\M' THEN v_message:='instagram';
  ELSIF p_message ~* '\mfacebook\M' THEN v_message:='facebook';
  ELSIF p_message ~* '\mlinkedin\M' THEN v_message:='linkedin';
  ELSIF p_message ~* '\m(tiktok|tik tok)\M' THEN v_message:='tiktok'; END IF;

  SELECT lower(default_platform),COALESCE(enabled_platforms,'[]'::jsonb)
  INTO v_default,v_enabled FROM social_media.client_schedule_preferences WHERE client_id=p_client_id;
  v_enabled:=COALESCE(v_enabled,'[]'::jsonb);

  IF v_trusted AND v_payload IS NOT NULL THEN v_platform:=v_payload;v_method:='explicit_payload';
  ELSIF v_message IS NOT NULL THEN v_platform:=v_message;v_method:='explicit_message';
  ELSIF v_payload IS NOT NULL THEN v_platform:=v_payload;v_method:='explicit_payload';
  ELSIF v_default IS NOT NULL THEN v_platform:=v_default;v_method:='client_default';
  ELSE
    RETURN jsonb_build_object('ok',false,'error','PLATFORM_REQUIRED','clarification_reason','missing_platform',
      'platform_resolution_method','clarification_required','enabled_platforms',v_enabled);
  END IF;

  IF NOT (v_enabled ? v_platform) THEN
    RETURN jsonb_build_object('ok',false,'error','PLATFORM_NOT_CONFIGURED','clarification_reason','platform_not_configured',
      'platform',v_platform,'platform_resolution_method',v_method,'enabled_platforms',v_enabled);
  END IF;
  RETURN jsonb_build_object('ok',true,'platform',v_platform,'platform_resolution_method',v_method,'enabled_platforms',v_enabled);
END; $$;

CREATE OR REPLACE FUNCTION social_media.process_schedule_request_v72(
  p_channel text,p_sender_id text,p_content_id text,p_message text,p_external_message_id text,
  p_action text,p_payload_platform text,p_source text,p_target_date date,p_target_time time,
  p_use_next_slot boolean DEFAULT false,p_requested_version_id uuid DEFAULT NULL,
  p_relative_expression text DEFAULT NULL,p_reference_now timestamptz DEFAULT NULL,
  p_context_timezone text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_client text;
  v_timezone text;
  v_platform_result jsonb;
  v_platform text;
  v_platform_method text;
  v_message_id uuid;
  v_existing uuid;
  v_corr uuid;
  v_working_message text;
  v_result jsonb;
  v_schedule_id uuid;
  v_event_type text;
BEGIN
  SELECT client_id INTO v_client FROM social_media.channel_identities
  WHERE channel=p_channel AND external_sender_id=p_sender_id AND active;
  IF v_client IS NULL THEN
    RETURN social_media.process_schedule_request(p_channel,p_sender_id,p_content_id,p_message,p_external_message_id,
      p_action,p_payload_platform,p_source,p_target_date,p_target_time,p_use_next_slot,p_requested_version_id,NULL);
  END IF;

  SELECT message_id INTO v_existing FROM social_media.messages
  WHERE channel=p_channel AND external_message_id=p_external_message_id;
  IF v_existing IS NOT NULL THEN
    RETURN social_media.process_schedule_request(p_channel,p_sender_id,p_content_id,p_message,p_external_message_id,
      p_action,p_payload_platform,p_source,p_target_date,p_target_time,p_use_next_slot,p_requested_version_id,NULL);
  END IF;

  v_platform_result:=social_media.resolve_schedule_platform(v_client,p_payload_platform,p_message,p_source);
  v_platform:=v_platform_result->>'platform';
  v_platform_method:=v_platform_result->>'platform_resolution_method';
  v_timezone:=social_media.get_effective_timezone(v_client,p_context_timezone,v_platform);
  IF p_target_date IS NULL AND NULLIF(p_relative_expression,'') IS NOT NULL THEN
    p_target_date:=social_media.resolve_relative_date(p_relative_expression,COALESCE(p_reference_now,now()),v_timezone);
  END IF;

  v_corr:=gen_random_uuid();
  INSERT INTO social_media.messages(client_id,channel,external_message_id,direction,sender_id,body,raw_payload,correlation_id)
  VALUES(v_client,p_channel,p_external_message_id,'INBOUND',p_sender_id,p_message,
    jsonb_build_object('phase','7.2','content_id',p_content_id,'source',p_source,'payload_platform',p_payload_platform,
      'platform_resolution_method',v_platform_method,'relative_expression',p_relative_expression,
      'reference_now',p_reference_now,'effective_timezone',v_timezone),v_corr)
  RETURNING message_id INTO v_message_id;

  IF NOT COALESCE((v_platform_result->>'ok')::boolean,false) THEN
    RETURN social_media.emit_schedule_result(v_corr,v_client,NULLIF(p_content_id,''),p_channel,'SCHEDULE_CLARIFICATION_REQUIRED',
      CASE v_platform_result->>'clarification_reason'
        WHEN 'missing_platform' THEN 'Em qual plataforma você quer publicar?'
        ELSE 'Essa plataforma não está configurada para este cliente.' END,
      v_platform_result||jsonb_build_object('timezone',v_timezone),'WARN');
  END IF;
  IF v_timezone IS NULL THEN
    RETURN social_media.emit_schedule_result(v_corr,v_client,NULLIF(p_content_id,''),p_channel,'SCHEDULE_VALIDATION_FAILED',
      'O fuso horário efetivo não está configurado corretamente.',
      jsonb_build_object('ok',false,'error','TIMEZONE_NOT_CONFIGURED','clarification_reason','missing_timezone'),'WARN');
  END IF;
  IF p_target_date IS NULL AND NULLIF(p_relative_expression,'') IS NOT NULL THEN
    RETURN social_media.emit_schedule_result(v_corr,v_client,NULLIF(p_content_id,''),p_channel,'SCHEDULE_VALIDATION_FAILED',
      'Não foi possível resolver a data relativa.',
      jsonb_build_object('ok',false,'error','RELATIVE_DATE_INVALID','clarification_reason','invalid_relative_date',
        'relative_expression',p_relative_expression,'timezone',v_timezone),'WARN');
  END IF;

  -- The 7.1 core still detects a message platform. Remove all platform words and
  -- append only the centrally resolved value; the original message is already persisted.
  v_working_message:=regexp_replace(p_message,'\m(instagram|insta|facebook|linkedin|tiktok|tik tok)\M','','gi');
  IF p_relative_expression ~ '^weekday_[0-6]$' THEN
    v_working_message:=regexp_replace(v_working_message,'\m(domingo|segunda|terça|terca|quarta|quinta|sexta|sábado|sabado)\M','','gi');
  END IF;
  v_working_message:=v_working_message||' plataforma '||v_platform;

  v_result:=social_media.process_schedule_request(p_channel,p_sender_id,p_content_id,v_working_message,p_external_message_id,
    p_action,v_platform,p_source,p_target_date,p_target_time,p_use_next_slot,p_requested_version_id,v_message_id);
  v_result:=v_result||jsonb_build_object('platform_resolution_method',v_platform_method,'effective_timezone',v_timezone,
    'relative_expression',p_relative_expression,'resolved_local_date',p_target_date);
  v_schedule_id:=NULLIF(v_result->>'schedule_id','')::uuid;

  IF v_schedule_id IS NOT NULL THEN
    UPDATE social_media.content_schedule SET metadata=metadata||jsonb_build_object(
      'platform_resolution_method',v_platform_method,'effective_timezone',v_timezone,
      'relative_expression',p_relative_expression,'reference_now',p_reference_now) WHERE id=v_schedule_id;
    UPDATE social_media.schedule_history SET details=details||jsonb_build_object(
      'platform_resolution_method',v_platform_method,'effective_timezone',v_timezone)
    WHERE history_id=(SELECT max(history_id) FROM social_media.schedule_history WHERE schedule_id=v_schedule_id);
    UPDATE social_media.events SET details=details||jsonb_build_object(
      'platform_resolution_method',v_platform_method,'effective_timezone',v_timezone,
      'relative_expression',p_relative_expression,'resolved_local_date',p_target_date)
    WHERE event_id IN (SELECT event_id FROM social_media.events WHERE correlation_id=v_corr
      AND event_type IN ('SCHEDULE_RESOLVED','SCHEDULE_CREATED') ORDER BY created_at DESC LIMIT 2);
  END IF;
  RETURN v_result;
END; $$;

COMMENT ON FUNCTION social_media.resolve_relative_date(text,timestamptz,text) IS
  'Relative dates are resolved using the effective client IANA timezone.';
COMMENT ON FUNCTION social_media.resolve_schedule_platform(text,text,text,text) IS
  'Distinguishes explicit payload, explicit message, client default and clarification.';
