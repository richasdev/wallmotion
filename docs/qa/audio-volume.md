# Volume do fundo (#45, primeira entrega)

Volume global persistido no PlaybackSettings em 0...1, padrão1 preservando ganho das bibliotecas anteriores. AudioDisplayID continua nil por padrão: importar, restaurar ou migrar não ativa som. JSON inválido, valores não finitos ou fora da faixa não chegam ao player. Volume0 mantém mute efetivo.

O slider usa um rascunho local e salva após soltar/200ms sem edição, evitando escrita da biblioteca a cada pixel. Menu da barra oferece0/25/50/75/100%. A política de ganho é atualizada sem substituir AVPlayer, seek ou reinício do transporte. O monitor com áudio permanece único; pausa, oclusão e stop mantêm mute imediato.

YouTube aplica setVolume antes de unMute. Vimeo serializa promessas de mudança de volume e descarta permissões antigas de unmute por geração. Pedidos idênticos não reenviam comandos JS; descarte da WKWebView limpa esse controle. SDKs e autoplay continuam sujeitos ao provedor; Vimeo real ainda não está homologado (#42).

Testes: migração sem ganho explícito, roundtrip, rejeição de NaN/Infinity/faixa inválida, falha ao salvar preservando volume, AVPlayer sem seek e com volume0/pausa/oclusão, script YouTube com ordem de volume/mute, promessas Vimeo atrasadas e ganho mais recente, WKWebView pronta e recriada preservando política. Esses testes de scripts usam stubs de SDK e não certificam o provedor real.

Pendentes da issue45: mixer/ganho por fonte e estudo de rampas. Não se introduziu fade em pausa/oclusão, pois o áudio precisa parar imediatamente quando a política o bloqueia. Nenhum timer permanente ou polling foi adicionado. QA auditivo físico para estalos, diferentes dispositivos de saída e escalas de volume permanece necessário; não afirmar eliminação de estalos sem essa medição.
