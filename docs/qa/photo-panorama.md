# Panorama de fotos — etapa da issue #43

O modo **Panorâmico (foto)** posiciona uma foto na união dos retângulos dos monitores em pontos AppKit, incluindo origens negativas, telas verticais e espaços. Cada janela recorta sua parte da mesma composição. Ajustar/Preencher preservam proporção; Esticar ocupa a união; Centralizar usa a maior escala de pixels conectada como referência comum, portanto não promete um pixel da foto por pixel físico em telas com escalas diferentes.

A preparação assíncrona usa o tamanho da união multiplicado pela maior escala conectada. Pedidos idênticos do mesmo lote compartilham um CGImage imutável; não há novo timer ou cache permanente. A identidade de reutilização inclui a união e a escala, para recalcular telas existentes após hotplug. As escolhas individuais continuam salvas e voltam ao modo separado. Limpar em panorama remove o fundo de todas as telas. Vídeos, GIFs e fontes web são rejeitados antes de persistir a seleção nesse modo.

A biblioteca migra v1/v2/v3 para v4 apenas em memória ao carregar. Os campos compartilhados mantêm seus nomes persistidos anteriores. A versão nova é necessária para leitores antigos rejeitarem um modo que não conhecem.

## Qualidade e memória

Mantém-se o teto conservador de 128 MiB por imagem preparada, estimado a 16 bytes por pixel com alinhamento de linha: cerca de 8 milhões de pixels, não 33 milhões. O bitmap real pode usar menos bytes por pixel. Várias telas de alta resolução podem exigir redução da imagem e perder detalhe fino. O teto não limita scratch do codec, composição do WindowServer ou RSS total; não garante ausência de falta de memória. Janelas/representações AppKit têm custos próprios mesmo compartilhando o CGImage.

## Evidências automatizadas

- Geometria com origens negativas, disposição vertical, lacunas e DPI misto nos quatro enquadramentos; entradas inválidas e overflow rejeitados.
- Ida e volta do estado, migração sem regravar JSON e preservação das escolhas individuais.
- Duas telas lógicas em uma sessão gráfica: um decode no lote, identidade CGImage compartilhada, recortes contínuos e recálculo da tela restante após desconexão.
- Mudança da união durante preparação e limpeza não publicam resultado obsoleto; vídeo rejeitado preserva os bytes salvos.
- Snapshot compacto claro com seletor de panorama e cabeçalho inspecionado; fixture temporária sem alterações na biblioteca do usuário.

## QA física pendente

- Duas telas reais com escalas diferentes, posições à esquerda/acima, lacunas e mudanças de resolução.
- Continuidade visual e nitidez nas quatro opções, incluindo fotos orientadas e perfis de cor diferentes; HDR/EDR não certificado.
- Medição de memória/energia com fotos grandes e conexão repetida de monitores.
- A issue #43 permanece aberta para esses checks e para mídia animada entre telas.
