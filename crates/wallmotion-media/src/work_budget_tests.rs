use super::*;
#[cfg(unix)]
use std::io::{Seek, SeekFrom, Write};

const ONE: &[u8] = b"GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff\x2c\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02\x44\x01\x00\x3b";

fn scan(bytes: &[u8], steps: u64) -> Result<GifInfo, GifError> {
    probe_input_with_steps(SliceInput { bytes, position: 0 }, u64::MAX, steps)
}

fn comments(count: usize) -> Vec<u8> {
    let mut bytes = ONE[..19].to_vec();
    for _ in 0..count {
        bytes.extend_from_slice(&[0x21, 0xfe, 0]);
    }
    bytes.extend_from_slice(&ONE[19..]);
    bytes
}

#[cfg(unix)]
struct Fixture {
    file: std::fs::File,
    path: std::path::PathBuf,
}
#[cfg(unix)]
impl Fixture {
    fn new(bytes: &[u8]) -> Self {
        use std::os::unix::fs::OpenOptionsExt;
        use std::sync::atomic::{AtomicU64, Ordering};
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "wallmotion-work-{}-{stamp}-{}.gif",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let mut file = std::fs::OpenOptions::new()
            .create_new(true)
            .read(true)
            .write(true)
            .mode(0o600)
            .open(&path)
            .unwrap();
        file.write_all(bytes).unwrap();
        Self { file, path }
    }
}
#[cfg(unix)]
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

#[test]
fn exact_loop_budget_boundary_for_slice_and_file() {
    // One top-level image, two data-subblock iterations (including terminator), trailer.
    for steps in 0..4 {
        assert_eq!(scan(ONE, steps), Err(GifError::StructureBudgetExceeded));
    }
    assert_eq!(scan(ONE, 4), probe_gif(ONE));
    #[cfg(unix)]
    {
        let fixture = Fixture::new(ONE);
        for steps in 0..=4 {
            assert_eq!(
                probe_input_with_steps(
                    file_input::FileInput::new(&fixture.file).unwrap(),
                    u64::MAX,
                    steps
                ),
                scan(ONE, steps)
            );
        }
    }
}

#[test]
fn empty_extensions_consume_budget_and_do_not_hide_behind_small_canvas() {
    let bytes = comments(3);
    assert_eq!(scan(&bytes, 9), Err(GifError::StructureBudgetExceeded));
    assert_eq!(scan(&bytes, 10), probe_gif(ONE));
    // Decoded-byte rejection remains a distinct error when that check wins first.
    assert_eq!(probe_gif_with_budget(ONE, 3), Err(GifError::BudgetExceeded));
}

#[test]
fn each_comment_subblock_including_terminator_consumes_work() {
    let mut bytes = ONE[..19].to_vec();
    bytes.extend_from_slice(&[0x21, 0xfe]);
    for _ in 0..7 {
        bytes.extend_from_slice(&[1, 0xff]);
    }
    bytes.push(0);
    bytes.extend_from_slice(&ONE[19..]);
    assert_eq!(scan(&bytes, 12), Err(GifError::StructureBudgetExceeded));
    assert_eq!(scan(&bytes, 13), probe_gif(ONE));
}

#[test]
fn exhausted_budget_rejects_before_attempting_to_read_the_tail() {
    struct PrefixOnly<'a>(SliceInput<'a>);
    impl Input for PrefixOnly<'_> {
        fn read(&mut self, output: &mut [u8]) -> Result<(), GifError> {
            if self.0.position >= 22 {
                return Err(GifError::ReadFailure);
            }
            self.0.read(output)
        }
        fn skip(&mut self, length: usize) -> Result<(), GifError> {
            self.0.skip(length)
        }
    }
    let bytes = comments(1);
    assert_eq!(
        probe_input_with_steps(
            PrefixOnly(SliceInput {
                bytes: &bytes,
                position: 0
            }),
            u64::MAX,
            2
        ),
        Err(GifError::StructureBudgetExceeded)
    );
}

#[test]
fn default_ffi_work_failure_preserves_output_and_file_offset() {
    let bytes = comments((DEFAULT_MAX_STRUCTURE_STEPS / 2) as usize);
    let sentinel = WMGifInfo {
        width: 7,
        height: 8,
        frames: 9,
        decoded_bytes: 10,
    };
    let mut output = sentinel;
    // SAFETY: bytes is a live allocation and output is aligned writable storage.
    assert_eq!(
        unsafe { wm_gif_probe_bounded(bytes.as_ptr(), bytes.len(), u64::MAX, &mut output) },
        3
    );
    assert_eq!(output, sentinel);
    // SAFETY: Same live allocation/output ownership contract.
    assert_eq!(
        unsafe { wm_gif_probe(bytes.as_ptr(), bytes.len(), &mut output) },
        3
    );
    assert_eq!(output, sentinel);
    #[cfg(unix)]
    {
        use std::os::fd::AsRawFd;
        let mut fixture = Fixture::new(&bytes);
        fixture.file.seek(SeekFrom::Start(5)).unwrap();
        // SAFETY: the descriptor stays open and output is aligned writable storage.
        assert_eq!(
            unsafe { wm_gif_probe_fd_bounded(fixture.file.as_raw_fd(), u64::MAX, &mut output) },
            3
        );
        assert_eq!(output, sentinel);
        assert_eq!(fixture.file.stream_position().unwrap(), 5);
        assert!(fixture.file.metadata().is_ok());
    }
}
