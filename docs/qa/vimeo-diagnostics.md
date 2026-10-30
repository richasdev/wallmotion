# Diagnóstico de incorporação web (#42)

Na sessão de2026-10-31/JST, a amostra pública19231868 citada no [SDK oficial Vimeo](https://github.com/vimeo/player.js) passou no teste real: confirmação de reprodução, mudo, volume25%, pausa e descarte/stop. É homologação básica desse caso e ambiente; não certifica todos os vídeos, reconexão ou energia sustentada.

O exemplo76979871 falhou com PlaybackError com e sem hash8272103f6e publicado no README. Metadata oEmbed retornou200, o que não comprova que o player consiga tocar o vídeo. O exemplo59777392 retornou PrivacyError. Acrescentar encrypted-media ao allow do iframe e prefer_mms=0 em testes controlados não resolveu76979871; esses experimentos foram revertidos. Não atribuir a falha genericamente a CSP, hash, origem ou autoplay sem prova. Regras de navegação/CSP permanecem.

A interface distingue categorias públicas do provedor e oferece abrir o link canônico no navegador por ação explícita do usuário. PlaybackError não recebe uma causa inventada. Descrições arbitrárias do SDK e NSError, URLs e hashes não são reproduzidos no erro; o evento de diagnóstico conserva somente identificador conhecido. O banner usa texto semântico legível e quebra de linhas.

Teste manual: fonte pública válida; URL não listada completa; vídeo privado/com senha/bloqueado para incorporação; rede ausente e certificado inválido; confirmar mensagem e botão de abrir no navegador. Não preencher senha nem burlar restrições. A issue42 permanece aberta para casos não listados e resiliência/QA adicionais.

Reprodução pública: WALLMOTION_WEB_TEST_URL=https://vimeo.com/19231868 swift test -j2 --filter testOptInOfficialEmbedPlaysMutedAndStops. Falhas dos demais exemplos devem ser registradas como falhas, sem skip automático por retorno do provedor. Testes unitários offline cobrem redaction e categorias; não substituem rede real.
