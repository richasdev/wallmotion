# Resolução da revisão — Codex

Os pareceres do Antigravity são análise independente de snapshots anteriores; as linhas podem mudar. Esta página registra a decisão do coordenador sobre cada achado e a evidência executada.

| Achado inicial | Tratamento |
| --- | --- |
| BUG-01: aspect fit | Escolha de exibição documentada, sem distorção da proporção. Possíveis faixas não são tratadas como falha de decodificação. Fill/fit selecionável pode ser evolução de UX. |
| BUG-02: fullscreen | Desktop Spaces são o escopo inicial; fullscreen/Stage Manager ficam em QA. Evitar renderização adicional em Spaces dedicados é coerente com a prioridade de energia. |
| BUG-03: observers no template | Corrigido: observar o item ativo do player e atualizar o observer em cada troca, incluindo clones do looper. |
| BUG-04: fim de mídia remota | AVPlayer simples para remoto; falha de seek gera erro visível e recarga manual. A suposta frequência de falha de seek não foi medida. |
| BUG-05: UUID ausente | Fallback para ID numérico, com estabilidade limitada à sessão documentada. |
| BUG-06: recriação no wake | Corrigido: eventos de wake/unlock reaplicam política. Reconciliação preserva renderizadores com a mesma mídia/geometria. |
| BUG-07: layer/player | Desvinculação explícita no stop adicionada e testada. Vazamento anterior de VRAM não foi demonstrado por profiler. |
| BUG-08: URL raiz | Título usa hostname, coberto por teste. |
| RISK-01: gravações por arquivo | Importação copia em background, acumula resultados e persiste o lote uma vez, preservando edições concorrentes da UI. |
| RISK-02: rede/HLS | AVFoundation controla buffering; falhas têm erro e ação de recarga. Reconexão de streams reais requer QA e não está certificada. |

## Rust e memória

- Scanner Rust ligado estaticamente ao app via ABI C, sem processo auxiliar.
- Dados GIF mapeados para análise estrutural; não há decodificação LZW no scanner.
- Estimativa conservadora de frames limita GIFs a 256 MiB por mídia. Não é um limite de RAM total.
- Ponteiro de saída FFI agora também é verificado quanto ao alinhamento, além do contrato de propriedade e validade do chamador.
- Benchmark rejeita zero iterações e limites excessivos antes da alocação de amostras/frames.
- Fotos são decodificadas com thumbnail ImageIO para o tamanho do display.

## Evidências e limites

Testes locais cobrem vídeo H.264 real, loop, pausa, fotos/GIFs, preservação de janelas, dados corrompidos, importação e ABI Swift/Rust. O teste de troca entre dois monitores é ignorado quando existe apenas uma tela. Snapshot da biblioteca usa fixtures temporárias; não contém dados do usuário.

Build release gerou `dist/Wallmotion.app`, com Info.plist validado e assinatura ad-hoc verificada. O app abriu e permaneceu em execução. Não foram medidos consumo sustentado de energia, GPU, compatibilidade Intel, Stage Manager ou reconexão de HLS ao vivo.

O GitHub Actions foi impedido de iniciar pelo limite de cobrança da conta; evidência e resolução estão na issue #11. Os checks equivalentes foram executados localmente. Não se deve declarar CI remoto aprovado.

Teste remoto opt-in com o HLS VOD de exemplo oficial da Apple passou em 3,5 s: AVPlayer pronto, tempo avançando, áudio mudo, pausa e descarte. Fonte do exemplo: https://developer.apple.com/streaming/examples/advanced-stream-hevc.html . Isso não certifica URLs arbitrárias, live ou reconexão.
