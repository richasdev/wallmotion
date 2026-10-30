# Escopo da limpeza — issue #71

O cleaner valida todos os alvos antes de chamar qualquer ferramenta: pastas .build, native e target duplicado, seus componentes dentro do projeto e os manifests necessários. Links simbólicos normais/quebrados, tipos inesperados ou marcadores ausentes geram recusa. Diretórios existentes são conferidos por pwd -P e prefixo da raiz física. Os scripts de entrada removem CDPATH do próprio processo antes de ancorar o checkout, evitando que a busca de diretórios do shell selecione outro projeto.

Cargo recebe target-dir explícito. No modo completo, Swift recebe scratch-path .build e o processo do script remove SWIFTPM_BUILD_DIR antes de chamá-lo. Foi reproduzido com as ferramentas locais que essa variável podia vencer até o argumento explícito de scratch e limpar outro destino; apenas passar a flag não era suficiente. O ambiente do shell chamador não é alterado quando o script é executado conforme documentado com sh.

Sem --all, o target Rust dev é limpo e a biblioteca release usada pelo Swift é preservada. Com --all, builds release/Swift também são limpos. dist/Wallmotion.app permanece preservado. A proteção não limpa caches globais nem builds externos configurados pelo usuário e não constitui sandbox contra substituições concorrentes por outro processo da mesma conta após a pré-validação.

## Reproduções e checks

A versão anterior foi executada somente em uma árvore temporária controlada: .build apontava para uma pasta irmã, e cargo clean removeu o arquivo sentinel externo ao checkout. Nenhum arquivo do usuário participou do ensaio.

A regressão usa mocks para comprovar recusa antes de invocar ferramentas, incluindo symlinks quebrados/ancestrais/manifests/pasta do script, argumentos inválidos e paths com espaços. Todos os scripts são exercitados com CDPATH adverso e o primeiro comando precisa usar a raiz solicitada. A integração com Cargo/Swift reais usa um pacote mínimo temporário e confirma: symlink recusado, debug próprio removido, release preservado no modo padrão, scratch externo preservado mesmo com SWIFTPM_BUILD_DIR definido e app empacotado mantido.

Executar: `python3 -m unittest discover -s Tests -p 'test_clean_builds.py'`. O teste real pula se Cargo ou Swift não estiverem disponíveis. scripts/check.sh executa todos os testes Python antes da suíte Swift e limita a compilação Swift a dois jobs; run.sh usa o mesmo limite.
