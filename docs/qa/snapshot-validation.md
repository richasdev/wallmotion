# Validação preventiva das capturas — issue #67

A fixture de LibraryView passa a verificar conteúdo, além de dimensões. Ela aguarda layout/display, faz flush das transações de camada e captura com cacheDisplay. O helper exige pelo menos três grupos de cores amostrados numa grade32×24, com tolerância0.03 por componente e alpha acima de0.1. Capturas sem essa variação são repetidas a cada50ms até o prazo de3s; o tempo limita as tentativas, não interrompe uma chamada nativa de desenho. Task.sleep suspende a tarefa e libera MainActor para outras atualizações, sem RunLoop.run bloqueante dentro de async.

Pools de autorelease cercam captura e inspeção de cores. O pequeno aquecimento de250ms da fixture permite iniciar tarefas de miniaturas, mas não é condição de aprovação por si só. Cancelamento é verificado antes das tentativas. Erro ao capturar ou falta de variação gera falha explícita antes de gravar o PNG. A imagem heterogênea é condição necessária dessa fixture colorida, sem certificar que todos os componentes terminaram de desenhar ou que o resultado visual esteja correto. A inspeção humana continua necessária.

## Retificação da observação inicial

Não foi reproduzida uma captura vazia nos arquivos originais. Os PNGs/tmp/wallmotion-thumbnail-queue.png e queue-only.png continham1870 cores; o artefato de validação posterior continha1619. A ferramenta de visualização retornava data:application/octet-stream; encaminhar os mesmos bytes como data:image/png exibiu o conteúdo corretamente. Portanto, a hipótese de falha de NSHostingView sob carga não foi comprovada. O PR da fila e a issue foram retificados. Esta alteração é endurecimento preventivo do QA, não correção de um defeito observado no app.

## Checks

Fixtures sintéticas RGBA por bytes verificam rejeição de uma cor/alpha transparente, aceitação de três regiões, retry até conteúdo, expiração e cancelamento. Usar bytes evita depender de NSColor nomeada ao preencher buffers de teste. A captura real usa apenas biblioteca temporária e janela fora da tela, sem arquivos do usuário.

Para visualizar via ferramenta que retorna MIME genérico, conservar os bytes e indicar image/png ao encaminhar a imagem; isso não exige editar o PNG nem mudar seu perfil de cor. O perfil do display continua no artefato exportado.
