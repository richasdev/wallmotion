# Validação do Wallmotion

## Automática

`sh scripts/check.sh` compila o núcleo Rust em release, executa seus testes e Clippy e roda as suítes Swift. Os testes AppKit criam imagens, GIFs e um vídeo H.264 sintéticos, verificam janelas desktop, ciclo de vida e pausa. São testes de integração locais, não uma certificação de compatibilidade visual com todas as versões do macOS.

O runner sem display pode pular testes que precisam de `NSScreen`. O teste que troca conteúdo em outro monitor precisa de dois displays. Consulte o log para diferenciar aprovado de ignorado.

O teste de reprodução remota é opt-in, para que a suíte padrão não dependa de rede. Para executá-lo com o [exemplo HLS oficial da Apple](https://developer.apple.com/streaming/examples/advanced-stream-hevc.html):

```sh
WALLMOTION_REMOTE_TEST_URL=https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_adv_example_hevc/master.m3u8 swift test --filter testOptInRemoteStreamBecomesReadyAndAdvances
```

Esse teste passou localmente na implementação da issue #21: estado pronto/reproduzindo observável, tempo avançando, áudio mudo e pausa/stop. Não verifica transmissão ao vivo nem reconexão real.

A suíte padrão inclui `RemotePlaybackRecoveryTests`, com scheduler manual (sem esperas reais/rede), verificando estados, backoff 2/4/8 s, três tentativas, deadline final, rede offline/online, orçamento preservado após sucesso, falha terminal e callbacks cancelados após pausa/stop. Fixtures H.264 locais exercitam o adaptador remoto real, notificações de stall/falha transitória, substituição de item, descarte de eventos antigos, repetição finita, pausa durante seek e liberação do item em erro/stop. Elas não simulam o transporte HTTP do AVFoundation.

Validação local da issue #21 (macOS arm64, Swift 6; CI remoto bloqueado por billing, #11):

- Build Rust release, 6 testes Rust e Clippy com `-D warnings`: passaram nas fases Rust de `CARGO_INCREMENTAL=0 sh scripts/check.sh`, usando `.build/native`. A execução Swift desse script foi interrompida ao receber o limite de concorrência; os checks Swift seguintes usam `-j 2`.
- `swift test -j 2`: suíte Swift padrão passou; HLS e snapshot são opt-in e o teste de dois monitores é ignorado quando há somente um display.
- `WALLMOTION_REMOTE_TEST_URL=https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_adv_example_hevc/master.m3u8 swift test -j 2 --filter testOptInRemoteStreamBecomesReadyAndAdvances`: passou.
- Rodada final combinada com `WALLMOTION_REMOTE_TEST_URL` acima e `WALLMOTION_SNAPSHOT_PATH=/tmp/wallmotion-issue21-library.png swift test -j 2`: 23 testes XCTest (22 passaram, somente o de dois monitores ignorado) e 36 testes Swift Testing passaram. Snapshot da biblioteca gerado e inspecionado; não exercita os novos estados de erro na UI.

Limitações: interrupção real de rede, sleep/wake físico, expiração de URL em servidor real e CPU/GPU/RAM/energia prolongados ainda requerem QA manual. O teste determinístico cobre a política de recuperação; não há alegação de melhoria de performance medida.

## Roteiro manual antes de distribuir

- [ ] Abrir `dist/Wallmotion.app`; biblioteca vazia mostra ações claras.
- [ ] Importar JPEG/HEIC e verificar orientação e nitidez em Retina.
- [ ] Importar GIF animado; pausar/retomar e verificar os frames.
- [ ] Importar MP4/MOV com áudio; verificar loop contínuo e silêncio.
- [ ] Adicionar URL HTTPS de MP4 e HLS; observar carregando/reproduzindo/buffering; interromper/restaurar rede e verificar teto de três recargas por sessão.
- [ ] Pausar manualmente ou dormir durante backoff/seek; confirmar que callbacks atrasados não retomam. Acordar com pausa manual deve manter a pausa.
- [ ] Usar URL expirada/HTTP 403 e formato inválido; confirmar erro claro, ausência de retries automáticos e tentativa manual somente no monitor selecionado (respeitando pausa).
- [ ] Remover mídia/desconectar monitor/encerrar durante recuperação; confirmar liberação de player, observers e monitor de conectividade.
- [ ] Rejeitar HTTP, páginas web, arquivos não suportados e GIF acima do orçamento.
- [ ] Aplicar uma mídia em cada monitor; mover/redimensionar/desconectar/reconectar telas.
- [ ] Clicar, selecionar retângulo e arrastar arquivos no Finder sobre o fundo.
- [ ] Alternar Spaces, Mission Control, Stage Manager e apps fullscreen.
- [ ] Pausar manualmente; bloquear, dormir e acordar. Manter pausa manual.
- [ ] Ativar modo de baixo consumo com preferência ligada/desligada.
- [ ] Fechar biblioteca, abrir pela barra de menu e encerrar o app.
- [ ] Reabrir e verificar seleção por monitor e preferências restauradas.
- [ ] Corromper uma cópia da biblioteca de teste; erro deve preservar os bytes originais.
- [ ] Medir CPU/GPU/RAM/energia por 15 minutos com foto, GIF, vídeo e HLS; repetir pausado.

## Limites de compatibilidade

O modo de exibição inicial é proporcional, com possíveis faixas em mídias de outra proporção. As janelas participam dos Spaces normais; fullscreen e Stage Manager precisam de validação física. As notificações distribuídas de bloqueio são sinais de melhor esforço do macOS; eventos públicos de tela/repouso/sessão complementam a pausa. GIF tem orçamento conservador de 256 MiB de frames por mídia; isso não representa um teto garantido de RAM total do app.

Fotos são decodificadas com ImageIO para o tamanho do monitor. O app não publica metadados no Now Playing e configura `preventsDisplaySleepDuringVideoPlayback = false`. Isso deve ser verificado com `pmset -g assertions`, pois outros frameworks/apps podem manter o sistema acordado.

Build local usa assinatura ad-hoc de desenvolvimento e arquitetura do host. Distribuição pública requer Developer ID, notarização e teste de arquiteturas compatíveis. Não remova a quarentena global do macOS para testar.
