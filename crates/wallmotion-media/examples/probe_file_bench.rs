//! Warm-cache scanner comparison only, not an app memory/energy benchmark.
#[cfg(unix)]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    use std::fs::OpenOptions;
    use std::hint::black_box;
    use std::io::Write;
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::OpenOptionsExt;
    use std::time::{Instant, SystemTime, UNIX_EPOCH};
    use wallmotion_media::{WMGifInfo, probe_gif_with_budget, wm_gif_probe_fd_bounded};

    let iterations = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "10000".into())
        .parse::<usize>()?;
    if !(1..=100_000).contains(&iterations) {
        return Err("use 1..100000 iterations".into());
    }
    let mut bytes = b"GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff".to_vec();
    for _ in 0..120 {
        bytes.extend_from_slice(b"\x2c\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02\x44\x01\x00");
    }
    bytes.push(0x3b);
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
    let path = std::env::temp_dir().join(format!(
        "wallmotion-file-bench-{}-{stamp}.gif",
        std::process::id()
    ));
    struct Cleanup(std::path::PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.0);
        }
    }
    let mut file = OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&path)?;
    let _cleanup = Cleanup(path);
    file.write_all(&bytes)?;
    let fd = file.as_raw_fd();
    let scan_file = || {
        let mut out = WMGifInfo::default();
        // SAFETY: file stays open and out is aligned writable storage for the call.
        let status = unsafe { wm_gif_probe_fd_bounded(fd, u64::MAX, &mut out) };
        assert_eq!(status, 0);
        assert_eq!(out.frames, 120);
        black_box(out);
    };
    for _ in 0..100 {
        black_box(probe_gif_with_budget(&bytes, u64::MAX)).unwrap();
        scan_file();
    }
    let mut slice = Vec::with_capacity(iterations);
    let mut stream = Vec::with_capacity(iterations);
    for iteration in 0..iterations {
        // Alternate order to reduce systematic first-run/cache-order bias.
        for file_first in [iteration % 2 == 0, iteration % 2 != 0] {
            let start = Instant::now();
            if file_first {
                scan_file();
            } else {
                black_box(probe_gif_with_budget(black_box(&bytes), u64::MAX)).unwrap();
            }
            let elapsed = start.elapsed().as_nanos();
            if file_first {
                stream.push(elapsed);
            } else {
                slice.push(elapsed);
            }
        }
    }
    println!(
        "120 frames, {} bytes, {iterations} paired iterations; warm filesystem cache",
        bytes.len()
    );
    for (name, mut samples) in [("slice", slice), ("fd (dup + metadata + pread)", stream)] {
        samples.sort_unstable();
        println!(
            "{name}: p50={} ns, p95={} ns",
            samples[samples.len() / 2],
            samples[(samples.len() - 1) * 95 / 100]
        );
    }
    println!(
        "Fixed file read-ahead buffer: 8192 bytes. Excludes import/copy, decoder, GPU, cold I/O and app RSS."
    );
    Ok(())
}

#[cfg(not(unix))]
fn main() {
    eprintln!("This descriptor benchmark requires Unix.");
}
