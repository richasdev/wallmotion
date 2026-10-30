# Fila de miniaturas — etapa da issue #63

A biblioteca passa os pedidos a um actor com até quatro decoders ativos. Pedidos idênticos em voo (URL, tipo e dimensões) compartilham um CGImage. Cada view tem sua própria assinatura: cancelar uma view não cancela as demais. Sem assinantes, o pedido sai da fila ou solicita cancelamento do worker. Se o codec nativo ainda estiver trabalhando, ele mantém o slot até retornar; um pedido posterior da mesma chave usa uma geração nova. Resultados ou erros de uma view cancelada não sobrescrevem sua miniatura atual.

A fila não guarda outro cache de imagens. O NSCache existente e seu limite indicativo continuam separados; a quantidade de pedidos pendentes acompanha as assinaturas das views, sem promessa de teto de RSS. Cancelamento é cooperativo: não interrompe uma chamada síncrona do ImageIO já em andamento. AVAssetImageGenerator recebe cancelAllCGImageGeneration quando seu último consumidor desaparece.

## Medição anterior à mudança

Antes de implementar a fila, o commit d97bb9c adicionou um harness opt-in com 48 pedidos distintos, uma fixture JPEG temporária de2048×1024 e thumbnails próximas de440×236. O padrão anterior com uma Task.detached por pedido chegou a12 decoders ativos,14.022ms de wall time e151.63ms de CPU do processo. Log:/tmp/wallmotion-thumbnail-baseline-cpu.log.

O ensaio modela uma rajada do decoder e ignora o NSCache. Não mede rolagem real do SwiftUI, memória residente, GPU, vídeo ou energia. A fonte é aquecida antes da rodada. Outras atividades da máquina podem influenciar a duração.

## Comparação no mesmo harness

M2 Pro/macOS27.0.1; cada linha completa48 pedidos. O modo sem limite foi medido antes e depois das duas opções para expor variação de ordem/cache.

| Política | Pico de decoders | Wall time | CPU do processo |
| --- | ---: | ---: | ---: |
| Sem fila, antes |12|14.472ms|147.711ms|
| Limite2 |2|58.841ms|168.132ms|
| Limite4 |4|30.106ms|145.320ms|
| Sem fila, depois |12|13.331ms|146.757ms|

O padrão4 reduz o pico de trabalho paralelo nesse cenário e conclui o lote antes do limite2. O lote fica mais lento que no modo sem limite. Não se infere ganho geral de velocidade, reserva de núcleos para a interface, redução de RSS ou autonomia de bateria desses números. Log:/tmp/wallmotion-thumbnail-queue-comparison.log.

Reproduzir: `WALLMOTION_THUMBNAIL_STRESS=1 swift test -j 2 --filter ThumbnailStressTests`, após `sh scripts/build-native.sh`. Fora desse opt-in o ensaio é pulado. As fixtures são temporárias e não acessam a biblioteca do usuário.

## Checks e pendências

Testes determinísticos cobrem teto de concorrência, deduplicação, cancelamento de um assinante, descarte na fila, codec que ignora cancelamento, reentrada da mesma chave, erro distribuído e liberação de slots. A suíte inclui orientação e orçamento de miniaturas, além do snapshot compacto.

Permanecem pendentes medir rolagem/redimensionamento reais com biblioteca extensa, cancelamento e throughput de AVAssetImageGenerator em vídeos locais, custo de CPU/RSS sob essas condições e energia no hardware. A issue #63 permanece aberta para essas medições.
