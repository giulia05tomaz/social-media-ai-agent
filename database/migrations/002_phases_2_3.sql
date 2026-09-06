ALTER TABLE social_media.messages
  ADD COLUMN IF NOT EXISTS correlation_id uuid;

ALTER TABLE social_media.content_items
  ADD COLUMN IF NOT EXISTS title text,
  ADD COLUMN IF NOT EXISTS subtitle text,
  ADD COLUMN IF NOT EXISTS cta text,
  ADD COLUMN IF NOT EXISTS hashtags jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS visual_description text,
  ADD COLUMN IF NOT EXISTS assembly_instructions jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS automatic_response text,
  ADD COLUMN IF NOT EXISTS ai_provider text,
  ADD COLUMN IF NOT EXISTS ai_model text,
  ADD COLUMN IF NOT EXISTS structured_output jsonb;

CREATE TABLE IF NOT EXISTS social_media.runtime_config (
  config_key text PRIMARY KEY,
  config_value text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO social_media.runtime_config (config_key, config_value)
VALUES
  ('ai_provider', :'ai_provider'),
  ('ai_model', :'ai_model')
ON CONFLICT (config_key) DO UPDATE
SET config_value = EXCLUDED.config_value,
    updated_at = now();

CREATE UNIQUE INDEX IF NOT EXISTS idx_messages_external_id
  ON social_media.messages(channel, external_message_id)
  WHERE external_message_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_messages_correlation
  ON social_media.messages(correlation_id, created_at);
