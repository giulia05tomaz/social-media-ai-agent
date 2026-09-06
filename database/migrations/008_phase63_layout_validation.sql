ALTER TABLE social_media.content_items
  DROP CONSTRAINT IF EXISTS content_items_status_check;

ALTER TABLE social_media.content_items
  ADD CONSTRAINT content_items_status_check CHECK (status IN (
    'REQUEST_RECEIVED', 'NEEDS_CLARIFICATION', 'BRIEFING_CREATED',
    'GENERATING_CONTENT', 'GENERATING_IMAGE', 'IMAGE_GENERATED',
    'IMAGE_GENERATION_FAILED', 'CREATING_ART', 'ART_RENDER_FAILED',
    'LAYOUT_VALIDATION_FAILED', 'READY_FOR_APPROVAL', 'SENT_FOR_APPROVAL',
    'APPROVED', 'CHANGES_REQUESTED', 'REVISION_IN_PROGRESS', 'RENDERING',
    'REJECTED', 'SCHEDULED', 'READY_TO_PUBLISH', 'MISSED', 'PUBLISHED', 'FAILED'
  ));

ALTER TABLE social_media.render_outputs
  DROP CONSTRAINT IF EXISTS render_outputs_status_check;

ALTER TABLE social_media.render_outputs
  ADD CONSTRAINT render_outputs_status_check CHECK (status IN (
    'CREATING_ART', 'READY_FOR_APPROVAL', 'LAYOUT_VALIDATION_FAILED', 'FAILED'
  ));

CREATE OR REPLACE FUNCTION social_media.audit_layout_validation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  layout_warnings jsonb := COALESCE(NEW.layout_spec #> '{layout_resolution,warnings}', '[]'::jsonb);
  event_name text;
BEGIN
  IF NEW.status <> 'READY_FOR_APPROVAL'
     OR COALESCE((NEW.layout_spec #>> '{validation,valid}')::boolean, false) IS NOT TRUE THEN
    RETURN NEW;
  END IF;

  FOREACH event_name IN ARRAY ARRAY['LAYOUT_VALIDATED']::text[] LOOP
    INSERT INTO social_media.events(client_id, content_id, event_type, workflow_name, details)
    SELECT c.client_id, NEW.content_id, event_name, 'renderer-auto-layout',
      jsonb_build_object(
        'version_id', NEW.version_id,
        'validation', NEW.layout_spec->'validation',
        'warnings', layout_warnings,
        'layout_resolution_ms', NEW.layout_spec #>> '{layout_resolution,duration_ms}'
      )
    FROM social_media.content_items c
    WHERE c.content_id = NEW.content_id
      AND NOT EXISTS (
        SELECT 1 FROM social_media.events existing_event
        WHERE existing_event.content_id = NEW.content_id
          AND existing_event.event_type = event_name
          AND existing_event.details->>'version_id' = NEW.version_id::text
      );
  END LOOP;

  IF EXISTS (SELECT 1 FROM jsonb_array_elements(layout_warnings) warning WHERE warning->>'type' = 'text_wrapped') THEN
    INSERT INTO social_media.events(client_id, content_id, event_type, workflow_name, details)
    SELECT c.client_id, NEW.content_id, 'TEXT_WRAPPED', 'renderer-auto-layout', jsonb_build_object('version_id', NEW.version_id, 'warnings', layout_warnings)
    FROM social_media.content_items c
    WHERE c.content_id = NEW.content_id
      AND NOT EXISTS (SELECT 1 FROM social_media.events existing_event WHERE existing_event.content_id=NEW.content_id AND existing_event.event_type='TEXT_WRAPPED' AND existing_event.details->>'version_id'=NEW.version_id::text);
  END IF;

  IF EXISTS (SELECT 1 FROM jsonb_array_elements(layout_warnings) warning WHERE warning->>'type' = 'font_size_adjusted') THEN
    INSERT INTO social_media.events(client_id, content_id, event_type, workflow_name, details)
    SELECT c.client_id, NEW.content_id, 'FONT_SIZE_ADJUSTED', 'renderer-auto-layout', jsonb_build_object('version_id', NEW.version_id, 'warnings', layout_warnings)
    FROM social_media.content_items c
    WHERE c.content_id = NEW.content_id
      AND NOT EXISTS (SELECT 1 FROM social_media.events existing_event WHERE existing_event.content_id=NEW.content_id AND existing_event.event_type='FONT_SIZE_ADJUSTED' AND existing_event.details->>'version_id'=NEW.version_id::text);
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_layout_validation ON social_media.render_outputs;
CREATE TRIGGER trg_audit_layout_validation
AFTER INSERT OR UPDATE OF status, layout_spec ON social_media.render_outputs
FOR EACH ROW EXECUTE FUNCTION social_media.audit_layout_validation();
