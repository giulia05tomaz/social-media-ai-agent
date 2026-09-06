# Segurança e confiabilidade
Se encontrar uma vulnerabilidade, evite publicar credenciais, dados pessoais ou um procedimento explorável em uma issue pública. Entre em contato com a responsável pelo projeto pelo perfil indicado no README.
Este repositório público contém somente configuração de exemplo e assets da demonstração WebTech. Chaves, tokens, dumps, sessões de navegador, logs internos e dados de clientes não fazem parte da distribuição.

## Padrões seguros

A configuração de exemplo inicia em modo de demonstração:

```env
DEMO_MODE=true
LIVE_MODE=false
SOCIAL_PUBLISH_PROVIDER=mock
BUFFER_PUBLISH_ENABLED=false
BUFFER_DRY_RUN=true
PUBLICATION_WORKER_ENABLED=false
```

Ativar um provider real exige configuração deliberada. A autorização de publicação usa várias condições independentes; mudar uma única flag não é suficiente para transformar conteúdo aprovado em uma mutation externa válida.

## Proteções do fluxo

- **Secrets fora do Git:** `.env*`, credenciais e sessões são ignorados.
- **Aprovação explícita:** uma versão deve estar aprovada antes do agendamento.
- **Separação de autorização:** aprovação da arte e permissão de publicar não são o mesmo estado.
- **Idempotência:** chaves determinísticas reduzem duplicidade em jobs e mutations.
- **Checksums:** o arquivo enviado deve corresponder à versão aprovada.
- **Cross-client guards:** conteúdo, versão, conta e calendário precisam pertencer ao mesmo cliente.
- **Dry-run:** valida payloads e integrações sem criar publicações.
- **Auditoria:** eventos registram transições e falhas importantes.
- **Retries limitados:** falhas transitórias são repetidas com limites, sem converter resultado incerto em sucesso.

## Recomendações para uso próprio

1. Gere senhas e chaves internas únicas para cada ambiente.
2. Armazene credenciais em um secret manager ou no mecanismo de credenciais do n8n.
3. Restrinja tokens de R2 e canais sociais ao menor escopo possível.
4. Mantenha `LIVE_MODE=false` até concluir testes em mock e dry-run.
5. Faça backup do PostgreSQL e configure retenção de logs conforme sua política.
6. Revise versões dos containers e dependências antes de uma implantação pública.

## Divulgação responsável

Se encontrar uma vulnerabilidade, evite publicar credenciais, dados pessoais ou um procedimento explorável em uma issue pública. Entre em contato com a responsável pelo projeto pelo perfil indicado no README.
