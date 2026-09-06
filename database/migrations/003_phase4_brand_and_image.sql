UPDATE social_media.clients
SET
  primary_colors = '["#000000", "#FFFFFF"]'::jsonb,
  secondary_colors = '["#3B3F40"]'::jsonb,
  fonts = '["Arial"]'::jsonb,
  logo_path = 'assets/brands/webtech-demo/logos/webtech-official-logo.jpg',
  brand_rules = '[
    "utilizar somente preto, branco e cinza",
    "usar conceitos ligados a tecnologia e automacao",
    "preservar o logo original",
    "nao redesenhar o logo com IA",
    "nao escrever o logo utilizando fontes aproximadas",
    "nao distorcer a proporcao do logo",
    "manter bom contraste",
    "manter composicao limpa e profissional",
    "nao inventar resultados ou metricas"
  ]'::jsonb,
  reference_images = '[
    "assets/brands/webtech-demo/logos/webtech-official-logo.jpg"
  ]'::jsonb,
  restrictions = '[
    "nao inserir logo, texto, CTA, telefone ou endereco na imagem gerada"
  ]'::jsonb,
  preferences = jsonb_build_object(
    'logo_paths', jsonb_build_object(
      'official', 'assets/brands/webtech-demo/logos/webtech-official-logo.jpg'
    ),
    'font_asset_available', false,
    'image_generation', jsonb_build_object(
      'use_brand_palette_for_atmosphere', true,
      'insert_logo', false,
      'insert_text', false
    )
  ),
  updated_at = now()
WHERE client_id = 'webtech-demo';

ALTER TABLE social_media.content_items
  DROP CONSTRAINT IF EXISTS content_items_status_check;

ALTER TABLE social_media.content_items
  ADD CONSTRAINT content_items_status_check CHECK (status IN (
    'REQUEST_RECEIVED', 'NEEDS_CLARIFICATION', 'BRIEFING_CREATED', 'GENERATING_CONTENT',
    'GENERATING_IMAGE', 'IMAGE_GENERATED', 'IMAGE_GENERATION_FAILED',
    'CREATING_ART', 'ART_RENDER_FAILED', 'LAYOUT_VALIDATION_FAILED', 'READY_FOR_APPROVAL',
    'SENT_FOR_APPROVAL', 'APPROVED', 'CHANGES_REQUESTED',
    'REVISION_IN_PROGRESS', 'RENDERING', 'REJECTED',
    'SCHEDULED', 'READY_TO_PUBLISH', 'MISSED', 'PUBLISHED', 'FAILED'
  ));

INSERT INTO social_media.runtime_config (config_key, config_value)
VALUES
  ('image_provider', :'image_provider'),
  ('image_model', :'image_model')
ON CONFLICT (config_key) DO UPDATE
SET config_value = EXCLUDED.config_value,
    updated_at = now();

CREATE INDEX IF NOT EXISTS idx_external_operations_content_type
  ON social_media.external_operations(content_id, operation_type, created_at DESC);
