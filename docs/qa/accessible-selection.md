# Contraste e seleção acessível (#47)

A identidade aurora/W permanece. Contornos de seleção usam ciano no tema escuro e violeta #6B38CC no claro. O texto Aplicado e o check continuam redundantes com a cor; com contraste aumentado o contorno fica mais espesso. O painel de opções recebe delimitação leve, sem alterar controles nativos.

VoiceOver recebe valor de seleção do card, monitor numerado, fundo aplicado e estado remoto. O seletor de enquadramento informa a descrição do modo e usa menu se os segmentos não couberem. O seletor de organização também tem fallback para menu. A marca vetorial decorativa fica oculta do leitor, pois o nome Wallmotion já está adjacente.

Verificação local: capturas claro/escuro e janela mínima. O contraste calculado contra branco/preto serve como cheque dos tokens de cor; não certifica todos os fundos, preferências de sistema ou estados. Não houve homologação com VoiceOver real, Increase Contrast real nem texto aumentado em todos os idiomas. A issue #47 permanece aberta para esse QA manual.

QA manual: navegar só com teclado; percorrer cabeçalhos, monitores e cards com VoiceOver; conferir nomes e valores sem repetição da marca; selecionar quatro enquadramentos e ouvir as dicas; ativar contraste aumentado e ampliar texto; redimensionar barra lateral e janela até mínimo820x560. Confirmar que aplicar/remover e controles nativos seguem alcançáveis e legíveis.

## Auditoria nativa adicional — 01/11/2026

`AccessibleLibraryTests` calcula o contraste do contorno de seleção contra a cor
nativa `controlBackgroundColor` resolvida em `aqua`/`darkAqua`. Neste Mac, os pares
medidos foram 6,8566:1 e 12,0128:1, acima do limite de 3:1 para esse contorno. Isso
não certifica todos os pixels, textos, transparências ou configurações de display.

Outra integração hospeda a biblioteca em 820×560 pontos, solicita o ambiente SwiftUI
`.accessibility3` e aparências nativas de alto contraste claras/escuras. A captura
valida conteúdo renderizado; o teste move o scroll view AppKit até o fim e verifica
mudança real do clip para alcançar a coleção. Quatro capturas (início e fim em cada
tema) foram inspecionadas. Isso não altera a preferência global de texto/contraste
nem certifica sua equivalência em todos os Macs/idiomas. As exportações opt-in usam
`WALLMOTION_ACCESSIBILITY_SNAPSHOT_DIR`.

O teste de ações/seleção via AX é separado e opt-in (`WALLMOTION_NATIVE_AX_QA=1`).
Neste host de XCTest, `NSHostingView.accessibilityChildren()` não expôs filhos
SwiftUI, mesmo após captura e tentativa de janela visível. Nenhuma permissão foi
solicitada/alterada; não foi usada API privada para forçar a árvore. O caso é
registrado como **skip**, sem atestar leitura ou ações de VoiceOver. A issue #47
permanece aberta para essa validação com tecnologia assistiva real.

As dicas de enquadramento panorâmico agora dizem “mídia”, cobrindo fotos e GIFs.

Checks locais após integrar a matriz de performance: 50 testes Rust, Clippy com
warnings negados, 39 Python, 168 Swift Core e 223 AppKit (11 skips opt-in). Release
e verificação estrita da assinatura ad-hoc passaram. Nenhum skip AX foi contado
como validação de ações do leitor de tela.
