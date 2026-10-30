# Preflight de GIF sem mapeamento — issue #59

O parser estrutural Rust compartilha a mesma gramática entre bytes em memória e arquivos. Para arquivos regulares, usa read-ahead de 8192 bytes, pread e offsets checados; paletas e payloads comprimidos são pulados sem decodificar LZW. O tamanho capturado inicialmente limita a travessia, sem perseguir bytes adicionados depois. O limite estimado de frames permanece 256 MiB por GIF e o orçamento de reprodução continua separado.

A entrada FFI por descritor duplica um FD válido e aberto durante a chamada, fecha a duplicata ao retornar e preserva o offset do chamador. Ponteiro de saída precisa ser alinhado e gravável; somente sucesso o altera. EOF, erro de leitura e estrutura inválida retornam erro controlado; EINTR é repetido e short reads são consumidos antes de assumir EOF. Swift passa tanto URLs locais abertas sem seguir symlink final como os descritores usados na importação para essa entrada.

Não há mmap nem Data de tamanho igual ao arquivo nesses caminhos. Isso elimina a exposição do scanner a SIGBUS por páginas mapeadas truncadas. O buffer é de 8 KiB; esse número não limita RSS, buffers do sistema, AppKit ou decodificação de pixels. A API que aceita Data em memória ainda depende de o chamador fornecer bytes válidos durante a chamada.

## Concorrência e limites

Bytes já lidos podem continuar sendo processados após uma alteração no disco. Não se promete detectar toda mutação, obter snapshot coerente ou validar LZW. O corte que atinja uma leitura necessária é tratado como EOF. Um arquivo cheio de extensões ainda demanda trabalho proporcional aos blocos visitados; não há deadline de wall-clock ou prova de energia menor. A abertura/leitura de volumes lentos pode demorar. Os decodificadores de exibição continuam sendo fornecidos pelo macOS.

## Checks

- Paridade arquivo/bytes em cada prefixo truncado, enquadramento de paletas/subblocos e rejeição antecipada por orçamento.
- Truncamento determinístico após metadata e após preencher o buffer; short read com cabeçalho ainda completo e EOF seguinte.
- Cadeias maiores que 8 KiB, crescimento após metadata e preservação de offset/FD original.
- Output FFI preservado no erro de leitura, truncamento e excesso de orçamento.
- Integração Swift: URL/bytes equivalentes, FD/offset, symlink e FIFO sem bloquear; regressões de importação e orçamento do app.

## Microbenchmark reproduzível

`CARGO_INCREMENTAL=0 cargo run --release --manifest-path crates/wallmotion-media/Cargo.toml --target-dir .build/native --example probe_file_bench -- 10000`

Fixture temporária de 120 frames 1×1, 100 aquecimentos e iterações pareadas alternando ordem. Compara o scanner de slice com a entrada FFI por FD (dup + metadata + pread), em cache aquecido. Coleta p50/p95; exclui cópia/importação, cache frio, GPU, decodificação e RSS do app. Não compara Rust com Swift e não representa energia do aplicativo.
