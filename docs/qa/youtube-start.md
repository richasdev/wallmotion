# Tempo inicial do YouTube (#52)

A importação preserva t em segundos, t em horas/minutos/segundos ordenados, start inteiro e fragmento #t. A URL canônica usa t em segundos, a biblioteca persiste startSeconds e o título distingue pontos iniciais diferentes. Bibliotecas anteriores sem esse campo começam em0; IDs, hashes e restrições de origem continuam validados.

O parser recusa mais de uma forma de timestamp, chaves duplicadas, valores vazios/nulos, caracteres fora de ASCII numérico/unidades h/m/s, unidades repetidas ou fora de ordem, valores negativos/fracionários e overflow. URLs são limitadas a4096 bytes. Tempo máximo representável é Int32.max segundos; não se promete que o vídeo/provedor aceite uma posição além da duração real. Offsets de Vimeo não fazem parte desta entrega.

O renderer envia apenas start inteiro ao iframe oficial, mantendo CSP e controles de áudio. Segundo a [documentação oficial](https://developers.google.com/youtube/player_parameters#start), o início pode cair no keyframe anterior (aproximadamente até2segundos). Não é corte de segmento nem garantia de loop a partir do ponto; autoplay, live, duração e incorporação dependem do provedor. Ao descartar/recriar a view por pausa, o ponto inicial é usado novamente.

Verificar: formatos e overflow offline, roundtrip JSON/canonicalURL, migração sem campo e documento com start numérico. Teste de rede opt-in com WALLMOTION_WEB_TEST_URL=https://www.youtube.com/watch?v=M7lc1UVf-VE&t=10 observa player.getCurrentTime>=8 e volume25% ainda mudo. Rede e Vimeo não homologados devem ser registrados como limites reais, nunca convertidos em sucesso presumido.
