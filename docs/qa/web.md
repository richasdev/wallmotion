# QA de fontes web (#15)

Complementa o roteiro geral em [QA.md](../QA.md). Contrato, segurança, resultados e testes opt-in em [WEB-SOURCES.md](../WEB-SOURCES.md).

A suíte padrão é offline. Fixtures de persistência/JS/WebKit verificam normalização, compatibilidade legada, ciclo de vida e propagação de erro; não certificam reprodução real dos provedores. O teste opt-in exige playing oficial e mudo pela API.

- [ ] Adicionar YouTube/Vimeo explicitamente como fonte web, mantendo vídeos diretos no modo padrão.
- [ ] Verificar proporção em Retina, silêncio e apresentação de erro por monitor.
- [ ] Cobrir a janela e confirmar descarte da WKWebView; retomar manualmente ou por política e reconstruir ainda coberta sem recriar o embed. Tornar visível e confirmar retomada, respeitando pausa manual.
- [ ] Pausar/parar e verificar descarte; recarregar manualmente após erro do provedor.
- [ ] Verificar biblioteca legada v1 com URL youtube-nocookie: permanece remote, sem reclassificação, com fotos e seleções preservadas. Novas entradas diretas desse host devem pedir fonte web explícita.
- [ ] Rejeitar HTTP, credenciais, páginas arbitrárias e formatos não suportados; não contornar login/DRM/restrições.

Os testes com visibilidade injetada não substituem QA físico de oclusão/Spaces, memória/energia sustentadas, macOS 14 e múltiplos monitores. CI remoto bloqueado por billing #11.

## Validação após integrar PRs #38 e #24

Integrados por merges normais: main em `a1c3ece` (#38) e depois `35a9885` (#24). Preservados rótulos localizados, MediaThumbnail, contexto por monitor e acessibilidade; fonte web mantém a identificação do provedor. Oclusão central e compatibilidade legada não foram alteradas nesta rodada. `docs/QA.md` foi mantido idêntico ao de main, com este roteiro separado.

`CARGO_INCREMENTAL=0 sh scripts/build-native.sh` aprovado antes do Swift. `swift test -j 2`: 54 Swift Testing e 36 XCTest, 3 skips opt-in (snapshot/HLS/embed), sem falhas/warnings. Snapshot opcional da biblioteca executado separadamente com `-j 2` e inspecionado: rótulos FOTO/VÍDEO, thumbnails e contexto preservados. Testes de login usam serviço fake, sem registrar o app no login real. `git diff --cached --check` aprovado. Não houve teste real de YouTube/Vimeo ou benchmark nesta rodada; os fixtures não certificam reprodução dos provedores. CI continua bloqueado por billing #11.

## Composição com fit/fill (#29)

Preservados `MediaFit`, o teto de saída de foto (128 MiB estimados/16.384 px), a validação pós-decode, orientação/Retina e a política central do #39. O renderer recebe fit/fill para mídia nativa junto da injeção offline web. Embeds continuam proporcionais pelo player oficial, sem seletor nativo que não teria efeito.

Fixture literal v1 combinando URL remota youtube-nocookie e preferência fill confirma migração v2 com fonte, modo, seleção e bytes preservados antes da gravação. A suíte mantém regressões de covered+resume/rebuild e decode extremo. Build estático release aprovado antes do Swift; `swift test -j 2`: 65 Swift Testing e 40 XCTest, 3 skips opt-in, sem falhas/warnings. Diff staged aprovado; `MediaFit.swift` e `docs/QA.md` idênticos a main. Sem teste real de rede ou benchmark nesta rodada; fixtures não certificam reprodução de provedores.

## Conjunto consolidado das issues #15 e #21

PR #35 incorpora por merge normal o HEAD `8863ae1424261195e65c10362f44af8f43790850` do PR #32, preservando o histórico. A política/adaptador remoto permanecem idênticos àquele SHA; fonte web mantém renderer separado. O callback onState e o retry por monitor coexistem com descarte web condicionado à política central. Veja também [QA da recuperação remota](remote-stream-recovery.md). PR #32 só será encerrado pela coordenação após revisão/integração do conjunto.

O teste de composição injeta dois monitores lógicos e HTML offline: retry direcionado de uma fonte web coberta não cria WKWebView nem estado de vídeo direto e preserva a view do outro monitor. Ao ficar visível, retoma; stop descarta ambas.

Validação consolidada: build Rust estático release antes do Swift; suíte offline com `swift test -j 2` aprovada (65 Swift Testing e 53 XCTest, 3 skips opt-in). Reexecução completa com HLS oficial Apple, YouTube `M7lc1UVf-VE` e snapshot habilitados: 65 Swift Testing e 53 XCTest aprovados, zero skips/falhas/warnings. HLS confirmou ready, avanço de tempo, estado playing, mudo, pausa por oclusão e stop; YouTube confirmou playing/mudo e descarte. Snapshot da biblioteca inspecionado. Esses testes reais de exemplos não certificam reconexão/live, compatibilidade universal nem consumo prolongado; os fixtures offline só comprovam seus contratos de estado/ciclo de vida. Vimeo permanece não certificado. CI remoto bloqueado por billing #11.


## Public official-player runtime sample (2026-11-01, #7/#42)

Source f2b93815b5b8e9fa28e5b5912f189b829962c0ae on macOS 27.0.1 arm64 passed `WebWallpaperRendererTests.testOptInOfficialEmbedPlaysMutedAndStops` with YouTube `https://youtu.be/M7lc1UVf-VE` (3.257s) and public Vimeo `https://vimeo.com/19231868` (2.706s). See [scalar evidence](evidence/official-web-20261101.json).

The opt-in case requires provider playing, muted=true and actual provider time advancing; disabled audio output must report volume zero. The old expectation of 25% volume while audio was disabled was stale after the audio-safety policy changes and has been corrected. Requested gain remains separate from actual disabled output. It never unmutes the live provider. Pause must clear/release the native webview after outstanding callbacks finish; resume creates a playing, still-muted view; stop leaves the surface empty. Source changes are limited to this test and QA documentation.

Reproduce with `WALLMOTION_WEB_TEST_URL='https://vimeo.com/19231868' swift test -j 2 --filter WebWallpaperRendererTests.testOptInOfficialEmbedPlaysMutedAndStops` (or the public YouTube URL). These calls make opt-in network requests and may briefly display a desktop QA window. The default suite remains offline. Full local check passed: 50 Rust tests and Clippy, 39 Python, 168 Core, 223 AppKit cases (11 explicit skips). Remote CI remains blocked by #11.

This sample closes the earlier absence of a working public Vimeo playback example. The provider API/time evidence is not a guarantee of pixel-perfect framing or provider-overlay suppression: inspected startup captures still include provider chrome, and the early Vimeo capture is black while its time advances. It does not establish stable rendering over hours, physical sound output, resource efficiency or universal compatibility. The two examples are public; no user-supplied private hash was tested or published. Unlisted-hash parsing/placement, error redaction and provider failures remain covered by existing deterministic tests, not live unlisted/login/DRM certification. Provider embedding/privacy restrictions are honored rather than bypassed.
