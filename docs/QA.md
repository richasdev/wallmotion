# Validação do Wallmotion

## Automática

`sh scripts/check.sh` compila o núcleo Rust em release, executa seus testes e Clippy e roda as suítes Swift. Os testes AppKit criam imagens, GIFs e um vídeo H.264 sintéticos, verificam janelas desktop, ciclo de vida e pausa. São testes de integração locais, não uma certificação de compatibilidade visual com todas as versões do macOS.

A suíte do orçamento testa limites exatos, excesso de um byte, overflow, substituição por monitor e descarte de propostas. A integração AppKit testa rejeição antes de salvar, falha de persistência/decoder, refresh forçado, desconexão simulada, reconexão, remoção e stop com fixtures pequenas.

O runner sem display pode pular testes que precisam de `NSScreen`. O teste que troca conteúdo em outro monitor precisa de dois displays. Consulte o log para diferenciar aprovado de ignorado.

O teste de reprodução remota é opt-in, para que a suíte padrão não dependa de rede. Para executá-lo com o [exemplo HLS oficial da Apple](https://developer.apple.com/streaming/examples/advanced-stream-hevc.html):

```sh
WALLMOTION_REMOTE_TEST_URL=https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_adv_example_hevc/master.m3u8 swift test --filter testOptInRemoteStreamBecomesReadyAndAdvances
```

Esse teste passou localmente: estado pronto, tempo de reprodução avançando, áudio mudo e pausa/stop. Não verifica transmissão ao vivo nem reconexão.

## Roteiro manual antes de distribuir

- [ ] Abrir `dist/Wallmotion.app`; biblioteca vazia mostra ações claras.
- [ ] Importar JPEG/HEIC e verificar orientação e nitidez em Retina.
- [ ] Importar GIF animado; pausar/retomar e verificar os frames.
- [ ] Importar MP4/MOV com áudio; verificar loop contínuo e silêncio.
- [ ] Adicionar URL HTTPS de MP4 e HLS; reproduzir, interromper rede e tentar novamente.
- [ ] Rejeitar HTTP, páginas web, arquivos não suportados e GIF acima do orçamento.
- [ ] Aplicar GIFs até 512 MiB estimados entre monitores (máximo de 256 MiB por arquivo); rejeitar a seleção seguinte com erro visível e manter seleção persistida e wallpapers anteriores. Contar o mesmo GIF em cada monitor, inclusive pausado.
- [ ] Trocar/remover GIF, desconectar/reconectar monitor e reiniciar; confirmar liberação/revalidação da cota e preservação dos demais monitores.
- [ ] Aplicar uma mídia em cada monitor; mover/redimensionar/desconectar/reconectar telas.
- [ ] Clicar, selecionar retângulo e arrastar arquivos no Finder sobre o fundo.
- [ ] Alternar Spaces, Mission Control, Stage Manager e apps fullscreen.
- [ ] Pausar manualmente; bloquear, dormir e acordar. Manter pausa manual.
- [ ] Ativar modo de baixo consumo com preferência ligada/desligada.
- [ ] Cobrir completamente um GIF/vídeo e retomar pausa manual, wake ou baixo consumo; continuar sem reproduzir enquanto coberto. Trocar mídia em outro monitor deve preservar essa condição. Descobrir a janela deve respeitar a pausa manual.
- [ ] Durante o loop remoto, cobrir a janela/pausar/encerrar antes da conclusão do seek; não retomar o transporte após stop. Verificar Spaces/Stage Manager e medir CPU/GPU/energia separadamente em Instruments; os testes não certificam economia medida.
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

## Regressão de oclusão da issue #36

`RendererPlaybackStateTests` testa a tabela pausa/visibilidade/stop, retomadas enquanto coberto, seek pendente, falha, conclusão antiga/duplicada e stop terminal. Os testes AppKit injetam visibilidade e conclusões de seek, verificando `NSImageView.animates` e `AVPlayer.rate` com GIF e H.264 locais. O caminho remoto usa AVPlayer simples com fixture local e seek controlado, sem rede. Dois displays lógicos sobre uma tela física criam renderers independentes e comprovam que trocar o segundo preserva a pausa por oclusão do primeiro. O teste físico de dois monitores permanece separado e pode ser ignorado.

Essas verificações não comprovam cobertura real pelo WindowServer, compatibilidade com todos os Spaces/Stage Manager, streaming remoto nem redução medida de consumo; essas medições precisam de hardware e profiler.

Checks locais da correção em 2026-10-30: `CARGO_INCREMENTAL=0 sh scripts/build-native.sh`, `CARGO_INCREMENTAL=0 cargo test --locked --manifest-path crates/wallmotion-media/Cargo.toml --target-dir .build/native` (7 aprovados), Clippy no mesmo target com `--all-targets -- -D warnings` aprovado; `swift test -j 2` (46 testes core aprovados, 18 AppKit executados: 15 aprovados e 3 ignorados por snapshot/rede opt-in e segundo monitor físico indisponível), sem falhas ou avisos na execução final; `git diff --check` aprovado. CI remoto bloqueado por billing (#11).
