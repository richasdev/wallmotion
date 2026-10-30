# QA de streaming remoto e recuperação — issue #21

Requer macOS 14+, Swift 6 e Rust estável. Execute `CARGO_INCREMENTAL=0 sh scripts/build-native.sh` antes de `swift test -j 2`. Rust usa `.build/native`; não executar builds simultâneos neste worktree.

HLS opt-in:

```sh
WALLMOTION_REMOTE_TEST_URL=https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_adv_example_hevc/master.m3u8 swift test -j 2 --filter testOptInRemoteStreamBecomesReadyAndAdvances
```

## Cobertura e validação original

Esse teste passou localmente na implementação da issue #21: estado pronto/reproduzindo observável, tempo avançando, áudio mudo e pausa/stop. Não verifica transmissão ao vivo nem reconexão real.

A suíte padrão inclui `RemotePlaybackRecoveryTests`, com scheduler manual (sem esperas reais/rede), verificando estados, backoff 2/4/8 s, três tentativas, deadline final, rede offline/online, orçamento preservado após sucesso, falha terminal e callbacks cancelados após pausa/stop. Fixtures H.264 locais exercitam o adaptador remoto real, notificações de stall/falha transitória, substituição de item, descarte de eventos antigos, repetição finita, pausa durante seek e liberação do item em erro/stop. Elas não simulam o transporte HTTP do AVFoundation.

Validação local da issue #21 (macOS arm64, Swift 6; CI remoto bloqueado por billing, #11):

- Build Rust release, 6 testes Rust e Clippy com `-D warnings`: passaram nas fases Rust de `CARGO_INCREMENTAL=0 sh scripts/check.sh`, usando `.build/native`. A execução Swift desse script foi interrompida ao receber o limite de concorrência; os checks Swift seguintes usam `-j 2`.
- `swift test -j 2`: suíte Swift padrão passou; HLS e snapshot são opt-in e o teste de dois monitores é ignorado quando há somente um display.
- `WALLMOTION_REMOTE_TEST_URL=https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_adv_example_hevc/master.m3u8 swift test -j 2 --filter testOptInRemoteStreamBecomesReadyAndAdvances`: passou.
- Rodada final combinada com `WALLMOTION_REMOTE_TEST_URL` acima e `WALLMOTION_SNAPSHOT_PATH=/tmp/wallmotion-issue21-library.png swift test -j 2`: 23 testes XCTest (22 passaram, somente o de dois monitores ignorado) e 36 testes Swift Testing passaram. Snapshot da biblioteca gerado e inspecionado; não exercita os novos estados de erro na UI.

Limitações: interrupção real de rede, sleep/wake físico, expiração de URL em servidor real e CPU/GPU/RAM/energia prolongados ainda requerem QA manual. O teste determinístico cobre a política de recuperação; não há alegação de melhoria de performance medida.

## Roteiro específico

- [ ] Adicionar URL HTTPS de MP4 e HLS; observar carregando/reproduzindo/buffering; interromper/restaurar rede e verificar teto de três recargas por sessão.
- [ ] Pausar manualmente ou dormir durante backoff/seek; confirmar que callbacks atrasados não retomam. Acordar com pausa manual deve manter a pausa.
- [ ] Usar URL expirada/HTTP 403 e formato inválido; confirmar erro claro, ausência de retries automáticos e tentativa manual somente no monitor selecionado (respeitando pausa).
- [ ] Remover mídia/desconectar monitor/encerrar durante recuperação; confirmar liberação de player, observers e monitor de conectividade.

## Atualização de integração da issue #21

Após merge normal de `origin/main` em `00afda7` na branch da issue #21:

- Preservados orçamento global de GIFs (#14), scanner limitado (#23) e observação de oclusão (#13). Retry por monitor agora pede substituição transacional; falha de validação/decoder mantém renderer e cota anteriores. Oclusão usa a pausa efetiva do adaptador remoto para cancelar recuperação, mantendo a pausa manual ao voltar a ficar visível.
- `CARGO_INCREMENTAL=0 sh scripts/build-native.sh`: aprovado antes do Swift. Fases Rust de `scripts/check.sh`: 7 testes e Clippy `-D warnings` aprovados. A etapa Swift sem limite desse script foi interrompida; a validação foi executada diretamente com `-j 2`.
- `swift test -j 2`: aprovado. Rodada final com `WALLMOTION_REMOTE_TEST_URL=https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_adv_example_hevc/master.m3u8 swift test -j 2`: 28 XCTest (26 passaram, 2 ignorados: snapshot opt-in e segundo monitor), 40 testes Swift Testing aprovados. HLS real inclui pausa por oclusão e preservação da pausa manual ao reaparecer. Regressão de GIF inclui retry rejeitado preservando janela/cota.
- `git diff --cached --check`: aprovado. CI remoto segue bloqueado por billing (#11); medições prolongadas e sleep/rede físicos permanecem pendentes.

## Composição com PR #39 e main em 641e49d

O adaptador remoto delega recargas ao `applyPlaybackState` do renderer e fim de item ao `restartRemotePlayback`; não chama play/pause/seek diretamente. A política central `RendererPlaybackState`, a amostragem atual de visibilidade, a coalescência e os tokens de seek do #39 foram preservados. Um teste adicional injeta scheduler e visibilidade para comprovar que uma recarga não retoma um renderer recém-coberto, mesmo sem notificação de oclusão. Falhas de substituição continuam preservando janela/cota de GIF. Imports concorrentes, drag-and-drop e thumbnails de main não foram alterados.

- `CARGO_INCREMENTAL=0 sh scripts/build-native.sh` aprovado antes de Swift.
- `CARGO_INCREMENTAL=0 cargo test --locked --manifest-path crates/wallmotion-media/Cargo.toml --target-dir .build/native`: 7 aprovados. Clippy no mesmo target com `--all-targets -- -D warnings`: aprovado.
- `swift test -j 2`: 36 XCTest executados, 34 aprovados/2 ignorados por HLS e snapshot opt-in; 46 testes Swift Testing aprovados.
- Rodada final com URL HLS Apple acima e `WALLMOTION_SNAPSHOT_PATH=/tmp/wallmotion-issue21-main39-library.png swift test -j 2`: 36 XCTest e 46 Swift Testing aprovados, zero falhas/ignorados. HLS usa transporte real e visibilidade injetável; snapshot gerado e inspecionado.
- A fixture isolada do adaptador foi ajustada para deixar transporte com seu chamador, e o HLS deixou de fixar visibilidade em true para poder simular oclusão. As falhas intermediárias dessas fixtures foram corrigidas antes da rodada final.

`docs/QA.md` permanece byte a byte conforme main. Os resultados históricos acima foram movidos para este arquivo sem remover instruções/limites do recurso. CI continua bloqueado por billing (#11); oclusão física/WindowServer, sleep/rede físicos, expiração real de URL e memória/energia prolongados ainda requerem QA manual. Recarga reinicia a origem, sem promessa de performance medida.
