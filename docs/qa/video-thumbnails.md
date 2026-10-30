# Miniaturas de vídeo local — etapa da issue #63

A fixture H.264 usada pelos testes de renderização passa a ser compartilhada com os testes de thumbnails. Gera um MP4 temporário de32×16, três frames e um segundo, com opção de rotação. Nenhuma URL externa ou biblioteca do usuário é usada.

O teste com AVAssetImageGenerator real verifica saída16×32 para vídeo rotacionado, custo de bitmap aceito e drenagem do scheduler. Outro teste inicia uma operação nativa, cancela o assinante, aguarda active/pending/subscribers zerarem e solicita uma nova dimensão do mesmo vídeo; a nova miniatura precisa concluir. O ensaio observado retornou subscriber-cancelled, drained=true e subsequent_native_frame=true.

A expectativa de entrada antecede a chamada do gerador; não fixa em qual fase do SDK o cancelamento chega. Conclusão que vença essa corrida é permitida. Portanto, não se prova cancelamento durante um frame específico, corte instantâneo do codec, retorno de RSS à linha de base ou comportamento em todos os formatos. O contrato público da [Apple para cancelAllCGImageGeneration](https://developer.apple.com/documentation/avfoundation/avassetimagegenerator/cancelallcgimagegeneration()) trata pedidos de imagem pendentes; não se presume código numérico específico de NSError.

O gerador agora rejeita URL não local antes de construir o asset, incluindo host remoto em fileURL, e verifica cancelamento novamente depois de carregar metadados antes de solicitar a imagem. Isso se aplica à prévia de arquivos; os renderizadores de vídeos remotos e embeds têm seus próprios caminhos. O teste verifica erro específico de prévia indisponível para as fontes não locais.

Reproduzir: `swift test -j 2 --filter VideoThumbnailTests`, após `sh scripts/build-native.sh`. A fixture pode pular quando o encoder H.264 estiver indisponível. Os testes de renderização existentes continuam usando o mesmo helper.

A issue #63 permanece aberta para rolagem/redimensionamento reais, vídeos grandes e codecs variados, medições de memória/CPU do app e energia em hardware.
