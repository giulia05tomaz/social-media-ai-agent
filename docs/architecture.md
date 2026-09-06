# Arquitetura

O AI Social Media Agent separa orquestração, persistência, renderização e publicação. Essa divisão mantém o fluxo extensível e permite aplicar travas específicas antes de cada efeito externo.

![Arquitetura do sistema](images/architecture.png)

## Componentes

### n8n

Recebe a entrada, cria IDs de correlação e conduz os workflows de identificação, conteúdo, imagem, renderização, aprovação, agendamento e publicação. Os arquivos em `n8n/workflows/` são a representação versionada dessas automações.

### PostgreSQL

É a fonte de verdade para clientes, perfis de marca, mensagens, eventos, conteúdo, versões, layouts, aprovações, calendários, contas sociais e jobs de publicação. As migrations são aplicadas em ordem durante o bootstrap.

### Providers de IA

Os workflows usam configuração por provider. O modo `mock` permite desenvolver e testar sem tráfego externo; providers reais podem ser habilitados por ambiente. Os contratos em `schemas/` validam a estrutura do conteúdo e das decisões de aprovação.

### Renderer

O serviço FastAPI usa Pillow para combinar imagem, logo e copy em um canvas 1080 × 1080. O template define safe areas, limites de escala, prioridades, tipografia e regras de colisão. A saída inclui PNG, checksum e `layout_spec` persistível.

### Scheduler e publicação

O scheduler resolve o horário no timezone do cliente e cria a fila. O serviço de publicação valida a versão aprovada, o canal, a conta social, o checksum e as travas de runtime antes de enviar a mídia ao R2 e criar a publicação no Buffer.

## Fluxo de dados

1. `messages` registra a entrada recebida.
2. `events` registra a evolução observável do processamento.
3. O perfil de marca orienta structured output e geração visual.
4. Conteúdo e arte recebem versões imutáveis.
5. Aprovação seleciona uma versão; não autoriza automaticamente a publicação.
6. Agenda e job de publicação mantêm estados separados.
7. O worker executa apenas quando todos os guards são satisfeitos.

## Isolamento multi-cliente

Recursos de conteúdo, versão, calendário e conta social carregam a associação do cliente. Operações críticas validam essas relações antes de alterar estado ou produzir efeitos externos. A configuração da marca também é carregada por cliente, evitando templates globais implícitos.

## Extensibilidade

- providers de texto, imagem, armazenamento e publicação são configuráveis;
- novos templates entram como documentos versionados;
- canais adicionais podem reutilizar aprovação, agenda e fila;
- eventos permitem incorporar observabilidade sem acoplar a lógica de negócio.
