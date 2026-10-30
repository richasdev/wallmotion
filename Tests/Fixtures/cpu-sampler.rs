use std::hint::black_box;
use std::time::{Duration, Instant};
fn main() {
    let memory = vec![1u8; 16 * 1024 * 1024];
    let started = Instant::now();
    let mut value = 1u64;
    while started.elapsed() < Duration::from_secs(3) {
        for _ in 0..10000 {
            value = black_box(value.wrapping_mul(6364136223846793005).wrapping_add(1));
        }
    }
    black_box((&memory, value));
    std::thread::sleep(Duration::from_secs(5));
    black_box(memory);
}
