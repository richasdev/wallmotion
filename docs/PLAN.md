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

## Evolução depois do MVP

A primeira sequência abaixo é o registro histórico. O estado atual e as próximas prioridades estão na seção de 31/10; não considerar recursos dessa lista como pendentes apenas por terem sido previstos após o MVP.

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

## Estado atual — 31/10/2026 (JST)

| Área | Implementado e integrado | Validação e limites |
| --- | --- | --- |
| Biblioteca | Importação gerenciada, busca/filtros/ordenação, renomeação, remoção por ID atual e preservação de cópias compartilhadas | Fixtures temporárias; [catálogo](qa/library-filters.md), [integridade](qa/shared-media-removal.md) e [ciclo da folha](qa/rename-lifecycle.md) |
| Monitores | Seleção independente, espelhamento e panorama de foto local; ajuste/preenchimento/centralização/esticar | [Controles](qa/display-controls.md) e [compatibilidade](qa/panorama-compatibility.md); panorama animado e QA físico permanecem abertos |
| Fotos | Preparação serial assíncrona, limite por bitmap e por lote, dimensões da foto e bitmap instalado | [Lote](qa/photo-batch-budget.md) e [dimensões](qa/photo-quality.md); os orçamentos não equivalem a RSS/GPU |
| GIF e miniaturas | Scanner Rust por leitura antecipada de 8 KiB, limite de entrada GIF, orçamento/trabalho estrutural, fila limitada e deduplicação de miniaturas | [Scanner](qa/gif-file-stream.md), [entrada GIF](qa/gif-input-budget.md), [trabalho](qa/gif-work-budget.md), [fila](qa/thumbnail-scheduler.md); compartilhar uma animação mutável entre views ainda não está aprovado |
| Vídeo e web | AVFoundation local/HTTPS/HLS, preferência HLS, embeds oficiais YouTube/Vimeo, posição inicial YouTube e diagnóstico de falhas | [HLS](qa/hls-quality.md), [YouTube](qa/youtube-start.md), [Vimeo](qa/vimeo-diagnostics.md); disponibilidade depende do provedor, sem login/DRM/playlists |
| Áudio e energia | Som desativado inicialmente, um monitor com áudio, ganho global, pausas manuais/sistema/baixo consumo/térmica e liberação sob memória crítica | [Áudio](qa/audio-volume.md), [térmica](qa/thermal-pause.md), [memória](qa/memory-pressure.md); nenhuma garantia de consumo energético ou de prevenção de OOM |
| Inicialização | Lease cooperativo e encaminhamento de arquivos entre instâncias, início automático opt-in | [Instância](qa/single-instance.md), [handoff](qa/runtime-file-handoff.md), [login](qa/login-item.md); restauração não-default sem URLs ainda requer QA |
| Ferramentas | Build ad-hoc, limpeza dos próprios artefatos, snapshots opt-in, CPU por intervalos, auditor de asserções de energia e probe HLS sintético | [CPU](qa/cpu-intervals.md), [energia](qa/power-assertions.md), [HLS sintético](qa/hls-probe.md), [limpeza](qa/build-cleanup.md); CI remoto segue bloqueado por #11 |

Os itens integrados possuem testes locais/revisões registrados nas PRs e documentos vinculados. Capturas de componentes e fixtures não substituem teste físico de cor, múltiplos monitores, repouso ou VoiceOver.

## Próximas prioridades

1. **Qualidade visual e acessibilidade:** completar a matriz física de monitores/escala/rotação, panorama e VoiceOver (#43, #47). Preservar o enquadramento e verificar qualidade com mídia real.
2. **Vídeo e provedores:** validar streams HLS adaptativos, portrait e transições HDR/SDR (#101), além dos cenários Vimeo (#42). Separar observação sintética de certificação de hardware.
3. **Performance medida:** executar os protocolos de CPU, memória, asserções e energia com cenários controlados (#8, #91, #63, #77). Não anunciar ganhos de Rust/cache sem medições comparáveis.
4. **Compartilhamento e novos recursos:** estudar decodificador de vídeo espelhado (#44), animações GIF compartilhadas (#14), mixer de áudio (#45) e panorama animado (#43), com provas de ciclo de vida antes de integrar. Playlists, agendamento e importação/exportação de coleções ainda são propostas.
5. **Distribuição:** resolver o bloqueio de CI (#11), concluir QA de restauração (#88) e preparar assinatura Developer ID/notarização antes de distribuição pública.

## Fluxo multiagente atual: dois agentes

1. **Codex** implementa, reproduz achados e executa os checks adequados em branches e worktrees isoladas; faz commits pequenos por entrega e abre PRs.
2. **Antigravity (`agy`)** estuda, abre issues, faz revisão independente com busca de bugs no HEAD exato, registra evidências/limites e realiza merge protegido quando seguro.
3. Alterar o HEAD exige nova revisão. A conclusão depende do código/testes e do escopo real, não apenas de um parecer favorável. O merge deve conferir o SHA revisado e as exigências do repositório, sem bypass.
4. Revisões usam a identidade GitHub disponível com veredito explícito em comentário; isso não representa aprovações de contas independentes. Não há terceiro agente dedicado a testes neste fluxo.
5. Atualizar a issue/PR com o resultado e limpar apenas artefatos próprios após parar os compiladores, preservando o app em `dist/`.

Veja a [política de revisão](REVIEW-POLICY.md). Questões de hardware ou serviço externo permanecem abertas quando a validação ainda não foi executada.
