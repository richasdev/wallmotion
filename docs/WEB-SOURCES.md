# Fontes web oficiais (#15)

O seletor “Fonte web (YouTube ou Vimeo)” cria `MediaSource.web(embed:)`. O modo padrão continua aceitando somente vídeo direto/HLS pelo AVFoundation. Não há conexão durante inclusão nem ao restaurar uma seleção pausada.

## Contrato e persistência

- YouTube: HTTPS de vídeo individual `watch?v=`, `youtu.be/ID`, `shorts/ID`, `live/ID` ou `embed/ID`; ID ASCII de 11 caracteres. Usa youtube-nocookie.com; isso não elimina contato com o provedor nem garante ausência de rastreamento.
- Vimeo: `vimeo.com/ID`, `vimeo.com/ID/HASH` e `player.vimeo.com/video/ID?h=HASH`. Preserva hash de vídeo não listado, sem login/senha. IDs numéricos positivos; hash alfanumérico até 64 caracteres.
- Hosts/rotas explícitos, HTTPS, sem credenciais ou porta não padrão. Ignora tracking, timestamp e playlist de links de vídeo; links somente de playlist são rejeitados. Não repassa flags arbitrárias ao player.
- Novas URLs diretas passam pela validação estrita de `MediaURL.validate`/`Wallpaper.remote`, que exige adicionar youtube-nocookie.com explicitamente como fonte web. Fontes remotas persistidas usam o contrato anterior em load/save/resolução, inclusive após migrar para v2. Assim, uma URL youtube-nocookie.com aceita na v1 continua `.remote`, sem conversão automática para WebKit; isso não garante que AVFoundation reproduza uma página de embed.
- Estado v1 migra em memória para v2; bytes originais só mudam ao salvar uma edição. Preserva IDs, datas, seleções, preferências, arquivos e URLs assinadas. Estado inválido causa erro sem sobrescrever a biblioteca. Builds antigos não abrem v2.

## Renderização e segurança

`WallpaperRenderer` delega fontes web para `WebWallpaperRenderer`. O player oficial preserva a proporção do vídeo, sem esticar, recortar ou cobrir marca/controles com overlays. Resolução entregue e adaptação Retina dependem do player/rede; não há promessa de 4K.

WKWebView usa armazenamento não persistente, autoplay sem gesto no WebKit, fullscreen desabilitado e CSP permitindo scripts/frames oficiais. Sem login, popups ou navegação externa. O delegate permite somente a primeira navegação do wrapper no frame principal e frames HTTPS dos players oficiais. Mensagens só são aceitas do wrapper principal e da view atual; o handler tem referência fraca ao renderer.

Origem/referrer usam `https://<bundle-id>` via `loadHTMLString(_:baseURL:)`, conforme orientação oficial para macOS. Em `swift run` sem bundle usa `dev.richas.wallmotion`, do manifesto. Envia `origin` ao YouTube e usa política `strict-origin-when-cross-origin`.

YouTube chama `mute()` antes de `playVideo()` em ready e faz loop com playlist do próprio vídeo. Não depende de parâmetro mute não documentado. Vimeo usa `autoplay=1`, `muted=1`, `loop=1`, `autopause=0`, `dnt=1`, além de `setMuted(true)` antes de `play()` no SDK. Não depende de background=1, que pode exigir plano do proprietário.

Erros YouTube (inclusive 100/101/150/153), autoplay bloqueado, rejeições/eventos Vimeo, falhas de navegação e término do processo WebKit geram erro por monitor. Prazo único de 30 segundos trata ausência de confirmação playing; sem polling/retry automático.

A decisão central `RendererPlaybackState.shouldPlay`, aplicada por `WallpaperRenderer.applyPlaybackState`, combina intenção de pausa, visibilidade atual e stop. Enquanto coberta, a fonte não aloca WKWebView nem carrega o embed, inclusive em retomada manual/política e rebuild.

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

### Correção da compatibilidade legada solicitada no review

O [BUG-HUNTER-1](https://github.com/richasdev/wallmotion/pull/35#issuecomment-6523112512) identificou que ampliar o bloqueio de novas URLs também invalidava bibliotecas v1 antes aceitas. O validador de fontes persistidas agora preserva o contrato anterior em load, save e resolução, mesmo em v2. O fluxo de inclusão continua estrito. Não há reclassificação automática das fontes antigas.

O fixture JSON v1 literal com `https://www.youtube-nocookie.com/embed/M7lc1UVf-VE`, foto local e seleções cobre preservação integral, ausência de escrita no load, manutenção de `.remote` e round-trip após editar/salvar em v2. Testes adicionais confirmam rejeição da nova entrada direta e de URLs persistidas que já eram inválidas (HTTP, credenciais, hosts anteriormente bloqueados e HTML).

Checks desta correção: `CARGO_INCREMENTAL=0 sh scripts/build-native.sh` aprovado; `swift test -j 2` aprovado (44 Swift Testing, 17 XCTest, 4 skips explícitos, sem warnings); `git diff --check` aprovado. Rust tests/Clippy não foram repetidos, pois não há alteração Rust/ABI. Nenhum teste de rede foi executado nesta revisão. Fixtures de persistência/JS/WebKit não certificam reprodução real YouTube/Vimeo. CI continua bloqueado por billing #11. O novo commit invalida os pareceres anteriores; são necessários três novos pareceres no mesmo HEAD antes de integração por outro agente.

### Integração de origin/main no PR #35

Merge normal de `origin/main` em `agents/sol-web`, preservando scanner Rust/ABI com orçamento durante scan (#23), cota global de GIF por monitor (#14), observador de oclusão (#13) e política de três revisores/merger separado (#30). O conflito textual em `docs/QA.md` foi resolvido mantendo os roteiros de fontes web e orçamento GIF.

A integração mínima conecta a WKWebView ao observador de oclusão já integrado: ao ocultar, suspende e descarta a view; ao voltar visível, recria somente se não houver pausa manual/política. Fixture HTML local injetada no renderer permite testar essa integração sem acessar rede. Não há reestruturação da política nativa de vídeo/GIF. A regressão de URL legada continua coberta pelo fixture literal v1 e round-trip v2.

Checks após o merge: build Rust estático release com `CARGO_INCREMENTAL=0 sh scripts/build-native.sh`; `cargo test --locked --manifest-path crates/wallmotion-media/Cargo.toml --target-dir .build/native` (7 aprovados); Clippy `--all-targets -- -D warnings` aprovado; `swift test -j 2` (48 Swift Testing e 22 XCTest, 4 skips explícitos, sem warnings); diff staged sem erros ou marcadores de conflito. Rust usa `.build/native` e `CARGO_INCREMENTAL=0`.

Nenhuma reprodução real de YouTube/Vimeo ou medição de energia foi repetida nesta integração. Fixtures offline e notificações de oclusão não certificam autoplay dos provedores nem oclusão física em todos os desktops/Spaces. CI segue bloqueado por billing #11. O novo HEAD exige três pareceres novos antes do merge por outro agente.

### Correção de retomada web enquanto coberta (SECURITY-MEMORY-2)

Após integrar o PR #39 de main, a fonte web passou a consumir `RendererPlaybackState.shouldPlay` exclusivamente em `applyPlaybackState`. Cada pedido de pausa/retomada, rebuild e notificação consulta a visibilidade atual. Não há chamada de retomada web incondicional que recrie o player por trás de outra janela. O teardown terminal continua em stop; não foram alterados parser, migração legada ou SDKs dos provedores.

Regressões offline com visibilidade injetada verificam: início coberto; descarte ao cobrir; `setPaused(false)` e sequência manual/repouso/baixo consumo sem nova notificação enquanto coberto; rebuild preservado e forçado; mudança de visibilidade sem evento seguida de rebuild; retomada somente visível; pausa manual mesmo ao tornar visível; stop terminal. O teste de coordenador roda para YouTube e Vimeo com HTML local sem recursos remotos, verificando ausência de WKWebView na superfície enquanto coberta. O documento local é injetado apenas nos testes; produção mantém os embeds oficiais.

Checks: build estático release antes do Swift com `CARGO_INCREMENTAL=0`; `swift test -j 2` aprovado (54 Swift Testing, 29 XCTest, 4 skips explícitos, sem warnings). Fixtures não certificam reprodução real nem oclusão física por WindowServer/Spaces; nenhum teste de rede ou benchmark foi repetido. CI bloqueado por billing #11. Novo HEAD requer três pareceres novos independentes; integração por outro agente.
