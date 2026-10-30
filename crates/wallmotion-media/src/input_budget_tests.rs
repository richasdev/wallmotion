use super::*;

const ONE: &[u8] = b"GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff\x2c\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02\x44\x01\x00\x3b";

#[test]
fn encoded_slice_limit_includes_ignored_trailing_bytes_and_preserves_old_api() {
    let mut bytes = ONE.to_vec();
    bytes.extend_from_slice(&[42; 16]);
    assert_eq!(probe_gif_with_budget(&bytes, 4), probe_gif(ONE));
    assert_eq!(
        probe_gif_with_limits(&bytes, 4, bytes.len() as u64),
        probe_gif(ONE)
    );
    assert_eq!(
        probe_gif_with_limits(&bytes, 4, bytes.len() as u64 - 1),
        Err(GifError::EncodedBudgetExceeded)
    );
    assert_eq!(
        probe_gif_with_limits(b"not a GIF", 4, 0),
        Err(GifError::EncodedBudgetExceeded)
    );
    assert_eq!(
        probe_gif_with_limits(ONE, 3, ONE.len() as u64),
        Err(GifError::BudgetExceeded)
    );
}

#[test]
fn limited_slice_ffi_preserves_output_on_encoded_rejection_and_checks_pointers() {
    let mut output = WMGifInfo {
        width: 9,
        height: 8,
        frames: 7,
        decoded_bytes: 6,
    };
    let original = output;
    // SAFETY: ONE is live and readable for its length; output is aligned/writable.
    assert_eq!(
        unsafe {
            wm_gif_probe_limited(
                ONE.as_ptr(),
                ONE.len(),
                4,
                ONE.len() as u64 - 1,
                &mut output,
            )
        },
        4
    );
    assert_eq!(output, original);
    // SAFETY: Null input is explicitly rejected; output remains valid.
    assert_eq!(
        unsafe { wm_gif_probe_limited(core::ptr::null(), 1, 4, 0, &mut output) },
        1
    );
    assert_eq!(output, original);
    // SAFETY: Null output is explicitly rejected with the valid input buffer.
    assert_eq!(
        unsafe { wm_gif_probe_limited(ONE.as_ptr(), ONE.len(), 4, 0, core::ptr::null_mut()) },
        1
    );
    // SAFETY: The valid fixture meets both exact size budgets.
    assert_eq!(
        unsafe { wm_gif_probe_limited(ONE.as_ptr(), ONE.len(), 4, ONE.len() as u64, &mut output) },
        0
    );
    assert_eq!(output.decoded_bytes, 4);
}

#[cfg(unix)]
#[test]
fn sparse_file_limit_rejects_before_read_and_leaves_descriptor_offset_and_output_intact() {
    use std::fs::OpenOptions;
    use std::io::{Seek, SeekFrom, Write};
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::OpenOptionsExt;
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(0);
    struct Remove(std::path::PathBuf);
    impl Drop for Remove {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.0);
        }
    }
    let path = std::env::temp_dir().join(format!(
        "wallmotion-gif-input-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    let mut file = OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&path)
        .unwrap();
    let _cleanup = Remove(path.clone());
    file.write_all(ONE).unwrap();
    assert_eq!(
        probe_gif_file_with_limits(&file, 4, ONE.len() as u64),
        probe_gif(ONE)
    );
    file.set_len(512 * 1024 * 1024).unwrap(); // Sparse tail: no giant in-memory fixture.
    file.seek(SeekFrom::Start(7)).unwrap();
    assert_eq!(
        probe_gif_file_with_budget(&file, 4),
        probe_gif(ONE),
        "Compatible API still ignores trailing bytes"
    );
    assert_eq!(
        probe_gif_file_with_limits(&file, 4, 128 * 1024 * 1024),
        Err(GifError::EncodedBudgetExceeded)
    );
    let mut output = WMGifInfo {
        width: 9,
        height: 8,
        frames: 7,
        decoded_bytes: 6,
    };
    let original = output;
    // SAFETY: The caller-owned file stays open; output is aligned/writable.
    assert_eq!(
        unsafe { wm_gif_probe_fd_limited(file.as_raw_fd(), 4, 128 * 1024 * 1024, &mut output) },
        4
    );
    assert_eq!(output, original);
    assert_eq!(file.stream_position().unwrap(), 7);
    let write_only = OpenOptions::new().write(true).open(&path).unwrap();
    // SAFETY: A live descriptor is supplied. Rejection must precede any content read.
    assert_eq!(
        unsafe { wm_gif_probe_fd_limited(write_only.as_raw_fd(), 4, 0, &mut output) },
        4
    );
    assert_eq!(output, original);
    // SAFETY: The metadata-only check owns only a duplicate of this live descriptor.
    assert_eq!(
        unsafe { wm_gif_check_input_fd(write_only.as_raw_fd(), 0) },
        4
    );
    // SAFETY: A write-only regular file is sufficient: no content read is attempted.
    assert_eq!(
        unsafe { wm_gif_check_input_fd(write_only.as_raw_fd(), 512 * 1024 * 1024) },
        0
    );
    // SAFETY: Negative descriptors are explicitly rejected without borrowing.
    assert_eq!(unsafe { wm_gif_check_input_fd(-1, u64::MAX) }, 1);
    // SAFETY: The compatibility symbol keeps its prior pointer/descriptor contract.
    assert_eq!(
        unsafe { wm_gif_probe_fd_bounded(file.as_raw_fd(), 4, &mut output) },
        0
    );
    assert_eq!(output.decoded_bytes, 4);
    assert_eq!(file.stream_position().unwrap(), 7);
    assert!(file.metadata().is_ok());
}
