# Fontes web oficiais (#15)

O seletor “Fonte web (YouTube ou Vimeo)” cria `MediaSource.web(embed:)`. O modo padrão continua aceitando somente vídeo direto/HLS pelo AVFoundation. Não há conexão durante inclusão nem ao restaurar uma seleção pausada.

## Contrato e persistência

- YouTube: HTTPS de vídeo individual `watch?v=`, `youtu.be/ID`, `shorts/ID`, `live/ID` ou `embed/ID`; ID ASCII de 11 caracteres. Usa youtube-nocookie.com; isso não elimina contato com o provedor nem garante ausência de rastreamento.
- Vimeo: `vimeo.com/ID`, `vimeo.com/ID/HASH` e `player.vimeo.com/video/ID?h=HASH`. Preserva hash de vídeo não listado, sem login/senha. IDs numéricos positivos; hash alfanumérico até 64 caracteres.
- Hosts/rotas explícitos, HTTPS, sem credenciais ou porta não padrão. Ignora tracking, timestamp e playlist de links de vídeo; links somente de playlist são rejeitados. Não repassa flags arbitrárias ao player.
- Estado v1 migra em memória para v2; bytes originais só mudam ao salvar uma edição. Preserva IDs, datas, seleções, preferências, arquivos e URLs assinadas. Estado inválido causa erro sem sobrescrever a biblioteca. Builds antigos não abrem v2.

## Renderização e segurança

`WallpaperRenderer` delega fontes web para `WebWallpaperRenderer`. O player oficial preserva a proporção do vídeo, sem esticar, recortar ou cobrir marca/controles com overlays. Resolução entregue e adaptação Retina dependem do player/rede; não há promessa de 4K.

WKWebView usa armazenamento não persistente, autoplay sem gesto no WebKit, fullscreen desabilitado e CSP permitindo scripts/frames oficiais. Sem login, popups ou navegação externa. O delegate permite somente a primeira navegação do wrapper no frame principal e frames HTTPS dos players oficiais. Mensagens só são aceitas do wrapper principal e da view atual; o handler tem referência fraca ao renderer.

Origem/referrer usam `https://<bundle-id>` via `loadHTMLString(_:baseURL:)`, conforme orientação oficial para macOS. Em `swift run` sem bundle usa `dev.richas.wallmotion`, do manifesto. Envia `origin` ao YouTube e usa política `strict-origin-when-cross-origin`.

YouTube chama `mute()` antes de `playVideo()` em ready e faz loop com playlist do próprio vídeo. Não depende de parâmetro mute não documentado. Vimeo usa `autoplay=1`, `muted=1`, `loop=1`, `autopause=0`, `dnt=1`, além de `setMuted(true)` antes de `play()` no SDK. Não depende de background=1, que pode exigir plano do proprietário.

Erros YouTube (inclusive 100/101/150/153), autoplay bloqueado, rejeições/eventos Vimeo, falhas de navegação e término do processo WebKit geram erro por monitor. Prazo único de 30 segundos trata ausência de confirmação playing; sem polling/retry automático.

Pausa chama `setAllMediaPlaybackSuspended(true)` e `pauseAllMediaPlayback`, interrompe carregamento, remove delegate/handler, remove a view da hierarquia e libera a referência. Retomar reinicia o vídeo. Stop é terminal/idempotente. A janela permanece preta enquanto pausada. WebKit pode reter processos auxiliares por política do sistema; não se garante término imediato nem teto medido de RAM.

## Limites e QA

Sem páginas arbitrárias, playlists, streams extraídos, DRM, login, senha ou contorno de restrições por domínio, idade ou região. ID válido não garante embed/autoplay. Falhas aparecem na biblioteca com recarga manual. Não há certificação de uso contínuo, energia, múltiplos monitores ou oclusão; requisitos de visibilidade/autoplay do provedor precisam ser respeitados na homologação antes de distribuir.

A suíte padrão é offline. `WebEmbedTests` cobre normalização, entradas hostis, hash Vimeo e migração v1 literal. `WebWallpaperRendererTests` cobre criação preguiçosa, pausa/descarte, retomada, stop terminal e erro 153 com documento local real no WebKit.

Teste real opt-in (após `CARGO_INCREMENTAL=0 sh scripts/build-native.sh`):

```sh
WALLMOTION_WEB_TEST_URL='https://www.youtube.com/watch?v=M7lc1UVf-VE' swift test -j 2 --filter testOptInOfficialEmbed
WALLMOTION_WEB_TEST_URL='https://vimeo.com/76979871' swift test -j 2 --filter testOptInOfficialEmbed
```

Exige playing oficial, verifica mudo via API e descarte. Pode falhar por restrições de vídeo/rede/autoplay; isso não autoriza bypass. Verificar manualmente silêncio, proporção Retina, retorno de energia/memória e ausência de assertions de repouso no host.

## Documentação primária consultada em 2026-10-30

- [YouTube identidade/referrer e autoplay](https://developers.google.com/youtube/terms/required-minimum-functionality)
- [YouTube IFrame API: mute, eventos e erros](https://developers.google.com/youtube/iframe_api_reference)
- [YouTube parâmetros e loop](https://developers.google.com/youtube/player_parameters)
- [Vimeo SDK, métodos e eventos](https://github.com/vimeo/player.js)
- [Vimeo opções de embed](https://developer.vimeo.com/player/sdk/embed)
- [Vimeo autoplay e mute](https://help.vimeo.com/hc/en-us/articles/29677068222737-Troubleshooting-Autoplay-restrictions)
- [Apple WKWebView](https://developer.apple.com/documentation/webkit/wkwebview)

`docs/NEXT-PHASE.md` foi lido como proposta anterior. Não havia relatório YouTube separado neste checkout. A proposta não certifica reprodução real.

## Registro local desta implementação

Em 2026-10-30, neste worktree `agents/sol-web`:

- `CARGO_INCREMENTAL=0 sh scripts/check.sh`: build estático release concluído, 6 testes Rust aprovados e Clippy sem warnings. A primeira compilação Swift falhou em testes novos; foi corrigida e validada separadamente com o limite de jobs solicitado abaixo.
- `swift test -j 2`: aprovado, 41 testes Swift Testing e 17 XCTest, sendo 4 skips explícitos (snapshot opcional, HLS opt-in, segundo monitor e embed opt-in). Sem warnings na rodada final.
- YouTube `M7lc1UVf-VE`: teste opt-in aprovado duas vezes após correções; rodada final em 1,70 s confirmou playing, mudo pela API e descarte em pausa/stop. Snapshot da view inspecionado: player oficial proporcional, sem recorte adicionado pelo Wallmotion. Para exportar novamente, definir também `WALLMOTION_WEB_SNAPSHOT_PATH=/tmp/wallmotion-web.png`.
- Vimeo `76979871` (com/sem hash de exemplo do SDK): teste opt-in falhou com `PlaybackError`; `59777392` retornou `PrivacyError: The video is private.`. SDK carregou e o app apresentou os erros/descarte. Reprodução Vimeo permanece não certificada neste host; não se atribui causa exclusiva à rede ou ao provedor.
- `git diff --check`: aprovado.

CI remoto segue bloqueado por billing (#11). Não foram medidos consumo sustentado de CPU/GPU/RAM/energia, comportamento prolongado de oclusão, macOS 14 físico ou múltiplos monitores. Esses limites precisam permanecer no PR draft e na revisão de integração.
