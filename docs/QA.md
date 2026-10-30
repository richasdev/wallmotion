# Validação do Wallmotion

## Automática

`sh scripts/check.sh` compila o núcleo Rust em release, executa seus testes e Clippy e roda as suítes Swift. Os testes AppKit criam imagens, GIFs e um vídeo H.264 sintéticos, verificam janelas desktop, ciclo de vida e pausa. São testes de integração locais, não uma certificação de compatibilidade visual com todas as versões do macOS.

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
- [ ] Aplicar uma mídia em cada monitor; mover/redimensionar/desconectar/reconectar telas.
- [ ] Clicar, selecionar retângulo e arrastar arquivos no Finder sobre o fundo.
- [ ] Alternar Spaces, Mission Control, Stage Manager e apps fullscreen.
- [ ] Pausar manualmente; bloquear, dormir e acordar. Manter pausa manual.
- [ ] Ativar modo de baixo consumo com preferência ligada/desligada.
- [ ] Fechar biblioteca, abrir pela barra de menu e encerrar o app.
- [ ] Reabrir e verificar seleção por monitor e preferências restauradas.
- [ ] Em Ajustes > Início da sessão, habilitar o início automático e confirmar o estado no macOS; se solicitado, aprovar em Ajustes do Sistema > Geral > Itens de Início. Desabilitar e confirmar a remoção.
- [ ] Corromper uma cópia da biblioteca de teste; erro deve preservar os bytes originais.
- [ ] Medir CPU/GPU/RAM/energia por 15 minutos com foto, GIF, vídeo e HLS; repetir pausado.

## Limites de compatibilidade

O modo de exibição inicial é proporcional, com possíveis faixas em mídias de outra proporção. As janelas participam dos Spaces normais; fullscreen e Stage Manager precisam de validação física. As notificações distribuídas de bloqueio são sinais de melhor esforço do macOS; eventos públicos de tela/repouso/sessão complementam a pausa. GIF tem orçamento conservador de 256 MiB de frames por mídia; isso não representa um teto garantido de RAM total do app.

Fotos são decodificadas com ImageIO para o tamanho do monitor. O app não publica metadados no Now Playing e configura `preventsDisplaySleepDuringVideoPlayback = false`. Isso deve ser verificado com `pmset -g assertions`, pois outros frameworks/apps podem manter o sistema acordado.

Build local usa assinatura ad-hoc de desenvolvimento e arquitetura do host. Distribuição pública requer Developer ID, notarização e teste de arquiteturas compatíveis. Não remova a quarentena global do macOS para testar.

## Início automático

O login item usa `SMAppService.mainApp` (macOS 13+, com deployment target macOS 14). O app não registra o serviço no lançamento: o cadastro ocorre apenas quando a pessoa ativa a opção em Ajustes. A interface reflete o status reportado pelo serviço e oferece um atalho para Ajustes do Sistema quando o macOS exige aprovação. Builds ad-hoc podem não ser aceitos ou persistidos pelo macOS como login item; valide o fluxo de aprovação e a persistência em um bundle assinado para distribuição. Os testes do controlador usam um serviço fake e não alteram os login items da máquina.
