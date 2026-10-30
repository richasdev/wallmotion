use std::env;
use std::fs;
use std::hint::black_box;
use std::path::Path;
use std::process;
use std::time::Instant;
use wallmotion_media::{probe_gif, GifInfo};

/// Gera um container GIF estruturalmente válido sem depender de arquivos em disco.
///
/// NOTA DE ARQUITETURA: Este GIF possui cabeçalhos, extensões de controle gráfico,
/// descritores de imagem e blocos de dados sintéticos válidos conforme a especificação GIF89a.
/// O parser `probe_gif` inspeciona a estrutura do container e pula os subblocos de dados,
/// validando dimensões e limites de canvas sem executar a descompressão LZW dos pixels.
fn generate_synthetic_gif(width: u16, height: u16, frames: u32) -> Vec<u8> {
    let mut data = Vec::with_capacity(19 + (frames as usize * 24) + 1);
    // Header GIF89a (6 bytes)
    data.extend_from_slice(b"GIF89a");
    // Logical Screen Descriptor (7 bytes)
    data.extend_from_slice(&width.to_le_bytes());
    data.extend_from_slice(&height.to_le_bytes());
    data.push(0x80); // Global Color Table Flag (1 bit), 2 cores (3 bits)
    data.push(0x00); // Background Color Index
    data.push(0x00); // Pixel Aspect Ratio
    // Global Color Table: 2 cores * 3 bytes (6 bytes)
    data.extend_from_slice(&[0x00, 0x00, 0x00, 0xff, 0xff, 0xff]);

    for _ in 0..frames {
        // Graphic Control Extension (8 bytes)
        // [0x21, 0xf9, block_size=4, packed, delay_low, delay_high, trans_index, terminator=0]
        data.extend_from_slice(b"\x21\xf9\x04\x00\x0a\x00\x00\x00");
        // Image Descriptor (10 bytes)
        data.push(0x2c);
        data.extend_from_slice(&0u16.to_le_bytes()); // left
        data.extend_from_slice(&0u16.to_le_bytes()); // top
        data.extend_from_slice(&width.to_le_bytes()); // frame_width
        data.extend_from_slice(&height.to_le_bytes()); // frame_height
        data.push(0x00); // Packed fields: sem paleta local
        // LZW Minimum Code Size (1 byte)
        data.push(0x02);
        // Sub-bloco de dados com payload mínimo válido (4 bytes)
        // [length=2, byte1, byte2, terminator=0]
        data.extend_from_slice(&[0x02, 0x44, 0x01, 0x00]);
    }

    // Trailer (1 byte)
    data.push(0x3b);
    data
}

fn print_usage(program: &str) {
    eprintln!("Uso:");
    eprintln!("  {program} --synthetic [frames] [iteracoes]");
    eprintln!("  {program} <caminho-do-arquivo.gif> [iteracoes]");
    eprintln!();
    eprintln!("Exemplos:");
    eprintln!("  {program} --synthetic 120 10000");
    eprintln!("  {program} assets/wallpaper.gif 5000");
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let program = args.first().map(|s| s.as_str()).unwrap_or("probe_bench");

    let (source_name, bytes, iterations) = if args.len() <= 1 {
        // Modo padrão: fixture sintética de 120 frames (ex.: 2s a 60fps), 10.000 iterações
        let frames = 120u32;
        let iters = 10_000usize;
        eprintln!("Nenhum argumento fornecido. Executando fixture sintética padrão ({} frames, {} iterações)...", frames, iters);
        (format!("Sintético (1920x1080, {} frames)", frames), generate_synthetic_gif(1920, 1080, frames), iters)
    } else if args[1] == "--synthetic" || args[1] == "-s" {
        let frames = args.get(2).and_then(|s| s.parse::<u32>().ok()).unwrap_or(120);
        let iters = args.get(3).and_then(|s| s.parse::<usize>().ok()).unwrap_or(10_000);
        (format!("Sintético (1920x1080, {} frames)", frames), generate_synthetic_gif(1920, 1080, frames), iters)
    } else if args[1] == "--help" || args[1] == "-h" {
        print_usage(program);
        process::exit(0);
    } else {
        let path_str = &args[1];
        let path = Path::new(path_str);
        if !path.exists() {
            eprintln!("Erro: Arquivo '{}' não encontrado.", path_str);
            process::exit(1);
        }
        let file_bytes = match fs::read(path) {
            Ok(b) => b,
            Err(e) => {
                eprintln!("Erro ao ler '{}': {}", path_str, e);
                process::exit(1);
            }
        };
        let iters = args.get(2).and_then(|s| s.parse::<usize>().ok()).unwrap_or(5_000);
        (format!("Arquivo ({})", path_str), file_bytes, iters)
    };

    // Validação prévia fora da medição cronometrada
    let initial_info: GifInfo = match probe_gif(&bytes) {
        Ok(info) => info,
        Err(err) => {
            eprintln!("Erro na validação prévia do GIF: {:?}", err);
            process::exit(1);
        }
    };

    eprintln!("=== Wallmotion Media: GIF Probe Benchmark ===");
    eprintln!("Alvo: {}", source_name);
    eprintln!("Tamanho dos bytes em memória: {} bytes", bytes.len());
    eprintln!("Dimensões: {}x{}", initial_info.width, initial_info.height);
    eprintln!("Frames detectados: {}", initial_info.frames);
    eprintln!("Estimativa descompactada (RGBA): {} bytes ({:.2} MB)",
        initial_info.decoded_bytes,
        initial_info.decoded_bytes as f64 / (1024.0 * 1024.0)
    );
    eprintln!("Iterações programadas: {}", iterations);
    eprintln!("Aquecimento (100 iterações)...");

    // Aquecimento (Warm-up) para carregar instruções na CPU e estabilizar caches
    for _ in 0..100 {
        let res = black_box(probe_gif(black_box(&bytes)));
        black_box(res).ok();
    }

    eprintln!("Medindo...");

    // Vetor para calcular percentis e desvio padrão
    let mut durations_ns = Vec::with_capacity(iterations);
    let total_start = Instant::now();

    for _ in 0..iterations {
        let start = Instant::now();
        let res = black_box(probe_gif(black_box(&bytes)));
        let elapsed = start.elapsed().as_nanos() as u64;
        black_box(res).ok();
        durations_ns.push(elapsed);
    }

    let total_elapsed = total_start.elapsed();

    durations_ns.sort_unstable();
    let min_ns = durations_ns.first().copied().unwrap_or(0);
    let max_ns = durations_ns.last().copied().unwrap_or(0);
    let median_ns = durations_ns[durations_ns.len() / 2];
    let p95_ns = durations_ns[(durations_ns.len() as f64 * 0.95) as usize];
    let sum_ns: u64 = durations_ns.iter().sum();
    let mean_ns = sum_ns as f64 / iterations as f64;

    let variance = durations_ns.iter().map(|&ns| {
        let diff = ns as f64 - mean_ns;
        diff * diff
    }).sum::<f64>() / iterations as f64;
    let std_dev_ns = variance.sqrt();

    println!();
    println!("--- Resultados da Medição ---");
    println!("Iterações válidas:        {}", iterations);
    println!("Tempo total acumulado:    {:.3} ms", total_elapsed.as_secs_f64() * 1_000.0);
    println!("Média por scan:           {:.1} ns ({:.3} µs)", mean_ns, mean_ns / 1_000.0);
    println!("Mediana (p50):            {} ns ({:.3} µs)", median_ns, median_ns as f64 / 1_000.0);
    println!("Percentil 95 (p95):       {} ns ({:.3} µs)", p95_ns, p95_ns as f64 / 1_000.0);
    println!("Mínimo:                   {} ns", min_ns);
    println!("Máximo:                   {} ns", max_ns);
    println!("Desvio Padrão:            {:.1} ns", std_dev_ns);
    println!();
    println!("Metadados estruturais validados:");
    println!("  Largura:                {} px", initial_info.width);
    println!("  Altura:                 {} px", initial_info.height);
    println!("  Contagem de frames:     {}", initial_info.frames);
    println!("  Memória estimada (RGBA): {} bytes ({:.2} MB)",
        initial_info.decoded_bytes,
        initial_info.decoded_bytes as f64 / (1024.0 * 1024.0)
    );
    println!();
    println!("NOTA TÉCNICA:");
    println!("  Throughput em GB/s sobre o arquivo foi omitido intencionalmente: o scanner pula");
    println!("  subblocos de dados LZW sem decodificar pixels. Declarar uma 'taxa de transferência'");
    println!("  sobre o tamanho do arquivo comprimido seria uma métrica fictícia e não representaria");
    println!("  a complexidade algorítmica (O(N) onde N é o número de blocos/extensões estruturais).");
}
