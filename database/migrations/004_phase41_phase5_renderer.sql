ALTER TABLE social_media.content_items
  DROP CONSTRAINT IF EXISTS content_items_status_check;

ALTER TABLE social_media.content_items
  ADD CONSTRAINT content_items_status_check CHECK (status IN (
    'REQUEST_RECEIVED', 'NEEDS_CLARIFICATION', 'BRIEFING_CREATED',
    'GENERATING_CONTENT', 'GENERATING_IMAGE', 'IMAGE_GENERATED',
    'IMAGE_GENERATION_FAILED', 'CREATING_ART', 'ART_RENDER_FAILED', 'LAYOUT_VALIDATION_FAILED',
    'READY_FOR_APPROVAL', 'SENT_FOR_APPROVAL', 'APPROVED',
    'CHANGES_REQUESTED', 'REVISION_IN_PROGRESS', 'RENDERING',
    'REJECTED', 'SCHEDULED', 'READY_TO_PUBLISH', 'MISSED', 'PUBLISHED', 'FAILED'
  ));

CREATE TABLE IF NOT EXISTS social_media.render_outputs (
  render_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  content_id text NOT NULL REFERENCES social_media.content_items(content_id),
  version_id uuid NOT NULL REFERENCES social_media.content_versions(id),
  template_id text NOT NULL,
  renderer text NOT NULL,
  source_image_path text NOT NULL,
  final_art_path text,
  layout_spec_path text,
  layout_spec jsonb NOT NULL DEFAULT '{}'::jsonb,
  width integer,
  height integer,
  checksum_sha256 text,
  status text NOT NULL CHECK (status IN ('CREATING_ART', 'READY_FOR_APPROVAL', 'FAILED')),
  error_message text,
  rendered_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (version_id)
);

CREATE INDEX IF NOT EXISTS idx_render_outputs_content
  ON social_media.render_outputs(content_id, created_at DESC);

INSERT INTO social_media.runtime_config (config_key, config_value)
VALUES ('art_renderer', :'art_renderer')
ON CONFLICT (config_key) DO UPDATE
SET config_value = EXCLUDED.config_value,
    updated_at = now();

UPDATE social_media.clients
SET preferences = preferences || jsonb_build_object(
      'default_template_id', 'webtech-ai-agent-v1',
      'typography', jsonb_build_object(
        'official', 'Arial',
        'official_file_available', false,
        'heading_fallback', 'Arial Bold',
        'body_fallback', 'Arial'
      )
    ),
    updated_at = now()
WHERE client_id = 'webtech-demo';
