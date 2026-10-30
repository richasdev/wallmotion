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
