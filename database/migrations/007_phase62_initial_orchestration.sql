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

ALTER TABLE social_media.external_operations
  ADD COLUMN IF NOT EXISTS version_id uuid REFERENCES social_media.content_versions(id),
  ADD COLUMN IF NOT EXISTS idempotency_key text;

CREATE UNIQUE INDEX IF NOT EXISTS idx_external_operations_idempotency
  ON social_media.external_operations(idempotency_key)
  WHERE idempotency_key IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_one_successful_image_per_version
  ON social_media.external_operations(version_id, operation_type)
  WHERE version_id IS NOT NULL
    AND operation_type = 'IMAGE_GENERATION'
    AND status = 'SUCCESS';

UPDATE social_media.external_operations eo
SET version_id = (eo.response_metadata->>'version_id')::uuid,
    idempotency_key = 'image:' || (eo.response_metadata->>'version_id')
WHERE eo.operation_type = 'IMAGE_GENERATION'
  AND eo.status = 'SUCCESS'
  AND eo.version_id IS NULL
  AND eo.response_metadata ? 'version_id'
  AND eo.operation_id = (
    SELECT e2.operation_id
    FROM social_media.external_operations e2
    WHERE e2.operation_type = 'IMAGE_GENERATION'
      AND e2.status = 'SUCCESS'
      AND e2.response_metadata->>'version_id' = eo.response_metadata->>'version_id'
    ORDER BY e2.created_at DESC, e2.operation_id DESC
    LIMIT 1
  )
  AND NOT EXISTS (
    SELECT 1 FROM social_media.external_operations other
    WHERE other.operation_id <> eo.operation_id
      AND other.idempotency_key = 'image:' || (eo.response_metadata->>'version_id')
  );
