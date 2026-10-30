# Arquitetura

## Decisões

- Swift Package, macOS 14+, SwiftUI para a biblioteca e AppKit para ciclo de vida/janelas. Sem dependências externas.
- `WallmotionCore`: modelos Codable, validação de fontes, importação gerenciada e estado JSON atômico. Sem dependência da UI.
- `Wallmotion`: biblioteca observável na main actor, coordenador de monitores, renderizadores e política de energia.
- Janelas borderless no nível desktop + 1 (abaixo dos ícones), sem foco e com `ignoresMouseEvents`; participam dos Spaces normais. Fullscreen/Stage Manager precisam de QA em hardware real.
- `NSImageView` para fotos/GIFs; `AVQueuePlayer` + `AVPlayerLooper` para vídeos locais. URLs remotas usam AVPlayer, repetição em fim de item para arquivos finitos e reprodução contínua para HLS ao vivo.
- Arquivos importados são copiados para Application Support/Wallmotion/Media. A biblioteca referencia a cópia, evitando perda de acesso quando a origem muda. O app de desenvolvimento não usa App Sandbox; sandbox futuro exige uma estratégia explícita de bookmarks.
- Atribuições usam o identificador estável de display fornecido por CoreGraphics. Monitores desconectados preservam a seleção; mudança de tela reconstrói os renderizadores.
- Preferências, biblioteca e atribuições são um único documento versionado salvo por escrita atômica. Arquivo inválido causa erro visível, sem sobrescrever os dados existentes.
- Pausa manual e pausa por política são estados separados. Desbloquear/acordar nunca deve desfazer uma pausa manual.

## Contrato de URLs

URLs remotas devem usar HTTPS, possuir host e não conter credenciais. Rejeitar páginas conhecidas de provedores e extensões claramente de páginas web; permitir caminhos sem extensão usados por CDNs. Validar sintaxe não prova que o servidor retorna mídia: erros de reprodução são apresentados pelo app. Redirecionamentos e codecs são responsabilidade do AVFoundation; não há extração de vídeos ou bypass de DRM.

## Limites do MVP

Não instala conteúdo em bancos de wallpaper do macOS, não muda a tela de bloqueio e não promete persistência em Spaces fullscreen. GIFs dependem do decodificador AppKit. O app precisa estar aberto para manter movimento. O wallpaper nativo continua configurado e reaparece quando o app para.

## Referências primárias

- [NSWindow.Level](https://developer.apple.com/documentation/appkit/nswindow/level-swift.struct)
- [Nível desktop](https://developer.apple.com/documentation/swiftui/windowlevel/desktop)
- [AVPlayerLooper](https://developer.apple.com/documentation/avfoundation/avplayerlooper)
- [NSWorkspace](https://developer.apple.com/documentation/appkit/nsworkspace)
