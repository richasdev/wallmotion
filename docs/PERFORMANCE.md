# Relatório de Performance e Análise de Segurança Rust (#9)

## Coletor local por processo (#19)

`scripts/collect-performance.py` coleta snapshots de CPU, RSS e tempo do processo Wallmotion no macOS, sem privilégios. Informe o PID, o intervalo e a duração explicitamente. Para reproduzir uma coleta de 15 minutos a cada 5 segundos:

```sh
pgrep -x Wallmotion
python3 scripts/collect-performance.py --pid 12345 --interval 5 --duration 900 --format csv --output wallmotion.csv
```

Substitua `12345` pelo PID retornado por `pgrep` (ou pelo PID exibido no Activity Monitor). JSON pode ser selecionado com `--format json`. A saída JSON inclui os limites; em CSV, o relatório é escrito em stderr para manter o arquivo CSV legível. CPU vem de `ps %cpu` e pode exceder 100% em sistemas multicore; RSS é o residente amostrado convertido de KiB para bytes. A ferramenta não coleta GPU ou potência: `ps` não fornece aqui uma métrica por processo com unidade verificada. Amostras podem perder picos entre intervalos. O coletor valida que o PID existe, pertence ao usuário atual e é Wallmotion; não usa sudo nem acessa dados de outros processos.

Se o processo terminar ou ficar indisponível depois da validação inicial, o coletor grava as amostras já obtidas e inclui `status`/`termination_reason` no JSON ou nas colunas CSV. O código de saída `3` indica resultado parcial e duração não cumprida; `0` indica duração concluída, `2` indica argumentos ou PID inicial inválidos sem arquivo de saída, e `130` indica interrupção pelo usuário após gravar as amostras parciais.

Os testes de parsing e argumentos podem ser executados sem iniciar o app:

```sh
python3 -m unittest discover -s Tests -p 'test_collect_performance.py'
```

**Data:** Outubro de 2026  
**Autor:** Antigravity (Performance & Architecture Research Agent)  
**Destinatário:** Codex Coordenador & Equipe Wallmotion  
**Alvo:** Crate `crates/wallmotion-media` (Scanner GIF sem alocações)

---

## 1. Revisão de Segurança do Código Rust (`src/lib.rs`)

O crate `wallmotion-media` implementa um scanner de contêiner GIF estrutural de passagem única (*single-pass*), sem alocações de heap e sem decodificação dos fluxos de pixels comprimidos com LZW.

### 1.1 Análise de Limites de Memória (Bounds Checking)
- **Cursor e Fatiamento Seguro:** A estrutura interna `Cursor<'a>` manipula fatias de bytes (`&'a [u8]`) por meio de `take(length)`. Todas as operações calculam o índice final usando `position.checked_add(length).ok_or(GifError::Overflow)?` antes de invocar `self.bytes.get(position..end)`.
- **Prevenção de Pânico:** O método `get()` retorna `Option<&[u8]>`, mapeando falhas de leitura para `GifError::Truncated`. Não há indexação direta não verificada (`[]`), garantindo ausência de *panics* em entradas truncadas ou corrompidas.

### 1.2 Análise de Estouro Inteiro (Integer Overflow)
- **Tabelas de Cores:** O deslocamento `1usize.checked_shl(u32::from(packed & 7) + 1)` opera sobre valores garantidos no intervalo `0..=7`, resultando em potências de 2 até 256. A multiplicação por 3 para obter o tamanho em bytes usa `checked_mul(3)`, imune a estouros.
- **Limites de Tela e Canvas:** As coordenadas de sub-quadros (`left`, `top`, `frame_width`, `frame_height`) são lidas como inteiros de 16 bits convertidos para `u32`. As somas `left.checked_add(frame_width)` e `top.checked_add(frame_height)` utilizam aritmética checada e são validadas contra as dimensões lógicas do cabeçalho (`width`, `height`).
- **Estimativa de Memória Decodificada:** O cálculo em `decoded_size` multiplica `width * height * 4 * frames` utilizando inteiros de 64 bits (`u64`) encadeados via `checked_mul()`, retornando `GifError::Overflow` caso o produto exceda `u64::MAX`.

### 1.3 Análise de FFI (`wm_gif_probe`) e Apontamentos para o Coordenador

> [!WARNING]
> **Achado de Segurança FFI — Alinhamento de Ponteiro de Saída (`out`):**
> Na função FFI `wm_gif_probe`:
> ```rust
> pub unsafe extern "C" fn wm_gif_probe(bytes: *const u8, len: usize, out: *mut WMGifInfo) -> i32 {
>     if bytes.is_null() || out.is_null() || len > isize::MAX as usize {
>         return 1;
>     }
>     ...
>     unsafe {
>         out.write(WMGifInfo { ... });
>     }
> }
> ```
> A chamada `out.write(...)` da biblioteca padrão do Rust exige que o ponteiro `out` esteja devidamente alinhado para o tipo `WMGifInfo` (alinhamento de 8 bytes em plataformas de 64 bits devido ao campo `u64 decoded_bytes`). Se um chamador externo em C ou Swift passar um ponteiro desalinhado, a operação constitui Comportamento Indefinido (*Undefined Behavior*).
> 
> **Correção Recomendada ao Coordenador:**  
> Utilizar `core::ptr::write_unaligned(out, ...)` ou adicionar uma checagem explícita `if !out.is_aligned() { return 1; }` antes da escrita.

#### Observações sobre Especificação GIF89a:
1. **Rejeição Estrita de Quadros Fora do Canvas (`FrameOutsideCanvas`):**  
   O parser rejeita qualquer arquivo onde `left + width > canvas_width` ou `top + height > canvas_height`. Embora a especificação GIF89a permita que quadros excedam a tela lógica (sendo tipicamente recortados por navegadores e pelo AppKit), a postura restritiva adotada pelo crate é segura para fins de dimensionamento defensivo no Wallmotion.
2. **Faixa de Código LZW:**  
   A linha `141` valida `(2..=8).contains(&cursor.byte()?)`. Na especificação GIF, o tamanho inicial do código LZW varia entre 2 e 8 para imagens indexadas até 256 cores, cobrindo todo o espaço padrão.

---

## 2. Metodologia do Benchmark (`probe_bench`)

O utilitário CLI de benchmark foi criado em `crates/wallmotion-media/examples/probe_bench.rs` sem dependências externas adicionais, operando sobre a biblioteca padrão do Rust.

### Princípios Metodológicos:
1. **Isolamento de E/S:** O carregamento do arquivo em disco (ou alocação da fixture sintética em memória) é executado previamente, fora da janela de medição temporal.
2. **Prevenção de Otimizações Indesejadas do Compilador:** O ponteiro da fatia de entrada e o resultado retornado pelo parser são envelopados em chamadas de `std::hint::black_box`, impedindo que o LLVM elimine o loop ou pré-calcule o resultado estaticamente.
3. **Fase de Aquecimento (Warm-up):** Executam-se 100 iterações prévias para aquecer instruções no cache L1i da CPU e estabilizar a frequência operacional.
4. **Métricas Temporais Precisas:** Medição via `std::time::Instant`, coletando nanosegundos por varredura, calculando média, mediana (p50), percentil 95 (p95), valores mínimo/máximo e desvio padrão amostral.
5. **Omissão Consciente de Taxas de Transferência Fictícias:**  
   > [!IMPORTANT]
   > Não é exibido throughput em "GB/s" sobre o tamanho do arquivo em disco. Como o `probe_gif` salta os subblocos comprimidos sem executar a descompressão LZW, projetar uma taxa de transferência sobre o arquivo comprimido geraria um indicador distorcido e desprovido de valor técnico. O custo computacional do scanner é linear em função do **número de extensões e blocos estruturais** ($O(N)$), e não do volume de pixels codificados.

---

## 3. Ambiente e Resultados Experimentais Reais

### 3.1 Especificações do Hardware de Teste
- **Processador:** Apple M2 Pro (12 núcleos de computação)
- **Arquitetura:** `aarch64-apple-darwin` (ARM64)
- **Sistema Operacional:** macOS 27.0.1 (Build 26A434)
- **Compilador:** rustc 1.94.1 (e408947bf 2026-03-25, Edição 2024)
- **Perfil de Compilação:** `release` (`opt-level = 3`, `lto = true`, `codegen-units = 1`, `panic = "abort"`)

---

### 3.2 Cenário 1: Fixture Sintética — 120 Frames (1920x1080)
- **Parâmetros:** Resolução 1920x1080, 120 quadros sintéticos (simulando 2 segundos de animação a 60 fps).
- **Volume Estrutural em Memória:** 2.780 bytes.
- **Estimativa de Memória Descompactada (RGBA):** 995.328.000 bytes (~949,22 MB).
- **Amostragem:** 10.000 iterações cronometradas consecutivas.

| Métrica | Valor na Execução de Referência | Re-execução Isolada (Menor Carga) |
| :--- | :--- | :--- |
| **Tempo Total Acumulado** | **50,460 ms (10k scans)** | **~25,9 ms (10k scans)** |
| **Média por Scan** | **4.998,4 ns (~5,00 µs)** | **2.591,9 ns (~2,59 µs)** |
| **Mediana (p50)** | **4.625 ns (~4,63 µs)** | **2.541 ns (~2,54 µs)** |
| **Percentil 95 (p95)** | **7.000 ns (~7,00 µs)** | **2.917 ns (~2,92 µs)** |
| **Mínimo** | **3.667 ns** | **~2.300 ns** |
| **Máximo** | **214.208 ns** | **~15.000 ns** |
| **Desvio Padrão** | **3.268,1 ns** | **~420 ns** |

> [!NOTE]
> **Variação por Carga de Sistema:** Os números em nanossegundos variam conforme o estado térmico dos núcleos de eficiência/performance e a carga concorrente de processos do sistema (como compilações paralelas). O objetivo do benchmark não é fixar um número absoluto imutável, mas comprovar que o custo do scanner permanece na ordem de unidades baixas de microssegundos por verificação.

---

### 3.3 Cenário 2: Fixture Sintética de Carga Elevada — 500 Frames (1920x1080)
- **Parâmetros:** Resolução 1920x1080, 500 quadros sintéticos.
- **Volume Estrutural em Memória:** 11.520 bytes.
- **Estimativa de Memória Descompactada (RGBA):** 4.147.200.000 bytes (~3.955,08 MB).
- **Amostragem:** 5.000 iterações cronometradas consecutivas.

| Métrica | Valor Medido |
| :--- | :--- |
| **Tempo Total Acumulado (5.000 scans)** | **52,006 ms** |
| **Média por Scan** | **10.377,7 ns (~10,38 µs)** |
| **Mediana (p50)** | **10.250 ns (~10,25 µs)** |
| **Percentil 95 (p95)** | **10.875 ns (~10,88 µs)** |
| **Mínimo** | **9.709 ns (~9,71 µs)** |
| **Máximo** | **31.208 ns (~31,21 µs)** |
| **Desvio Padrão** | **1.170,4 ns** |

---

## 4. Limitações e Fronteiras desta Avaliação

1. **Ausência de Comparativo com Swift:**  
   Nenhum teste de desempenho relativo frente ao AppKit ou implementação pura em Swift foi realizado nesta fase. Portanto, **não se deve declarar superioridade de velocidade do parser Rust frente ao ecossistema Swift** até que um *benchmark* sob as mesmas condições e entradas idênticas seja executado.
2. **Escopo Estrito de Validação Estrutural:**  
   O scanner atesta unicamente a integridade dos cabeçalhos, extensões, tabelas e terminação de subblocos. Ele **não valida se os bytes de dados LZW contêm quadros de imagem visualmente íntegros**, não substituindo o decodificador final do sistema no momento da exibição na tela.
3. **Comportamento sob Memória Real do Sistema:**  
   A estimativa de memória decodificada (ex.: ~949 MB para 120 quadros a 1080p) reflete o custo matemático da projeção de quadros integrais em RGBA (4 bytes por pixel). Como o AppKit pode otimizar a retenção descartando quadros anteriores ou mantendo caches intermediários de `CGImage`, a alocação de memória residente real do app deve ser perfilada separadamente via Instruments Allocations.

---

## 5. Parecer Arquitetural: Escopo de Backend (Rust vs. Swift/SwiftUI)

Avaliou-se a hipótese de migrar 100% do backend para Rust, mantendo apenas a interface visual em SwiftUI.

### Conclusão e Diretriz para o Coordenador:
1. **100% Rust é Desaconselhado:**  
   No macOS, a orquestração de vídeo e desktop depende de APIs profundamente integradas ao runtime da Apple (`AVQueuePlayer`, `AVPlayerLooper`, `AVPlayerLayer`, `NSWindow`, `kCGDesktopWindowLevelKey`, `NSScreen`, `NSWorkspace`).  
   - Chamar essas estruturas a partir de Rust via `objc2` introduziria centenas de linhas de código inseguro (`unsafe`), chamadas manuais de `objc_msgSend` e alta fricção de FFI com o framework reativo `@Observable` do SwiftUI.
   - **Performance:** A descompressão de vídeo já é despachada pelo AVFoundation diretamente para os aceleradores de hardware dedicados (*Apple Silicon Media Engine*). O Swift compila via LLVM para código nativo com ARC, tendo overhead irrelevante para despacho de janelas e estado.

2. **Manter a Arquitetura Híbrida Pragmática:**
   - **Rust (`crates/wallmotion-media`):** Especializado em tarefas de baixo nível onde segurança de memória e ausência de pânico auxiliam na contenção de falhas — pré-inspeção e validação de containers não confiáveis (`probe_gif`/`wm_gif_probe`), detecção de anomalias estruturais antes de tocar no decodificador do sistema, e futuras operações intensivas de CPU/hashing.
   - **Swift (`Sources/WallmotionCore` e `Sources/Wallmotion`):** Orquestração do ciclo de vida, janelas desktop (`DesktopCoordinator`), pipeline de renderização acelerado por hardware e interface SwiftUI.

*Esta decisão foi registrada no `ai-memory` do workspace (`richasdev-wallmotion`) sob a tag `architecture/backend-rust-swiftui-division`.*

---
*Relatório registrado em `docs/PERFORMANCE.md` para apreciação da equipe de engenharia.*
