# Arquitetura

## Decisões

- Swift Package, macOS 14+, SwiftUI para a biblioteca e AppKit para ciclo de vida/janelas. Rust estável para análise estrutural de GIF via FFI C; sem dependências externas de runtime.
- `WallmotionCore`: modelos Codable, validação de fontes, importação gerenciada e estado JSON atômico. Sem dependência da UI.
- `Wallmotion`: biblioteca observável na main actor, coordenador de monitores, renderizadores e política de energia.
- `crates/wallmotion-media`: scanner Rust sem alocação de frames e sem decodificação LZW. Ligado estaticamente pelo alvo C `CWallmotionMedia`; build explícito antes do Swift. Não há IPC nem processo Rust separado.
- Janelas borderless no nível desktop + 1 (abaixo dos ícones), sem foco e com `ignoresMouseEvents`; participam dos Spaces normais. Fullscreen/Stage Manager precisam de QA em hardware real.
- `NSImageView` para fotos/GIFs; `AVQueuePlayer` + `AVPlayerLooper` para vídeos locais. URLs remotas usam AVPlayer, repetição em fim de item para arquivos finitos e reprodução contínua para HLS ao vivo.
- Arquivos importados são copiados para Application Support/Wallmotion/Media. A biblioteca referencia a cópia, evitando perda de acesso quando a origem muda. O app de desenvolvimento não usa App Sandbox; sandbox futuro exige uma estratégia explícita de bookmarks.
- Atribuições usam o UUID de display fornecido por CoreGraphics. Monitores desconectados preservam a seleção. Quando UUID não está disponível, o ID numérico é usado como fallback de sessão e pode mudar entre conexões. A reconciliação preserva janelas/players cuja mídia e geometria continuam iguais.
- Preferências, biblioteca e atribuições são um único documento versionado salvo por escrita atômica. Arquivo inválido causa erro visível, sem sobrescrever os dados existentes.
- Pausa manual e pausa por política são estados separados. Desbloquear/acordar nunca deve desfazer uma pausa manual.
- Fotos usam thumbnail ImageIO dimensionada à tela; GIFs passam por orçamento conservador de 256 MiB de frames por mídia antes de abrir o decodificador AppKit. O componente puro `GIFPlaybackBudget` limita a soma a 512 MiB entre displays ativos, incluindo GIFs pausados, com uma cobrança por view mesmo para o mesmo arquivo. `DesktopCoordinator` usa os metadados do `GIFPreflight` antes do decodificador e confirma a cota somente após criar o renderer; substituições descontam a cobrança anterior do monitor selecionado. Falhas preservam o renderer e a cota anteriores. Desconexão, remoção, troca para foto/vídeo e stop liberam a cobrança; reconexão/restauração revalidam o teto e mostram erro por monitor se não houver espaço. A seleção rejeitada pelo orçamento não é salva. Instâncias `NSImage` continuam independentes até comprovar segurança da animação entre views. Isso limita entradas caras, mas não garante um teto de memória residente total; a troca pode manter temporariamente o renderer anterior até a criação do novo terminar.

## Contrato de URLs

URLs remotas devem usar HTTPS, possuir host e não conter credenciais. Rejeitar páginas conhecidas de provedores e extensões claramente de páginas web; permitir caminhos sem extensão usados por CDNs. Validar sintaxe não prova que o servidor retorna mídia: erros de reprodução são apresentados pelo app. Redirecionamentos e codecs são responsabilidade do AVFoundation; não há extração de vídeos ou bypass de DRM.

## Limites do MVP

Não instala conteúdo em bancos de wallpaper do macOS, não muda a tela de bloqueio e não promete persistência em Spaces fullscreen. GIFs dependem do decodificador AppKit. O app precisa estar aberto para manter movimento. O wallpaper nativo continua configurado e reaparece quando o app para.

## Referências primárias

- [NSWindow.Level](https://developer.apple.com/documentation/appkit/nswindow/level-swift.struct)
- [Nível desktop](https://developer.apple.com/documentation/swiftui/windowlevel/desktop)
- [AVPlayerLooper](https://developer.apple.com/documentation/avfoundation/avplayerlooper)
- [NSWorkspace](https://developer.apple.com/documentation/appkit/nsworkspace)
