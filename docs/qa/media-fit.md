# Validação local — issue #20

Data: 2026-10-30. Branch: `agents/sol-fit-fill`. Referência: https://github.com/richasdev/wallmotion/issues/20.

## Roteiro específico de ajustar/preencher

Este arquivo concentra o roteiro e os limites da issue #20. `docs/QA.md` permanece conforme main; o conteúdo dos demais recursos não foi alterado.

- [ ] Alternar Ajustar/Preencher em fotos, GIFs e vídeos de proporções diferentes, incluindo retrato e panorama; verificar faixas/recorte central sem distorção em Retina.
- [ ] Trocar de mídia/monitor e voltar; reabrir o app e confirmar preferência por par mídia/monitor.
- [ ] Carregar JSON versão 1 sem `mediaFits`; confirmar padrão Ajustar sem perda de atribuições.
- [ ] Confirmar a explicação de resolução reduzida no seletor. Em fotos extremas, aceitar menor nitidez para respeitar o orçamento, mantendo proporção e recorte.
- [ ] Repetir pausa manual, oclusão/desoclusão e alteração do outro monitor com GIF em Preencher; a decisão central de playback deve continuar efetiva.

Ajustar mostra toda a mídia, com possíveis faixas; Preencher mantém a proporção e recorta no centro. Fotos usam dimensões orientadas e escala Retina, sem decodificar acima da resolução original. Ambos os modos respeitam o teto conservador de 128 MiB por bitmap (16 bytes/pixel e linhas alinhadas a 64 bytes) e lado máximo de 16.384 pixels. Ao atingir o teto, a resolução é reduzida e o recorte preservado; o layout real retornado pelo ImageIO também é verificado. O orçamento é por bitmap de saída, não por RSS global/temporários dos codecs; decode permanece síncrono. Trocar modo recria apenas o renderer daquele monitor, reiniciando seu vídeo. GIF continua sujeito aos orçamentos existentes da main.

Os roteiros gerais de Spaces, Stage Manager, pausa por política, vídeos remotos e consumo de energia permanecem em `../QA.md`. Sem certificação física de dois monitores, nitidez em todas as telas ou benchmark de pico de memória/energia; CI remoto bloqueado por billing #11.

## Comportamento

- Ajustar mostra a mídia inteira; Preencher recorta no centro. Ambos preservam a proporção.
- Preferência por par mídia/monitor, preservada ao trocar de wallpaper, limpar a atribuição ou desconectar o monitor. Remover a mídia apaga suas preferências.
- JSON continua versão 1; `assignments` continua display → UUID. O novo campo opcional `mediaFits` é display → UUID de mídia → `fit`/`fill`. Sua ausência usa `fit`; valores inválidos são rejeitados sem sobrescrever o arquivo.
- Fotos usam dimensões orientadas e escala de backing Retina para calcular o limite ImageIO. Não há upsampling na decodificação. Preencher pode exigir uma imagem maior que Ajustar; agora o orçamento de saída limita ambos os modos, reduzindo resolução quando necessário (correção dos pareceres abaixo).
- GIF mantém animação/pausa via NSImageView dentro do contêiner que recorta. Vídeos usam `resizeAspect`/`resizeAspectFill` do AVPlayerLayer.
- Alterar o modo recria somente o renderizador do monitor afetado; isso reinicia o vídeo desse monitor. Os demais renderizadores são preservados. A reconciliação também considera mudanças de escala Retina.

## Checks executados

Todos os comandos foram invocados por `/opt/homebrew/bin/rtk` neste worktree, sequencialmente para builds.

- `CARGO_INCREMENTAL=0 sh scripts/check.sh`: passou após corrigir import explícito de CoreGraphics; Rust estático release construído antes de Swift; 6 testes Rust, Clippy com `-D warnings`, 43 testes Swift Testing e 15 testes XCTest (3 ignorados na execução padrão).
- Após a orientação de limitar concorrência: `WALLMOTION_SNAPSHOT_PATH=/tmp/wallmotion-issue20-library.png swift test -j 2`: 43 testes do núcleo aprovados; XCTest executou 15, com 13 aprovados e 2 ignorados (rede opt-in e dois monitores).
- Após ajuste do rótulo visual: `WALLMOTION_SNAPSHOT_PATH=/tmp/wallmotion-issue20-library.png swift test -j 2 --filter testOptionalLibraryViewSnapshotUsesOnlyTemporaryFixtures`: aprovado. Snapshot inspecionado visualmente com o modo Preencher ativo; fixtures e estado temporários.
- `swift build -c release -j 2`: aprovado, com biblioteca Rust estática previamente construída.
- `git diff --check`: aprovado.

A cobertura nova inclui paisagem/retrato, centralização e proporção de fit/fill, mesma proporção, dimensões vazias, orçamento de pixels para recorte/Retina e fonte pequena, fixture JSON legado sem campo novo, persistência por mídia/monitor, remoção e preferências inválidas. A integração verifica frames/clipping de imagem, gravidade nativa de vídeo, pausa de GIF em fill, persistência via LibraryModel e reconciliação ao alterar modo.

## Limitações e integração

- CI remoto indisponível por billing (#11); os resultados acima são locais.
- O host tinha um monitor disponível: preservação entre dois monitores continua pendente de execução física. Reprodução remota não foi habilitada nesta validação. Sem benchmark de CPU/GPU/RAM/energia ou certificação visual de wallpapers/Spaces/Stage Manager.
- Pontos de possível conflito com agentes paralelos: `DesktopCoordinator.swift` (tipo Entry, condição de reutilização, inicializador do renderizador e superfícies), `LibraryModel.swift`, `LibraryView.swift` e testes AppKit que esperavam NSImageView diretamente como contentView. Agora a imagem está em `ImageSurface.imageView`. Nenhuma branch de colega foi integrada.
- `GIFPreflight.inspect`, scanner Rust e ABI permaneceram intactos. Sem WebKit, lógica de drop ou geração de miniaturas da biblioteca.
- Após os commits e com builds concluídos, a limpeza final é `sh scripts/clean-builds.sh --all`, restrita a este worktree e preservando `dist/`.

## Correção após SECURITY-MEMORY-2 e VISUAL-PERF-3

Os dois pareceres REQUEST_CHANGES sobre `200e264921d78ffd5a66b12ef212c05615e4276a` foram lidos integralmente. O limite anterior podia solicitar 6000×60000 pixels (1,44 GB em RGBA8) ou 60000×2000 (480 MB), calculados sem alocar bitmaps.

A correção calcula o limite antes de chamar ImageIO, em fit e fill: até 128 MiB por bitmap estimado com 16 bytes/pixel e alinhamento de linha de 64 bytes, e lado máximo de 16.384 pixels. Busca binária encontra o maior tamanho que cabe, preservando o tamanho Retina solicitado quando está dentro do orçamento. Dimensões são limitadas ainda em ponto flutuante antes da conversão para Int; valores inválidos não causam overflow. O ImageIO recebe `ShouldAllowFloat = false`, e o layout real retornado é verificado por `bytesPerRow <= budget / height`, sem multiplicação que possa transbordar. Uma saída fora do contrato causa erro visível, sem ser retida no NSImage.

Fallback: para fotos extremas, o bitmap menor é ampliado proporcionalmente no mesmo recorte central. A nitidez pode cair; a explicação junto ao seletor informa a redução de resolução para limitar memória. Nenhuma tentativa de decodificar a origem inteira para obter nitidez perfeita. Vídeo/GIF e persistência não mudaram.

Novos testes são apenas aritméticos: fixtures exatas 6000×60000/6000×4000 e 60000×2000/3840×2160, transposição, aspectos de 1:1 bilhão e inverso, limite exato/primeiro tamanho que excede o teto, NaN/infinito/zero/negativo, dimensão finita máxima e 4K Retina preservado dentro do teto. Não alocam bitmaps gigantes.

Limitação mantida: orçamento por foto de saída, sem teto global de RSS ou de temporários internos de codecs; a chamada de decodificação permanece síncrona no MainActor, agora com dimensões solicitadas limitadas. Não há medição de pico de RAM ou latência nesta rodada. Revisões anteriores ficam inválidas após o novo commit; são necessárias três novas revisões independentes do novo HEAD, e merge por outro agente.

Checks locais da correção (2026-10-30):

- `CARGO_INCREMENTAL=0 sh scripts/build-native.sh`: aprovado, antes do Swift.
- `WALLMOTION_SNAPSHOT_PATH=/tmp/wallmotion-issue20-budget-library.png swift test -j 2`: 46 testes Swift Testing aprovados; 15 XCTest executados, 13 aprovados e 2 ignorados (rede opt-in e dois monitores). Snapshot da explicação de degradação inspecionado visualmente.
- `swift build -c release -j 2`: aprovado.
- `git diff --check`: aprovado. Rust tests/Clippy não repetidos nesta correção (scanner/ABI sem alterações); resultados anteriores ficam registrados acima. CI remoto permanece bloqueado por billing #11.

## Integração de origin/main — 2026-10-30

Merge normal de `origin/main` em `agents/sol-fit-fill`, base integrada `00afda7b892226ae5fa6bc3eefc88584fef47bd2` (inclui orçamento global GIF #14, pausa por oclusão #13 e scanner limitado #23). Conflitos resolvidos somente em `DesktopCoordinator.swift`, `docs/ARCHITECTURE.md` e `docs/QA.md`.

A resolução conserva `!force` na reutilização, orçamento GIF antes de criar o renderer, confirmação da cota somente depois de sucesso e preservação de renderer/cota anteriores em falhas. Acrescenta os critérios de modo/escala Retina à mesma condição, encaminhando o modo ao renderer. O observador de oclusão e o scanner/ABI integrados permanecem intactos. O teste de orçamento foi adaptado para `ImageSurface.imageView` e verifica trocar fit → fill no limite exato da cota sem cobrança duplicada.

Checks locais da árvore integrada: Rust estático via `CARGO_INCREMENTAL=0 sh scripts/build-native.sh`, 7 testes Rust e Clippy `-D warnings` aprovados; `swift test -j 2` aprovou 50 testes Swift Testing e 16 XCTest (19 executados, 3 ignorados: snapshot/rede opt-in e dois monitores); `swift build -c release -j 2` aprovado; sem conflitos pendentes e `git diff --cached --check` aprovado. CI remoto segue bloqueado por billing #11. Sem nova medição de memória/energia ou validação física em dois monitores. O merge invalida todas as aprovações de HEAD anteriores; requer três novas revisões independentes e merger separado.

## Integração do PR #39 — main 4cd97d1

Merge normal da main `4cd97d16562ad357b34cc440a660a2c3f5d2ebe5` na branch da issue #20, sem novas funcionalidades. A resolução mantém integralmente `RendererPlaybackState`, `applyPlaybackState`, decisão única de play/pause/animação, reamostragem da visibilidade, tokens de seek, rejeição de conclusões antigas/duplicadas, pausa durante seek e stop terminal do PR #39. O parâmetro `mediaFit` foi composto com as injeções de visibilidade/player/seek do inicializador. O coordenador encaminha tanto o modo quanto a visibilidade, sem substituir a política central.

Os testes de oclusão usam agora `ImageSurface.imageView`, preservando suas asserções; o teste de GIF coberto exercita Preencher, e o refresh do segundo display inclui Preencher sem retomar o GIF coberto do primeiro. Testes de seek do PR #39 permanecem integrais.

`docs/QA.md` foi restaurado byte a byte da main. O antigo `docs/QA-20.md` foi movido para este arquivo; roteiro manual, limites e histórico do recurso ficam em `docs/qa/media-fit.md`. A seção central de playback em `docs/ARCHITECTURE.md` foi mantida e os documentos de métricas/miniaturas/outros recursos não receberam edições próprias desta branch.

Checks desta integração: `CARGO_INCREMENTAL=0 sh scripts/build-native.sh` antes de Swift; 7 testes Rust e Clippy `--all-targets -- -D warnings` aprovados; `swift test -j 2` aprovou 56 testes Swift Testing e 23 XCTest (25 executados, 2 ignorados: snapshot/rede opt-in). Passaram os testes de GIF coberto, refresh de outro display sem retomar o coberto, seek remoto com player/seek injetados e stop terminal. O teste existente entre displays também passou nesta sessão; isso não substitui QA visual/manual em hardware. `git diff --exit-code origin/main -- docs/QA.md Sources/WallmotionCore/RendererPlaybackState.swift` confirmou ambos idênticos à main. Sem conflitos pendentes. CI remoto bloqueado por billing #11; novas aprovações de três sessões independentes são necessárias para o novo HEAD.

`swift build -c release -j 2` também passou na árvore composta com `4cd97d1`.
