# Validação do Wallmotion

## Automática

`sh scripts/check.sh` compila o núcleo Rust em release, executa seus testes e Clippy e roda as suítes Swift. Os testes AppKit criam imagens, GIFs e um vídeo H.264 sintéticos, verificam janelas desktop, ciclo de vida e pausa. São testes de integração locais, não uma certificação de compatibilidade visual com todas as versões do macOS.

A suíte do orçamento testa limites exatos, excesso de um byte, overflow, substituição por monitor e descarte de propostas. A integração AppKit testa rejeição antes de salvar, falha de persistência/decoder, refresh forçado, desconexão simulada, reconexão, remoção e stop com fixtures pequenas.

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
- [ ] Aplicar GIFs até 512 MiB estimados entre monitores (máximo de 256 MiB por arquivo); rejeitar a seleção seguinte com erro visível e manter seleção persistida e wallpapers anteriores. Contar o mesmo GIF em cada monitor, inclusive pausado.
- [ ] Trocar/remover GIF, desconectar/reconectar monitor e reiniciar; confirmar liberação/revalidação da cota e preservação dos demais monitores.
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

O modo de exibição inicial é proporcional, com possíveis faixas em mídias de outra proporção. As janelas participam dos Spaces normais; fullscreen e Stage Manager precisam de validação física. As notificações distribuídas de bloqueio são sinais de melhor esforço do macOS; eventos públicos de tela/repouso/sessão complementam a pausa. GIF tem orçamento conservador de 256 MiB de frames por mídia e 512 MiB somando as views dos monitores conectados, inclusive pausadas; isso não representa um teto garantido de RAM total do app.

Fotos são decodificadas com ImageIO para o tamanho do monitor. O app não publica metadados no Now Playing e configura `preventsDisplaySleepDuringVideoPlayback = false`. Isso deve ser verificado com `pmset -g assertions`, pois outros frameworks/apps podem manter o sistema acordado.

Build local usa assinatura ad-hoc de desenvolvimento e arquitetura do host. Distribuição pública requer Developer ID, notarização e teste de arquiteturas compatíveis. Não remova a quarentena global do macOS para testar.

## Validação local da issue #14 (2026-10-30)

- `CARGO_INCREMENTAL=0 sh scripts/check.sh`: build Rust release antes do Swift, 6 testes Rust e Clippy com `-D warnings` aprovados; Rust em `.build/native`.
- Execução final `swift test -j 2`: 40 testes do núcleo aprovados; 15 testes AppKit, sendo 12 aprovados e 3 ignorados (snapshot opt-in, stream remoto opt-in e segundo monitor indisponível). Sem falhas ou avisos de compilação na execução final.
- `git diff --check`: aprovado. CI remoto bloqueado por billing (#11); estes resultados são locais.
- Desconexão/reconexão foi simulada no coordenador; QA físico com dois monitores e medição de RSS/energia continuam pendentes. O teto estima frames, não a memória residente total nem o pico temporário da troca.

## Atualização de integração da issue #21

Após merge normal de `origin/main` em `00afda7` na branch da issue #21:

- Preservados orçamento global de GIFs (#14), scanner limitado (#23) e observação de oclusão (#13). Retry por monitor agora pede substituição transacional; falha de validação/decoder mantém renderer e cota anteriores. Oclusão usa a pausa efetiva do adaptador remoto para cancelar recuperação, mantendo a pausa manual ao voltar a ficar visível.
- `CARGO_INCREMENTAL=0 sh scripts/build-native.sh`: aprovado antes do Swift. Fases Rust de `scripts/check.sh`: 7 testes e Clippy `-D warnings` aprovados. A etapa Swift sem limite desse script foi interrompida; a validação foi executada diretamente com `-j 2`.
- `swift test -j 2`: aprovado. Rodada final com `WALLMOTION_REMOTE_TEST_URL=https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_adv_example_hevc/master.m3u8 swift test -j 2`: 28 XCTest (26 passaram, 2 ignorados: snapshot opt-in e segundo monitor), 40 testes Swift Testing aprovados. HLS real inclui pausa por oclusão e preservação da pausa manual ao reaparecer. Regressão de GIF inclui retry rejeitado preservando janela/cota.
- `git diff --cached --check`: aprovado. CI remoto segue bloqueado por billing (#11); medições prolongadas e sleep/rede físicos permanecem pendentes.
