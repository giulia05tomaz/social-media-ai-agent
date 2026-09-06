#!/bin/sh
set -eu

MAIN_WORKFLOW_ID="socialMediaPhases123Orchestrator"
CREDENTIAL_ID="socialMediaPostgres"

echo "[bootstrap] Sincronizando credenciais a partir do ambiente"
node -e "const fs=require('fs'); const data=[{id:process.env.N8N_POSTGRES_CREDENTIAL_ID || '$CREDENTIAL_ID',name:'Social Media PostgreSQL',type:'postgres',data:{host:'postgres',database:process.env.DB_POSTGRESDB_DATABASE,user:process.env.DB_POSTGRESDB_USER,password:process.env.DB_POSTGRESDB_PASSWORD,port:5432,ssl:'disable',maxConnections:20,allowUnauthorizedCerts:false}},{id:'openAiHeaderAuth',name:'OpenAI API Key (env)',type:'httpHeaderAuth',data:{name:'Authorization',value:'Bearer '+(process.env.OPENAI_API_KEY || '')}},{id:'mediaDeliveryHeaderAuth',name:'Media Delivery Internal Key (env)',type:'httpHeaderAuth',data:{name:'x-internal-key',value:process.env.MEDIA_DELIVERY_INTERNAL_KEY || ''}}]; fs.writeFileSync('/tmp/social-media-credentials.json',JSON.stringify(data));"
n8n import:credentials --input=/tmp/social-media-credentials.json
rm -f /tmp/social-media-credentials.json

echo "[bootstrap] Sincronizando workflows das Fases 1 a 8.4"
for workflow in /workflows/*.json; do
  n8n import:workflow --input="$workflow"
done
n8n publish:workflow --id="socialMediaPhase2ClientIdentity"
n8n publish:workflow --id="socialMediaPhase3AIProvider"
n8n publish:workflow --id="phase4ImageGeneration"
n8n publish:workflow --id="phase62InitialRenderOrchestrator"
n8n publish:workflow --id="phase61RevisionOrchestrator"
n8n publish:workflow --id="phase6ApprovalResponse"
n8n publish:workflow --id="phase7SchedulingOrchestrator"
n8n publish:workflow --id="phase7SchedulerWorker"
n8n publish:workflow --id="phase831PublicationOrchestrator"
n8n unpublish:workflow --id="phase831PublisherWorker" || true
n8n publish:workflow --id="phase84FirstLivePreflight"
n8n unpublish:workflow --id="phase84FirstLiveOneShot" || true
n8n unpublish:workflow --id="phase81InstagramPublish" || true
n8n unpublish:workflow --id="phase81PublisherWorker" || true
n8n publish:workflow --id="$MAIN_WORKFLOW_ID"

exec n8n start
