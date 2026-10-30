# Plano de entregas

## Produto

Wallmotion oferece uma biblioteca pessoal de fundos de tela com importação de fotos, vídeos e GIFs e adição de URLs HTTPS de mídia. Cada monitor pode ter uma seleção independente. O app permanece na barra de menu e respeita pausa manual, suspensão e modo de baixo consumo.

## MVP — primeira sequência de issues

| Issue | Entrega | Critério de conclusão |
| --- | --- | --- |
| #1 | Arquitetura e plano | Decisões e escopo registrados; estudo delegado ao Antigravity |
| #2 | Biblioteca persistente | Importação gerenciada, validação HTTPS, JSON atômico e testes |
| #3 | Motor desktop | Uma janela por monitor; fotos/GIF/vídeo; cliques passam ao Finder |
| #4 | Interface | Biblioteca SwiftUI, selecionar monitor, aplicar/remover e barra de menu |
| #5 | Energia e recuperação | Pausa automática, restauração da sessão, revisão e correções |
| #6 | Build e QA | `.app` reproduzível, CI macOS e roteiro de validação manual |

Cada issue concluída deve ter commit próprio com referência à issue. Builds e testes são executados antes de fechar a entrega. Itens que exigem interação humana ou outro hardware devem ser descritos como pendentes, sem declarar verificação inexistente.

## Depois do MVP

- #7: páginas web/YouTube com WKWebView e APIs oficiais, avaliando autoplay, privacidade e pausa.
- #8: medições reais de energia/performance; fullscreen/oclusão; assinatura, notarização e início automático opt-in.
- Futuro: playlists, agendamento, thumbnails em cache, arrastar e soltar e importação/exportação de coleções.

## Situação da primeira entrega — 30/10/2026

- #1–#4: arquitetura, biblioteca, renderização desktop e interface implementadas e publicadas.
- #5: política de energia, recuperação, testes AppKit e correções da revisão integradas.
- #6: build release do app, assinatura ad-hoc de desenvolvimento, workflow e QA adicionados.
- #9: scanner Rust integrado via ABI C, orçamento de GIF, downsample de fotos e benchmark reproduzível.
- #10: nome Wallmotion padronizado no conteúdo atual e classe `DesktopCoordinator`.
- #12: limpeza de artefatos Cargo entre ciclos; execução local removeu 43 MiB e preservou release/app.
- #11: CI remoto impedido de iniciar por cobrança/limite da conta GitHub; checks locais passaram.
- #7 e #8 permanecem como evolução: páginas web, métricas sustentadas, QA de hardware e distribuição pública.

O app é um MVP de desenvolvimento. As verificações automatizadas e os limites físicos estão em [QA](QA.md) e as decisões sobre achados em [resolução da revisão](REVIEW-RESOLUTION.md).

## Fluxo multiagente

1. Antigravity estuda APIs públicas, ciclo de vida, limites e armadilhas.
2. Codex implementa módulos pequenos, mantendo contratos claros para os testes paralelos.
3. Agente Codex de testes verifica validação e persistência em diretórios isolados.
4. Antigravity revisa a implementação; o coordenador reproduz e corrige achados antes do fechamento.
5. Commit e atualização da issue com evidências e limites da validação.
