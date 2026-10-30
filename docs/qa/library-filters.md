# Consulta da biblioteca — issue #65

A grade combina busca por título com tipo de mídia: Todas, Fotos, GIFs, Vídeos e Web. Vídeos inclui arquivos locais e URLs diretas; Web reúne embeds YouTube/Vimeo. A busca ignora caixa, acentos e diferenças de largura Unicode, com remoção de espaços nas extremidades.

A ordenação inicia em Mais recentes; Título (A–Z) usa comparação natural localizada; Tipo agrupa Foto, GIF, Vídeo e Web e depois ordena por título. Empates terminam em UUID para estabilidade. Consulta e ordenação são projeções: a ordem do JSON e as atribuições aos monitores permanecem salvas. Preferências de consulta são locais à janela/sessão. Atualizações de playback/volume com a mesma lista e consulta reaproveitam a projeção calculada, sem ordenar novamente.

Os controles usam segmentos quando cabem e menu como fallback, além de menu de ordenação e contagem de resultados. Nenhum resultado oferece ação para limpar busca/tipo. O cabeçalho do fundo aplicado continua visível mesmo quando esse item não corresponde à consulta. Importação e remoção invalidam a projeção.

Testes cobrem classificação Web separada de vídeo, busca combinada e acentos, ordenação/números/desempate, preservação dos bytes JSON com encoder determinístico e atualização da projeção após alterar título, importar, remover e mudar consulta. Snapshots temporários verificam layout compacto claro/escuro, foto filtrada e estado vazio; não certificam VoiceOver, contraste em todo hardware ou desempenho com biblioteca extensa.
