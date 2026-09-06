ALTER TABLE social_media.content_items
  DROP CONSTRAINT IF EXISTS content_items_status_check;

ALTER TABLE social_media.content_items
  ADD CONSTRAINT content_items_status_check CHECK (status IN (
    'REQUEST_RECEIVED', 'NEEDS_CLARIFICATION', 'BRIEFING_CREATED',
    'GENERATING_CONTENT', 'GENERATING_IMAGE', 'IMAGE_GENERATED',
    'IMAGE_GENERATION_FAILED', 'CREATING_ART', 'ART_RENDER_FAILED', 'LAYOUT_VALIDATION_FAILED',
    'READY_FOR_APPROVAL', 'SENT_FOR_APPROVAL',
    'CHANGES_REQUESTED', 'REVISION_IN_PROGRESS', 'RENDERING',
    'APPROVED', 'REJECTED', 'SCHEDULED', 'READY_TO_PUBLISH', 'MISSED', 'PUBLISHED', 'FAILED'
  ));

CREATE UNIQUE INDEX IF NOT EXISTS idx_approvals_message_once
  ON social_media.approvals(message_id)
  WHERE message_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_change_requests_approval_once
  ON social_media.change_requests(approval_id);

UPDATE social_media.render_outputs
SET layout_spec = jsonb_set(
      jsonb_set(layout_spec, '{safety,logo_scale}', '{"min":0.70,"max":1.30}'::jsonb, true),
      '{safety,product_bounds}', '{"min_x":460,"max_right":1050,"min_y":60,"max_bottom":1000}'::jsonb, true
    ),
    updated_at = now()
WHERE layout_spec ? 'safety';
