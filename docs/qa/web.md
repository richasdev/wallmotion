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
