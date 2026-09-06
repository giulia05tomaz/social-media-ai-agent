CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE SCHEMA IF NOT EXISTS social_media;

CREATE TABLE IF NOT EXISTS social_media.clients (
  client_id text PRIMARY KEY,
  brand_name text NOT NULL,
  business_type text,
  logo_path text,
  primary_colors jsonb NOT NULL DEFAULT '[]'::jsonb,
  secondary_colors jsonb NOT NULL DEFAULT '[]'::jsonb,
  fonts jsonb NOT NULL DEFAULT '[]'::jsonb,
  tone text,
  address text,
  phone text,
  instagram text,
  website text,
  brand_rules jsonb NOT NULL DEFAULT '[]'::jsonb,
  products jsonb NOT NULL DEFAULT '[]'::jsonb,
  services jsonb NOT NULL DEFAULT '[]'::jsonb,
  reference_images jsonb NOT NULL DEFAULT '[]'::jsonb,
  templates jsonb NOT NULL DEFAULT '[]'::jsonb,
  restrictions jsonb NOT NULL DEFAULT '[]'::jsonb,
  preferences jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS social_media.channel_identities (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id text NOT NULL REFERENCES social_media.clients(client_id),
  channel text NOT NULL,
  external_sender_id text NOT NULL,
  active boolean NOT NULL DEFAULT true,
  UNIQUE (channel, external_sender_id)
);

CREATE TABLE IF NOT EXISTS social_media.messages (
  message_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id text REFERENCES social_media.clients(client_id),
  channel text NOT NULL,
  external_message_id text,
  direction text NOT NULL CHECK (direction IN ('INBOUND', 'OUTBOUND')),
  sender_id text,
  body text,
  raw_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE SEQUENCE IF NOT EXISTS social_media.content_number_seq START 1;

CREATE TABLE IF NOT EXISTS social_media.content_items (
  content_id text PRIMARY KEY DEFAULT (
    'CONTENT-' || to_char(CURRENT_DATE, 'YYYY') || '-' ||
    lpad(nextval('social_media.content_number_seq')::text, 5, '0')
  ),
  client_id text NOT NULL REFERENCES social_media.clients(client_id),
  source_message_id uuid REFERENCES social_media.messages(message_id),
  request jsonb NOT NULL DEFAULT '{}'::jsonb,
  briefing jsonb,
  caption text,
  image_prompt text,
  generated_image_path text,
  final_art_path text,
  status text NOT NULL DEFAULT 'REQUEST_RECEIVED' CHECK (status IN (
    'REQUEST_RECEIVED', 'BRIEFING_CREATED', 'GENERATING_CONTENT',
    'GENERATING_IMAGE', 'CREATING_ART', 'READY_FOR_APPROVAL',
    'SENT_FOR_APPROVAL', 'APPROVED', 'CHANGES_REQUESTED',
    'REVISION_IN_PROGRESS', 'SCHEDULED', 'READY_TO_PUBLISH', 'MISSED', 'PUBLISHED', 'FAILED'
  )),
  approval_status text NOT NULL DEFAULT 'PENDING' CHECK (approval_status IN ('PENDING', 'APPROVED', 'REJECTED')),
  scheduled_at timestamptz,
  published_at timestamptz,
  approved_at timestamptz,
  approved_by text,
  approval_message text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS social_media.content_versions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  content_id text NOT NULL REFERENCES social_media.content_items(content_id),
  version integer NOT NULL CHECK (version > 0),
  version_label text GENERATED ALWAYS AS (content_id || '-v' || version::text) STORED,
  change_request jsonb,
  briefing jsonb,
  copy jsonb,
  generated_image_path text,
  final_art_path text,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (content_id, version)
);

CREATE TABLE IF NOT EXISTS social_media.content_schedule (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  content_id text NOT NULL REFERENCES social_media.content_items(content_id),
  client_id text NOT NULL REFERENCES social_media.clients(client_id),
  platform text NOT NULL,
  scheduled_date date NOT NULL,
  scheduled_time time NOT NULL,
  timezone text NOT NULL DEFAULT 'America/Sao_Paulo',
  status text NOT NULL DEFAULT 'SCHEDULED',
  cancelled_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (content_id, platform)
);

CREATE TABLE IF NOT EXISTS social_media.events (
  event_id bigserial PRIMARY KEY,
  correlation_id uuid NOT NULL DEFAULT gen_random_uuid(),
  client_id text,
  content_id text,
  event_type text NOT NULL,
  workflow_name text,
  severity text NOT NULL DEFAULT 'INFO' CHECK (severity IN ('DEBUG', 'INFO', 'WARN', 'ERROR')),
  details jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS social_media.external_operations (
  operation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  content_id text REFERENCES social_media.content_items(content_id),
  operation_type text NOT NULL,
  provider text NOT NULL,
  model text,
  prompt text,
  external_id text,
  file_path text,
  cost_estimate numeric(12,6),
  status text NOT NULL,
  response_metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_messages_client_created ON social_media.messages(client_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_content_status ON social_media.content_items(status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_schedule_due ON social_media.content_schedule(status, scheduled_date, scheduled_time);
CREATE INDEX IF NOT EXISTS idx_events_correlation ON social_media.events(correlation_id, created_at);

INSERT INTO social_media.clients (
  client_id, brand_name, business_type, primary_colors, secondary_colors,
  fonts, tone, instagram, logo_path, brand_rules, restrictions
) VALUES (
  'webtech-demo',
  'WebTech Demo',
  'Tecnologia, automacao, marketing e programacao',
  '["#000000", "#FFFFFF"]'::jsonb,
  '["#3B3F40"]'::jsonb,
  '["Arial"]'::jsonb,
  'moderno, tecnologico, profissional e direto',
  NULL,
  NULL,
  '["utilizar a identidade visual cadastrada", "nao inventar metricas", "preservar o logo original", "usar somente a paleta configurada"]'::jsonb,
  '["credenciais e contas sociais devem ser configuradas localmente"]'::jsonb
) ON CONFLICT (client_id) DO NOTHING;

INSERT INTO social_media.channel_identities (client_id, channel, external_sender_id)
VALUES ('webtech-demo', 'webhook', 'demo-user')
ON CONFLICT (channel, external_sender_id) DO NOTHING;
