# Renderer e auto-layout

O servico interno usa Python, Pillow e FastAPI. Ele nao chama IA nem executa shell.

## Pipeline

1. valida paths, assets, canvas e paleta;
2. resolve headline, subtitle e CTA com medicao real de fonte;
3. aplica fluxo vertical e largura dinamica do CTA;
4. valida safe areas, canvas e colisoes;
5. somente entao renderiza o PNG e grava o `layout_spec` resolvido.

Cada elemento textual persiste `resolved.font_size`, `resolved.lines`, `resolved.bbox` e `resolved.line_step`. O spec tambem guarda `layout_resolution`, `validation`, warnings e tempos.

Uma composicao impossivel levanta `LAYOUT_VALIDATION_FAILED`; nenhum PNG parcial e promovido. Os endpoints `POST /render-initial` e `POST /apply-and-render` retornam o mesmo contrato de validacao.

## Testes

```sh
python /app/renderer/test_phase63.py
```

A suite usa a fotografia persistida da Fase 6.2 e gera somente artefatos locais em `/app/tests/output/phase63` e o comparativo `final-v1-layout-fixed.png`.
