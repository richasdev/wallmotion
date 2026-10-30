# Especificação Técnica e Plano da Próxima Fase (Issues #7 e #8)

**Data:** Outubro de 2026  
**Autor:** Antigravity (Architecture Research Agent)  
**Alvo:** Wallmotion (macOS 14+)  
**Escopo:** Estudo de viabilidade pós-MVP — Páginas Web/Embeds (#7), Protocolo de Medição e Oclusão/Energia (#8).

---

## 1. Contexto, Evidências Recentes e Limites de Certificação

### 1.1 Evidência Medida em Laboratório Local
- **HLS VOD com AVPlayer:** Em testes locais de homologação conduzidos pelo Codex, um stream HLS VOD de exemplo oficial da Apple foi instanciado e executado com `AVPlayer` real em **3,5 segundos**, transitando por todos os estados de ciclo de vida (`readyToPlay`, avanço de tempo com `currentTime`, silenciamento defensivo com `isMuted`, pausa e encerramento com `replaceCurrentItem(with: nil)`).
- **Limite Técnico da Evidência:** Este teste atesta a reprodução de fluxos pré-gravados em contêiner HLS (`.m3u8`). **Não certifica transmissões ao vivo contínuas (live HLS 24/7)**, onde a duração é indefinida, nem a recuperação automática diante de perda de conexão de rede ou rotação de listas de reprodução em tempo real. Tais cenários constituem trabalho de campo pós-MVP.

---

## 2. Proposta Técnica: Páginas Web e Embeds de Vídeo (Issue #7)

A reprodução de links não diretos de contêiner (como páginas HTML e players do YouTube e Vimeo) exige um motor de renderização baseado em [WKWebView](https://developer.apple.com/documentation/webkit/wkwebview).

### 2.1 Gestão de Processos WebKit e Privacidade
No macOS, o WebKit adota uma arquitetura multiprocesso (`UIProcess`, `com.apple.WebKit.WebContent`, `com.apple.WebKit.Networking`, `GPUProcess`).

```swift
let configuration = WKWebViewConfiguration()

// Armazenamento efêmero: impede persistência de cookies, cache local e dados de rastreamento
configuration.websiteDataStore = WKWebsiteDataStore.nonPersistent()

// Diretriz para liberar autoplay programático
configuration.mediaTypesRequiringUserActionForPlayback = []

// Desativa recursos desnecessários para exibição passiva de wallpaper
configuration.defaultWebpagePreferences.allowsContentJavaScript = true
let preferences = WKPreferences()
preferences.isElementFullscreenEnabled = false
configuration.preferences = preferences
```

> [!NOTE]
> **Nota sobre `WKProcessPool` e Isolamento:**
> Em versões modernas do macOS, o `WKProcessPool` funciona primariamente como um token opaco. O WebKit gerencia o ciclo de vida e o isolamento de processos auxiliares de acordo com fronteiras de segurança de origem (*process-per-site*), não oferecendo garantias de que instâncias distintas de webview reutilizarão obrigatoriamente o mesmo processo de conteúdo.

### 2.2 Hipótese de Integração com Embeds Oficiais (YouTube / Vimeo)
A reprodução em segundo plano na Mesa depende do comportamento dos scripts dos reprodutores dentro de iframes WebKit:

1. **YouTube (IFrame Player API Oficial):**
   - **URL de Embed Proposta:** `https://www.youtube-nocookie.com/embed/{VIDEO_ID}?autoplay=1&mute=1&controls=0&loop=1&playlist={VIDEO_ID}&enablejsapi=1&playsinline=1`
   - O domínio `youtube-nocookie.com` evita a injeção de cookies de publicidade direcionada.
   - *Hipótese de Autoplay:* A flag `mediaTypesRequiringUserActionForPlayback = []` combinada com `mute=1` visa atender às políticas do WebKit para início sem interação humana. Contudo, scripts internos do YouTube podem impor validações de visibilidade de viewport ou exigir eventos de usuário dependendo de atualizações do provedor, o que requer validação prática.
   - Referência oficial: [Google Developers — YouTube IFrame Player API](https://developers.google.com/youtube/iframe_api_reference).
2. **Vimeo (Player SDK Oficial):**
   - **URL de Embed Proposta:** `https://player.vimeo.com/video/{VIDEO_ID}?autoplay=1&muted=1&loop=1&autopause=0&controls=0&background=1`
   - O parâmetro `background=1` sinaliza ao player a intenção de execução passiva em segundo plano.
   - Referência oficial: [Vimeo Developer Documentation — Embedding Videos](https://developer.vimeo.com/player/sdk).

### 2.3 Pausa e Descarte de Recursos da WebView
Diferente da aceleração enxuta de vídeo nativo, uma página web pode alocar memória substancial em seus processos de suporte do WebKit.

- **Pausa de Reprodução:**
  - Utilizar a API pública do macOS 14+: [`WKWebView.pauseAllMediaPlayback()`](https://developer.apple.com/documentation/webkit/wkwebview/3752243-pauseallmediaplayback).
  - Enviar comandos JavaScript (`player.pauseVideo()`) para congelar timers e loops de animação do DOM.
- **Descarte de Instância:**
  - Carregar `about:blank`, desconectar a view da hierarquia e liberar as referências fortes à `WKWebView`.
  - *Esclarecimento:* Embora essa ação destrua a árvore DOM e cesse a renderização visual, o encerramento do processo `com.apple.WebKit.WebContent` fica a critério das políticas de retenção de cache do próprio WebKit e do subsistema do sistema operacional, não havendo garantia síncrona de terminação do processo do sistema.

### 2.4 Limites Documentados (DRM, Cookies e Autenticação)
> [!WARNING]
> **Fronteiras Inegociáveis de Suporte Web:**
> 1. **Incompatibilidade com DRM Widevine:** O WebKit do macOS não possui suporte nativo ao módulo proprietário Widevine CDM (exclusivo do Chromium). Conteúdos protegidos comercialmente (como vídeos pagos do YouTube, Netflix ou serviços de streaming fechados) não decodificam no `WKWebView` e devem ser expressamente tratados como não suportados.
> 2. **Bloqueio de Login Google em WebViews:** A política de segurança do Google bloqueia ativamente telas de autenticação de contas Google dentro de WebViews embarcadas (*"This browser or app may not be secure"*). O Wallmotion não deve suportar ou solicitar credenciais de usuário para carregar páginas web.

---

## 3. Protocolo Padronizado de Medição Sem Elevação de Privilégios (Issue #8)

O utilitário `powermetrics` exige privilégios de superusuário (`sudo`), inviabilizando rotinas automatizadas em ambientes locais não interativos. O protocolo abaixo baseia-se exclusivamente em interfaces públicas acessíveis com permissões de usuário padrão.

### 3.1 Ferramentas e Métricas Validadas no macOS

| Dimensão | Métrica Primária | Comando / Ferramenta sem Sudo | API Programática (Swift / C) |
| :--- | :--- | :--- | :--- |
| **Memória Real** | **Dirty Footprint** (`phys_footprint`) | `vmmap -summary <PID>` | `task_info(mach_task_self(), TASK_VM_INFO, ...)` lendo o campo `phys_footprint` |
| **Memória Residente** | **Resident Size (RSS)** | `top -l 1 -stats pid,command,cpu,mem,time -pid <PID>` | `task_info(mach_task_self(), TASK_BASIC_INFO, ...)` lendo `resident_size` |
| **Carga de CPU** | **Tempo de CPU e %** | `ps -o %cpu,cputime -p <PID>` | `task_info(mach_task_self(), TASK_THREAD_TIMES_INFO, ...)` |
| **Atividade de Instruções** | **Instruções e Ciclos** | `top -l 1 -stats pid,command,instrs,cycles,csw -pid <PID>` | Contadores de instruções e trocas de contexto expostos pelo kernel |
| **Proxy do Compositor** | **Carga do WindowServer** | `ps -o %cpu -p $(pgrep -x WindowServer)` | *Aferição indireta:* monitorar a variação de CPU do `WindowServer` (proxy de composição da janela, não medição direta do silício da GPU) |
| **Retenção de Repouso** | **Power Assertions de Display/Sleep** | `pmset -g assertions` | `IOPMCopyAssertionsByProcess` / `IOPMAssertionCopyProperties` (<IOKit/pwr_mgt/IOPMLib.h>) |

> [!NOTE]
> **Correção Metodológica sobre Métricas:**
> 1. A disponibilidade das colunas do `top` depende da versão do macOS. O coordenador confirmou que `top -l 1 -pid <PID> -stats pid,command,power` é aceito no macOS 27.0.1 e exibe `POWER`. Esse valor não deve ser interpretado como watts nem comparado entre versões sem validar sua definição. CPU, memória e tempo continuam sendo métricas de base; confirme as chaves no host de cada ensaio.
> 2. O comando `IOPMCopyScheduledPowerEvents` destina-se ao agendamento de eventos futuros de despertar/repouso (ex.: alarmes RTC do sistema), e não à inspeção de assertions ativas. Para consultar assertions em runtime, utilizam-se as APIs de `IOPMLib.h` ou a ferramenta `pmset -g assertions`.
> 3. A CPU consumida pelo processo `WindowServer` reflete o custo de composição e mistura de camadas na tela pelo Quartz Compositor, atuando como um indicador indireto (*proxy*), mas não mede diretamente o consumo de energia ou a ocupação dos núcleos da GPU no silício da Apple.

### 3.2 Protocolo de Ensaio Comparativo
A amostragem deve ser executada nas mesmas condições térmicas e de concorrência:
1. **Fase de Aquecimento:** 30 segundos de execução prévia antes de iniciar o registro.
2. **Janela de Coleta:** 120 segundos de amostragem a 1 Hz em cada estado:
   - **Estado Ativo:** Wallpaper renderizando na área de trabalho.
   - **Estado Pausado:** Wallpaper em pausa manual pelo menu bar.
   - **Estado Ocluso / Suspenso:** Display em repouso ou janela cobrindo a tela.
3. **Métricas a Registrar:** Média e percentil 95 (p95) de `%cpu`, pico de `phys_footprint`, deltas de `cputime` e validação de que `PreventUserIdleDisplaySleep` permanece em `0` no `pmset`.

---

## 4. Limite de Memória GIF Multi-Monitor e Oclusão Reativa (Issue #8)

### 4.1 Proposta de Orçamento Consolidado de GIF
No MVP, o `GIFPreflight.swift` aplica uma restrição isolada de 256 MiB decodificados por mídia. Em sistemas com múltiplos monitores, múltiplas instâncias podem acumular consumo de memória considerável.

**Proposta Arquitetural:**
1. **Cota Global Agregada:**
   - Introduzir um teto global somado (ex.: sugestão de **512 MiB**) compartilhado entre todas as telas ativas.
   - Se uma nova atribuição ultrapassar a cota global restante, a interface deve alertar o usuário e sugerir o uso de arquivos de vídeo MP4/H.264.
2. **Reaproveitamento de Mídia Idêntica:**
   - Caso o mesmo GIF seja atribuído a dois ou mais monitores conectados, o `DesktopCoordinator` deve compartilhar a mesma referência do `NSImage` decodificado, evitando decodificação duplicada na memória do processo.

### 4.2 Proposta de Oclusão Reativa por Eventos
> [!CAUTION]
> **Prevenção de Polling Contínuo:**
> Rotinas baseadas em temporizadores periódicos (ex.: `Timer` a cada 100ms consultando a lista de janelas) forçam o despertar constante dos núcleos da CPU, impedindo que entrem em estados profundos de economia de energia (*C-States*). A arquitetura deve ser estritamente orientada a eventos.

**Abordagens Reativas sob Avaliação:**
1. **Notificação de Oclusão do AppKit:**
   - O AppKit disponibiliza a notificação [`NSWindow.didChangeOcclusionStateNotification`](https://developer.apple.com/documentation/appkit/nswindow/didchangeocclusionstatenotification) e a propriedade [`NSWindow.occlusionState`](https://developer.apple.com/documentation/appkit/nswindow/occlusionstate).
   - *Hipótese de Trabalho:* Quando uma janela opaca maximizada cobre a tela, o sistema emite a notificação de mudança de visibilidade.
   - *Ressalva Arquitetural:* Janelas posicionadas no nível do desktop (`kCGDesktopWindowLevelKey + 1`) coexistem com a camada de ícones do Finder e outros elementos de mesa. A precisão e a confiabilidade com que o WindowServer reporta a perda da flag `.visible` para janelas desse nível em setups com múltiplos monitores ou Stage Manager é uma **hipótese a ser aferida experimentalmente em hardware real**, e não uma certeza estática de especificação.
2. **Notificação de Troca de Spaces:**
   - Observar [`NSWorkspace.activeSpaceDidChangeNotification`](https://developer.apple.com/documentation/appkit/nsworkspace/activespacedidchangenotification).
   - Esse evento é emitido pelo sistema operacional de forma reativa apenas no momento em que o usuário troca de Space virtual ou transita para um Space exclusivo de aplicativo em tela cheia, eliminando amostragem periódica de CPU em repouso.

---

## 5. Critérios de Aceitação e Definição de Conclusão (DoD)

Para orientar a validação das issues #7 e #8 quando implementadas, estabelecem-se os seguintes critérios:

| ID | Cenário | Critério de Aceitação |
| :--- | :--- | :--- |
| **AC-P01** | Validação de Embed | A URL de embed público (YouTube/Vimeo) é carregada com parâmetros de mudo e autoplay em `WKWebView`, com tratamento gracioso de falha caso o provedor bloqueie a exibição. |
| **AC-P02** | Pausa de Mídia Web | Ao pausar o Wallmotion via menu bar ou repouso de tela, `WKWebView.pauseAllMediaPlayback()` é invocado e o áudio/decodificação cessa imediatamente. |
| **AC-P03** | Tratamento de DRM/Auth | URLs que exijam login de conta Google ou DRM Widevine exibem mensagem explícita de formato não suportado, sem travamento do aplicativo. |
| **AC-P04** | Medição sem Sudo | O script de medição executa de ponta a ponta em terminal não privilegiado, gerando relatórios de `phys_footprint`, `%cpu` e assertions do `pmset`. |
| **AC-P05** | Supressão de Power Assertions | Durante a reprodução de vídeo/GIF em estado ativo, `pmset -g assertions` confirma que o Wallmotion não cria assertions `PreventUserIdleDisplaySleep` indesejadas. |
| **AC-P06** | Experimento de Oclusão | A notificação `didChangeOcclusionStateNotification` é testada em hardware real para verificar se o WindowServer sinaliza adequadamente a cobertura total da área de trabalho. |
| **AC-P07** | Orçamento Agregado de GIF | A atribuição simultânea de GIFs em múltiplos monitores é governada por cota compartilhada, alertando o usuário caso o consumo exceda o limite global definido. |

---
*Documento registrado em `docs/NEXT-PHASE.md` como diretriz técnica para as próximas etapas.*
