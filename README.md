# Wallmotion

Um wallpaper engine nativo para macOS 14 ou superior. Fotos, GIFs animados, vídeos locais e URLs diretas HTTPS de vídeo/HLS como fundo de tela, com uma seleção por monitor.

**Em desenvolvimento:** veja o [plano de entregas](docs/PLAN.md), a [arquitetura](docs/ARCHITECTURE.md) e as [issues](https://github.com/richasdev/wallmotion/issues).

## Desenvolvimento

Requer macOS 14+, Xcode Command Line Tools e Swift 6. Execute na raiz:

```sh
swift test
swift run Wallmotion
```

O app usa APIs públicas de AppKit/AVFoundation. Ele mantém janelas atrás dos ícones do desktop enquanto está aberto; encerrar o app revela o wallpaper original. Não altera arquivos internos do macOS.

URLs de páginas (YouTube, Vimeo etc.) e conteúdo com DRM não são fontes de vídeo direto e não fazem parte do MVP. Arquivos HEIC/JPEG/PNG/TIFF/BMP/GIF e vídeos MP4/MOV/M4V são reconhecidos; a decodificação depende do suporte do macOS ao codec.

## Equipe de agentes

- **Codex coordenador:** implementação, integração, issues e commits por entrega.
- **Codex testes:** testes do núcleo, separado dos arquivos do app.
- **Antigravity (`agy`):** estudo de arquitetura e revisão independente, sem alterações concorrentes no código do app.

Os resultados e limitações das revisões ficam em `docs/`.
