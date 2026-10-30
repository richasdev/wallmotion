# Fotos preparadas fora da interface (#46)

O caminho de produção `LibraryModel.refreshPlayback` usa `scheduleRebuild`. Fotos que precisam de novo renderer são preparadas no executor serial compartilhado de `PhotoDecodeWorker`; AppKit e NSImage continuam na MainActor. O caminho síncrono de construção permanece disponível para testes unitários dos renderers e não é usado para decodificar fotos pelo modelo de produção.

ImageIO recebe limite de pixels, orientação EXIF e orçamento conservador de saída de 128 MiB por foto. Não é limite total de RSS nem da memória temporária do codec. Fotos iguais com o mesmo pedido de pixels compartilham o CGImage dentro de um lote, sem cache permanente ou reutilização entre arquivos que foram alterados.

Um novo pedido cancela a publicação do anterior. Cancelamento é cooperativo antes e depois de ImageIO e antes de publicar; não interrompe uma chamada de codec já em andamento. O executor serial evita sobreposição de decodificações na produção. Cada foto conserva as dimensões originais orientadas para Centralizar, independentemente do tamanho do bitmap reduzido.

As janelas anteriores permanecem enquanto o lote carrega. O swap ocorre sem fade nem animação contínua. A pausa mais recente é aplicada no commit. Limpar/remover um fundo, desconectar um monitor ou encerrar o modelo cancela a publicação e encerra as janelas removidas. Falha preserva o renderer anterior e o orçamento; não promete rollback atômico de todos os monitores. Outros novos renderers do mesmo lote podem aguardar a preparação das fotos.

Validação automatizada: orientação e limite de saída, execução do worker a partir da MainActor, cancelamento após codec, lote substituído, callback mais recente, compartilhamento dentro do lote, stop terminal, janela anterior durante carregamento, pausa tardia e limpeza durante carregamento. Monitores lógicos não homologam hotplug físico.

QA manual pendente: importar foto de alta resolução; interagir com busca/redimensionamento durante carregamento; trocar rapidamente foto/ajuste; pausar, limpar, remover e reconectar monitor durante o decode; comparar Centralizar em Retina e tela externa; medir latência da UI, RSS e energia com o protocolo #8. Não declarar ganho percentual sem medição sustentada.
