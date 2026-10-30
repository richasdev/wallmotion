# Arquivos de mídia gerenciados — issue #58

Novas importações abrem a origem com `O_NOFOLLOW | O_NONBLOCK`, validam arquivo regular por descritor e criam destino UUID com `openat(... O_EXCL ..., 0600)` dentro de Media. Novas pastas Media usam modo 0700; pastas e arquivos já existentes não recebem chmod em lote. A cópia usa `fcopyfile(DATA | XATTR)` sem importar modo ou ACL da origem, preservando atributos como quarentena conforme normalização do macOS. `fchmod` opera no descritor da cópia, sem alterar o original. O manual primário da [Apple para copyfile/fcopyfile](https://github.com/apple-oss-distributions/copyfile/blob/main/copyfile.3) descreve os flags de dados, atributos e metadados.

Media é aberto relativo ao descritor da raiz e rejeita symlink no seu componente final. Resolução verifica o componente final sem seguir symlinks e rejeita arquivos especiais; arquivo ausente mantém a URL para o tratamento normal de mídia removida. Exclusão usa `unlinkat` relativo ao diretório aberto: substituir a entrada por um symlink não faz a exclusão seguir seu alvo. Uma cópia incompleta é removida nesse mesmo diretório. Ao concluir a cópia, a identidade do diretório atual é conferida antes de publicar o item.

GIFs são inspecionados pelo scanner Rust no descritor antes e depois da cópia, sem reabrir o nome da origem. O mapeamento não aloca uma cópia completa do arquivo em Data. Isso não torna o arquivo imutável: truncamento concorrente de um arquivo mapeado pode causar SIGBUS e precisa de tratamento em uma etapa própria para o preflight de URLs e descritores.

## Limites explícitos

- 0600/0700 são permissões por usuário, não isolamento por processo. Outros programas da mesma conta e administradores ainda podem alterar arquivos.
- ACLs herdadas do diretório não são certificadas por uma comparação dos bits POSIX. Não são copiadas ACLs da origem, mas não há promessa de acesso exclusivo do processo.
- A raiz configurada e seus ancestrais podem conter links; a política fixa o componente Media aberto durante a operação, não todos os ancestrais permanentemente.
- AppKit/AVFoundation recebem uma URL após a validação. Troca posterior de nós ainda tem janela TOCTOU. Hardlinks regulares também não revelam a procedência do inode.
- A cópia por descritores não usa clone APFS. Há custo de cópia dos bytes e, para GIF, duas inspeções estruturais. Não há alegação de ganho de velocidade/energia sem medição.
- Falha em cópia/atributos/preflight aborta a importação e remove o destino incompleto; a origem é preservada. Alterações simultâneas do conteúdo da origem não constituem snapshot consistente garantido.

## Verificação

Fixtures temporárias verificam modo 0777 da origem preservado e 0600 na cópia, bytes iguais e marcador de quarentena retido (o macOS normaliza campos desse atributo). Também verificam rejeição de Media como link externo, symlink local normal/quebrado e FIFO, sem modificar os alvos externos. A suíte anterior cobre importação, rollback, orçamentos GIF e limpeza das cópias gerenciadas.
