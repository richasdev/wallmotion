# Wallmotion

Um aplicativo de fundos animados nativo para macOS 14 ou superior. Fotos, GIFs animados, vídeos locais e URLs diretas HTTPS de vídeo/HLS como fundo de tela, com seleção por monitor, repetição em todas as telas ou panorama de foto entre elas.

**Em desenvolvimento:** veja o [plano de entregas](docs/PLAN.md), a [arquitetura](docs/ARCHITECTURE.md) e as [issues](https://github.com/richasdev/wallmotion/issues).

## Desenvolvimento

Requer macOS 14+, Xcode Command Line Tools, Swift 6 e Rust estável (edição 2024). Execute na raiz:

```sh
sh scripts/check.sh
sh scripts/run.sh
```

O app usa APIs públicas de AppKit/AVFoundation. Ele mantém janelas atrás dos ícones do desktop enquanto está aberto; encerrar o app revela o wallpaper original. Não altera arquivos internos do macOS.

Para gerar o app de desenvolvimento:

```sh
sh scripts/build-app.sh
open dist/Wallmotion.app
```

O script compila o scanner Rust como biblioteca estática e depois o app Swift. Para usar `swift test` ou abrir `Package.swift` no Xcode diretamente, execute `sh scripts/build-native.sh` antes. O `.app` inclui o Rust no executável e não requer Cargo na máquina de quem o executa. O build usa a arquitetura do host e assinatura ad-hoc; Developer ID e notarização ficam para a distribuição pública.

Entre rodadas de validação, use `sh scripts/clean-builds.sh` para remover os artefatos Rust de desenvolvimento, preservando a biblioteca release. Para limpar também os builds release/Swift, com os compiladores parados, use `sh scripts/clean-builds.sh --all` e depois `sh scripts/build-native.sh` antes de compilar novamente. O `.app` em `dist/` é preservado; os caches globais de Cargo e de outros projetos não são alterados.

YouTube e Vimeo podem ser adicionados explicitamente como fontes web de vídeo individual, usando embeds oficiais em WKWebView. A disponibilidade depende do provedor; login, DRM, playlists e páginas web arbitrárias não são suportados. Pausar descarta a view; retomar reinicia o embed. Veja [fontes web e limites](docs/WEB-SOURCES.md). Arquivos HEIC/JPEG/PNG/TIFF/BMP/GIF e vídeos MP4/MOV/M4V são reconhecidos; a decodificação depende do suporte do macOS ao codec.

## Performance

Vídeos usam AVFoundation; fotos são preparadas serialmente fora da interface com ImageIO e um orçamento de saída conservador. No panorama, uma imagem preparada é compartilhada entre as telas; o recorte segue a disposição dos monitores, incluindo posições negativas e espaços. Ajustar, Preencher, Centralizar e Esticar também se aplicam ao conjunto. Vídeos e GIFs ainda não atravessam telas. Veja [panorama e limites de qualidade](docs/qa/photo-panorama.md). O scanner Rust inspeciona a estrutura dos GIFs sem decodificar pixels e calcula um orçamento conservador de frames antes da importação e exibição. GIFs acima de 256 MiB estimados por arquivo são rejeitados. A reprodução soma até 512 MiB estimados entre monitores conectados, contando cada view separadamente (inclusive pausada); uma seleção que exceda o teto é rejeitada com mensagem e mantém os wallpapers atuais; prefira MP4 para animações longas. Importação/cópia roda fora da thread da interface, e mudar um monitor preserva os players dos demais.

O app pausa em repouso de tela/sistema, troca de sessão e, opcionalmente, modo de baixo consumo, preservando a pausa manual. Sinais de bloqueio de tela complementam essa política em melhor esforço. Veja [medições e limites](docs/PERFORMANCE.md) e o [roteiro de QA](docs/QA.md).

## Equipe de agentes

- **Codex:** implementação e testes em branches isoladas, commits e PRs por entrega.
- **Antigravity (`agy`):** estudo, issues, revisão do HEAD e merge protegido.

O fluxo atual usa apenas esses dois agentes, conforme [a política de revisão](docs/REVIEW-POLICY.md).

Os resultados e limitações das revisões ficam em `docs/`.
