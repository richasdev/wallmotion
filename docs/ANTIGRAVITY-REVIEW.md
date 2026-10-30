# Relatório de Revisão Independente de Código — Wallmotion

**Data:** Outubro de 2026  
**Revisor:** Antigravity (Architecture Research & Code Review Agent)  
**Destinatário:** Codex Coordenador  
**Escopo Analisado:** `Sources/WallmotionCore/`, `Sources/Wallmotion/` e `Tests/WallmotionCoreTests/`  
**Diretiva:** Estudo estritamente de leitura, sem mutação de código de produção/testes e sem execução concorrente de `swift build`/`test`.

---

## 1. Esclarecimento Metodológico sobre Premissas de Performance

No relatório arquitetural preliminar foram mencionadas estimativas de consumo de recursos (ex.: CPU < 1-2%, alocação de memória RAM de 1-3 GB para GIFs grandes e supressão de *power assertions* via `isMuted`).
> [!NOTE]
> **Esclarecimento:** Tais números e comportamentos devem ser tratados estritamente como **hipóteses teóricas de trabalho**, sem garantias prévias de performance até que sejam executadas medições empíricas com o `Instruments` (Allocations, Time Profiler) e utilitários de sistema (`powermetrics`, `pmset -g assertions`) no hardware real de destino.

> [!NOTE]
> **Histórico de Arquivos e Marca (Wallmotion):**
> Em estrita conformidade com as diretrizes de marca do produto, a denominação oficial e exclusiva é **Wallmotion**. Esta revisão técnica avaliou o código no estado em que o coordenador de janelas e renderizadores residia no arquivo `Sources/Wallmotion/DesktopCoordinator.swift` (classe `DesktopCoordinator`). O coordenador subsequentemente renomeou esse componente para `Sources/Wallmotion/DesktopCoordinator.swift` (classe `DesktopCoordinator`). Os caminhos e linhas listados abaixo refletem o snapshot exato auditado durante a detecção dos achados, correspondendo diretamente às mesmas seções em `DesktopCoordinator.swift`.

---

## 2. Resumo Executivo dos Achados

| ID | Severidade | Categoria | Descrição Sucinta | Localização |
| :--- | :--- | :--- | :--- | :--- |
| **DEC-01** | **Decisão de Design** | Renderização / Geometria | Aspect Fit deliberado (`resizeAspect` / `scaleProportionallyUpOrDown`) preservando integridade da imagem sem corte | `DesktopCoordinator.swift:47, 97` |
| **DEC-02** | **Decisão de Escopo** | AppKit / Spaces | Janela focada em Spaces normais de Mesa (Fullscreen/Stage Manager fora do MVP) | `DesktopCoordinator.swift:28` |
| **BUG-03** | **Alta** | AVFoundation | Observers de erro e falha escutam `templateItem` em vez dos clones do `AVPlayerLooper` | `DesktopCoordinator.swift:120-145` |
| **BUG-04** | **Alta** | AVFoundation / Loop | Loop de vídeo remoto com `AVQueuePlayer` e `seek` frágil trava no último quadro se `finished == false` | `DesktopCoordinator.swift:125-140` |
| **BUG-05** | **Média** | Multi-Monitor | `Display.identify` ignora monitores caso `CGDisplayCreateUUIDFromDisplayID` retorne `nil` | `DesktopCoordinator.swift:11-17` |
| **BUG-06** | **Média** | Ciclo de Vida / UX | Wake e ativação de sessão chamam `refreshPlayback()` destruindo e recriando todas as janelas do zero | `LibraryModel.swift:37, 39, 41` |
| **BUG-07** | **Média** | Recursos / Vazamento | `WallpaperRenderer.stop()` fecha a janela mas não desvincula `playerLayer.player` nem invalida a camada | `DesktopCoordinator.swift:173-199` |
| **BUG-08** | **Baixa** | Validação de Dados | URLs remotas sem caminho geram título `"/"` em vez do nome do host | `Wallpaper.swift:38` |
| **RISK-01** | **Risco / Performance** | I/O de Persistência | Importação de múltiplos arquivos executa gravação atômica completa do JSON a cada item | `LibraryModel.swift:114-117` |
| **RISK-02** | **Risco / Resiliência** | Rede / Streaming | Ausência de tratamento para *stalls* de buffer em streams remotos HLS (`.m3u8`) | `DesktopCoordinator.swift:105-125` |

---

## 3. Achados Detalhados: Decisões Documentadas e Bugs Reais

### DEC-01: Proporção de Vídeo e Imagem em Modo Fit (Escolha Documentada de Design)
- **Status:** **Escolha Documentada do Projeto** (Não é bug crítico)
- **Caminho e Linhas:** `Sources/Wallmotion/DesktopCoordinator.swift:47, 97`
- **Contexto de Arquitetura:**  
  O uso de `.resizeAspect` e `.scaleProportionallyUpOrDown` foi documentado como decisão de produto para o MVP: preservar 100% do enquadramento original da mídia sem cortar bordas (aspect fit), gerando barras pretas quando a proporção difere da tela. Uma opção futura configurável pelo usuário (Fill vs. Fit) poderá ser oferecida pós-MVP.

---

### DEC-02: Escopo de Janela em Spaces Normais de Mesa (Escolha Documentada de Escopo)
- **Status:** **Escolha Documentada do Projeto** (Não é bug crítico)
- **Caminho e Linha:** `Sources/Wallmotion/DesktopCoordinator.swift:28`
- **Contexto de Arquitetura:**  
  A configuração `collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]` atende integralmente ao escopo definido no plano: atuação estável nos Spaces normais de Desktop. O suporte a Spaces exclusivos de aplicativos em tela cheia e Stage Manager foi expressamente postergado para a fase pós-MVP por demandar QA em hardware diversificado.

---

### BUG-03: Observers do AVPlayerLooper Escutam o Template em Vez dos Clones
- **Status:** **Bug Confirmado**
- **Caminho e Linhas:** `Sources/Wallmotion/DesktopCoordinator.swift:94-99, 115-122`
- **Evidência no Código:**
  ```swift
  looper = AVPlayerLooper(player: queue, templateItem: item)
  ...
  statusObserver = item.observe(\.status, options: [.initial, .new]) { item, _ in ... }
  failureObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemFailedToPlayToEndTime,
      object: item,
      queue: .main
  ) { _ in ... }
  ```
- **Impacto no Usuário:**  
  Segundo a documentação oficial da Apple, `AVPlayerLooper` não insere o `templateItem` diretamente no `AVQueuePlayer`; ele gera cópias internas (`loopingItems`). Se o vídeo reproduzir a primeira volta com sucesso mas encontrar um erro de decodificação na segunda repetição (ou falha de GPU), o `failureObserver` **não será disparado**, pois está filtrado explicitamente pelo objeto `item` (que já não é o item ativo na fila).
- **Correção Sugerida:**
  Remover a restrição de objeto único no observer de falha ou observar a fila do player:
  ```swift
  failureObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemFailedToPlayToEndTime,
      object: nil, // Captura falhas de itens gerados pelo looper
      queue: .main
  ) { [weak self] notification in
      guard let self, let failedItem = notification.object as? AVPlayerItem,
            self.player?.items().contains(failedItem) == true else { return }
      onError("A reprodução falhou durante o loop do vídeo.")
  }
  ```

---

### BUG-04: Vídeo Remoto Travado no Fim do Arquivo se Seek Interrompido
- **Status:** **Bug Confirmado**
- **Caminho e Linhas:** `Sources/Wallmotion/DesktopCoordinator.swift:101-114`
- **Evidência no Código:**
  ```swift
  queue.insert(item, after: nil)
  queue.actionAtItemEnd = .pause
  endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
      Task { @MainActor [weak self] in
          guard let self else { return }
          self.player?.seek(to: .zero) { [weak self] finished in
              Task { @MainActor [weak self] in
                  guard finished, let self, !self.paused else { return }
                  self.player?.play()
              }
          }
      }
  }
  ```
- **Impacto no Usuário:**  
  1. Se `finished` for `false` (fato frequente quando o buffer de rede ainda está sincronizando quadros ou há leve concorrência no pipeline), a cláusula `guard finished` aborta e `self.player?.play()` **nunca mais é chamado**. O vídeo permanece congelado indefinidamente no último quadro.
  2. Chamadas aninhadas redundantes de `Task { @MainActor in }` dentro de um bloco já despachado para a fila principal (`queue: .main`).
- **Correção Sugerida:**
  Utilizar tolerâncias nulas para seek exato e garantir tentativa de play ou recuperação:
  ```swift
  endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: item,
      queue: .main
  ) { [weak self] _ in
      guard let self else { return }
      self.player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
          guard let self, !self.paused else { return }
          self.player?.play()
      }
  }
  ```

---

### BUG-05: Telas Ignoradas se `CGDisplayCreateUUIDFromDisplayID` Retornar Nil
- **Status:** **Bug Confirmado**
- **Caminho e Linhas:** `Sources/Wallmotion/DesktopCoordinator.swift:10-14`
- **Evidência no Código:**
  ```swift
  @MainActor static func identify(_ screen: NSScreen) -> String? {
      guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
            let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
      return CFUUIDCreateString(nil, uuid) as String
  }
  ```
- **Impacto no Usuário:**  
  Em monitores externos legados sem número de série EDID, monitores virtuais (DisplayLink, Sidecar de iPad, telas de captura HDMI), `CGDisplayCreateUUIDFromDisplayID` frequentemente retorna `nil`. Com o `guard` atual, o monitor inteiro é descartado da lista `displays` e o usuário não consegue aplicar wallpapers nele.
- **Correção Sugerida:**
  Prover *fallback* transparente baseado no próprio ID do display:
  ```swift
  @MainActor static func identify(_ screen: NSScreen) -> String? {
      guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
      let displayID = number.uint32Value
      if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
          return CFUUIDCreateString(nil, uuid) as String
      }
      return "display-\(displayID)"
  }
  ```

---

### BUG-06: Recriação Destrutiva de Janelas e Players ao Acordar do Repouso
- **Status:** **Bug Confirmado**
- **Caminho e Linhas:** `Sources/Wallmotion/LibraryModel.swift:37, 39, 41`
- **Evidência no Código:**
  ```swift
  observe(NSWorkspace.didWakeNotification, in: workspace) { $0.policy.sleeping = false; $0.refreshPlayback() }
  observe(NSWorkspace.screensDidWakeNotification, in: workspace) { $0.policy.screenAsleep = false; $0.refreshPlayback() }
  observe(NSWorkspace.sessionDidBecomeActiveNotification, in: workspace) { $0.policy.sessionInactive = false; $0.refreshPlayback() }
  ```
- **Impacto no Usuário:**  
  `refreshPlayback()` invoca `coordinator.rebuild(...)`, que por sua vez chama `stop()` e destrói todas as janelas `DesktopWindow` e instâncias de `AVPlayer`. Toda vez que o Mac acorda do repouso ou a tela liga, os papéis de parede são reconstruídos do zero, fazendo os vídeos voltarem para o segundo `00:00` e causando um piscar preto na tela, em vez de simplesmente retomar a reprodução de onde estavam pausados.
- **Correção Sugerida:**
  Substituir `$0.refreshPlayback()` por `$0.applyPolicy()` nos eventos de reativação:
  ```swift
  observe(NSWorkspace.didWakeNotification, in: workspace) { $0.policy.sleeping = false; $0.applyPolicy() }
  observe(NSWorkspace.screensDidWakeNotification, in: workspace) { $0.policy.screenAsleep = false; $0.applyPolicy() }
  observe(NSWorkspace.sessionDidBecomeActiveNotification, in: workspace) { $0.policy.sessionInactive = false; $0.applyPolicy() }
  ```
  *(Nota: Se houver mudança real de geometria de monitores durante o repouso, o `NSApplication.didChangeScreenParametersNotification` já é disparado independentemente e cuidará do rebuild).*

---

### BUG-07: Desalocação Incompleta de `AVPlayerLayer` ao Parar o Renderer
- **Status:** **Bug Confirmado**
- **Caminho e Linhas:** `Sources/Wallmotion/DesktopCoordinator.swift:133-150`
- **Evidência no Código:**
  Em `WallpaperRenderer.stop()`, o `player` tem `removeAllItems()` e a janela recebe `close()`, mas `playerLayer.player` nunca é anulado.
- **Impacto no Usuário:**  
  Camadas `AVPlayerLayer` retidas pelo servidor de composição (`WindowServer`) mantêm contexto de texturas de vídeo alocados na VRAM mesmo após a janela ser fechada.
- **Correção Sugerida:**
  ```swift
  func stop() {
      ...
      if let surface = window.contentView as? VideoSurface {
          surface.playerLayer.player = nil
          surface.playerLayer.removeFromSuperlayer()
      }
      player?.pause()
      player?.removeAllItems()
      ...
  }
  ```

---

### BUG-08: Título de URL Raiz Resulta em Barra `"/"`
- **Status:** **Bug Confirmado**
- **Caminho e Linha:** `Sources/WallmotionCore/Wallpaper.swift:38`
- **Evidência no Código:**
  ```swift
  let title = url.lastPathComponent.isEmpty ? (url.host ?? "Vídeo remoto") : url.lastPathComponent
  ```
- **Impacto no Usuário:**  
  No Foundation do macOS, para uma URL como `https://stream.example.com/`, `url.lastPathComponent` retorna `"/"` (não vazio). O item salvo na biblioteca ganha o título `"/"`.
- **Correção Sugerida:**
  ```swift
  let last = url.lastPathComponent
  let title = (last.isEmpty || last == "/") ? (url.host ?? "Vídeo remoto") : last
  ```

---

## 4. Riscos de Regressão e Observações Arquiteturais

### RISK-01: Sobrecarga de E/S na Importação em Lote
- **Caminho:** `Sources/Wallmotion/LibraryModel.swift:114-117`
- **Evidência:** No laço `for url in urls`, cada arquivo copiado aciona imediatamente `update(next)`, que codifica todo o documento `LibraryState` e grava atomicamente no disco `library.json`.
- **Mitigação:** Acumular novos itens em uma coleção intermediária e realizar uma única invocação de `update(next)` após o processamento de todos os arquivos do painel.

### RISK-02: Tratamento de Queda e Reconexão de Streams HLS
- **Caminho:** `Sources/Wallmotion/DesktopCoordinator.swift:101-122`
- **Evidência:** Não há observador para `AVPlayerItemPlaybackStalledNotification` ou verificação de `playbackLikelyToKeepUp`.
- **Mitigação:** Em caso de *stall*, agendar tentativa de retomada após pequeno intervalo exponencial para evitar que streams de câmeras ao vivo fiquem paralisados permanentemente em pequenas oscilações de Wi-Fi.

---

## 5. Verificações Não Executadas (Limitações Desta Análise)

Em estrito cumprimento das instruções recebidas:
1. **Compilação e Suíte de Testes:** Não foram executados `swift build` nem `swift test`, uma vez que o coordenador estava compilando e operando paralelamente.
2. **Ambiente Multi-Display Físico:** Não foi realizada execução interativa em múltiplos monitores externos reais conectados com resoluções ou taxas de atualização mistas (ex.: 60Hz + 120Hz ProMotion).
3. **Métricas de Bateria/CPU:** Não foram coletados perfis com `powermetrics` ou `Instruments` para atestar o consumo real de energia em modo bateria versus tomada.

---
*Relatório de revisão arquivado em `docs/ANTIGRAVITY-REVIEW.md` para apreciação direta do coordenador.*
