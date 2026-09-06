ALTER TABLE social_media.content_items
  ADD COLUMN IF NOT EXISTS current_version_id uuid REFERENCES social_media.content_versions(id),
  ADD COLUMN IF NOT EXISTS approved_version_id uuid REFERENCES social_media.content_versions(id);

UPDATE social_media.content_items c
SET current_version_id = (
  SELECT id FROM social_media.content_versions
  WHERE content_id = c.content_id
  ORDER BY version DESC LIMIT 1
)
WHERE c.current_version_id IS NULL;

CREATE TABLE IF NOT EXISTS social_media.approvals (
  approval_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  content_id text NOT NULL REFERENCES social_media.content_items(content_id),
  version_id uuid NOT NULL REFERENCES social_media.content_versions(id),
  client_id text NOT NULL REFERENCES social_media.clients(client_id),
  message_id uuid REFERENCES social_media.messages(message_id),
  channel text NOT NULL,
  sender_id text NOT NULL,
  decision text NOT NULL CHECK (decision IN ('approved', 'changes_requested', 'rejected', 'unclear')),
  message text NOT NULL,
  structured_decision jsonb NOT NULL,
  provider text NOT NULL,
  model text,
  response_id text,
  usage jsonb NOT NULL DEFAULT '{}'::jsonb,
  cost_estimate numeric(12,6) NOT NULL DEFAULT 0,
  approved_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS social_media.change_requests (
  change_request_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  approval_id uuid NOT NULL REFERENCES social_media.approvals(approval_id),
  content_id text NOT NULL REFERENCES social_media.content_items(content_id),
  source_version_id uuid NOT NULL REFERENCES social_media.content_versions(id),
  target_version_id uuid REFERENCES social_media.content_versions(id),
  requested_by text NOT NULL,
  request_message text NOT NULL,
  interpreted_changes jsonb NOT NULL DEFAULT '[]'::jsonb,
  applied_changes jsonb NOT NULL DEFAULT '[]'::jsonb,
  requires_image_regeneration boolean NOT NULL DEFAULT false,
  status text NOT NULL CHECK (status IN ('INTERPRETED', 'REVISION_IN_PROGRESS', 'APPLIED', 'IMAGE_REGENERATION_REQUIRED', 'FAILED')),
  requested_at timestamptz NOT NULL DEFAULT now(),
  applied_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_approvals_content_created
  ON social_media.approvals(content_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_change_requests_content_created
  ON social_media.change_requests(content_id, created_at DESC);

INSERT INTO social_media.runtime_config (config_key, config_value)
VALUES
  ('approval_ai_provider', :'approval_ai_provider'),
  ('approval_ai_model', :'approval_ai_model')
ON CONFLICT (config_key) DO UPDATE
SET config_value = EXCLUDED.config_value,
    updated_at = now();

UPDATE social_media.render_outputs
SET layout_spec = layout_spec || jsonb_build_object(
      'schema_version', '2.0',
      'decorative_elements', '[
        {"id":"bottom-accent","type":"ellipse","bounds":[-210,820,310,1320],"fill":"#B3E0E1"},
        {"id":"top-secondary","type":"ellipse","bounds":[875,-190,1210,145],"fill":"#D3B0A5"},
        {"id":"side-bar","type":"rectangle","bounds":[1028,0,1080,1080],"fill":"#094339"},
        {"id":"product-shadow","type":"anchored_rounded_rectangle","anchor":"product_image","offsets":[-18,22,10,28],"radius_offset":8,"fill":"#094339"},
        {"id":"copy-separator","type":"rounded_rectangle","bounds":[80,675,354,681],"radius":3,"fill":"#D3B0A5"}
      ]'::jsonb,
      'source_assets', jsonb_build_object(
        'product_image', source_image_path,
        'logo', layout_spec #>> '{logo,asset}'
      ),
      'safety', '{
        "product_scale":{"min":0.75,"max":1.40},
        "logo_scale":{"min":0.75,"max":1.25},
        "move_step":24,
        "max_total_move":120,
        "font_size":{"min":20,"max":96},
        "product_bounds":{"min_x":460,"max_right":1050,"min_y":60,"max_bottom":1000}
      }'::jsonb
      ),
    updated_at = now()
WHERE template_id = 'webtech-ai-agent-v1'
  AND status = 'READY_FOR_APPROVAL';
