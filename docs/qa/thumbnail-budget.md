# Miniaturas: dimensões e orçamento de saída

As dimensões de geometria são convertidas para pixels apenas depois de validar finitude/sinal e limitar o resultado a 4096. Escala inválida usa 1; dimensão inválida usa 1 pixel. Metadados de vídeo com dimensão transformada não finita ou menor que 1 são rejeitados antes de gerar o frame, sem conversão direta insegura para Int.

A resolução para aspect fill considera a proporção orientada e a área do card, depois reduz o maior eixo até uma estimativa de 8 MiB por bitmap a 16 Bpp, com o mesmo cálculo conservador de alinhamento das fotos de fundo. Mantém-se o teto de eixo de 4096 para recortes panorâmicos. ImageIO aplica orientação/reflexão e desabilita saída float. Após ImageIO/AVFoundation, largura/altura e bytesPerRow × height são validados antes de criar/cachear NSImage, conferindo divisão antes da multiplicação.

O limite reduz detalhe em cards muito grandes quando necessário; não altera a resolução do wallpaper. O NSCache mantém limite sugerido de 32 MiB e 256 entradas. Esse limite do NSCache é indicativo e não inclui imagens retidas pelas views. O teto de saída não limita memória temporária dos codecs, GPU, múltiplas gerações simultâneas ou RSS total. Controle de fila/deduplicação/cancelamento é uma etapa separada.

Checks: NaN/infinito/negativos/overflow de geometria, escala inválida, metadata extrema, cálculo de aspect fill abaixo/acima do teto, bitmap real acima do orçamento, JPEG grande orientado; a suíte existente verifica EXIF 6 em JPEG/HEIC e reflexão EXIF 2. QA de nitidez em Retina e rolagem com biblioteca extensa permanece pendente.
