use crate::{GifError, Input};
use std::fs::File;
use std::io::ErrorKind;
use std::os::unix::fs::FileExt;

/// Fixed-size read-ahead, never a mapping into mutable file pages. The initial
/// file length bounds traversal: appended bytes do not prolong this scan.
pub(crate) struct FileInput<'a> {
    file: &'a File,
    length: u64,
    position: u64,
    buffer: [u8; 8192],
    buffer_start: u64,
    buffered: usize,
}

impl<'a> FileInput<'a> {
    pub(crate) fn new(file: &'a File) -> Result<Self, GifError> {
        let metadata = file.metadata().map_err(|_| GifError::ReadFailure)?;
        if !metadata.is_file() || metadata.len() > i64::MAX as u64 {
            return Err(GifError::InvalidBlock);
        }
        Ok(Self {
            file,
            length: metadata.len(),
            position: 0,
            buffer: [0; 8192],
            buffer_start: 0,
            buffered: 0,
        })
    }

    fn end(&self, length: usize) -> Result<u64, GifError> {
        let end = self
            .position
            .checked_add(length as u64)
            .ok_or(GifError::Overflow)?;
        if end > self.length {
            return Err(GifError::Truncated);
        }
        Ok(end)
    }

    fn refill(&mut self) -> Result<(), GifError> {
        let count = (self.length - self.position).min(self.buffer.len() as u64) as usize;
        loop {
            match self.file.read_at(&mut self.buffer[..count], self.position) {
                Ok(0) => return Err(GifError::Truncated),
                Ok(read) => {
                    self.buffer_start = self.position;
                    self.buffered = read;
                    return Ok(());
                }
                Err(error) if error.kind() == ErrorKind::Interrupted => continue,
                Err(_) => return Err(GifError::ReadFailure),
            }
        }
    }
}

impl Input for FileInput<'_> {
    fn read(&mut self, mut output: &mut [u8]) -> Result<(), GifError> {
        self.end(output.len())?;
        while !output.is_empty() {
            let offset = self.position.saturating_sub(self.buffer_start);
            if self.position < self.buffer_start || offset >= self.buffered as u64 {
                self.refill()?;
            }
            let offset = (self.position - self.buffer_start) as usize;
            let count = output.len().min(self.buffered - offset);
            output[..count].copy_from_slice(&self.buffer[offset..offset + count]);
            self.position += count as u64;
            output = &mut output[count..];
        }
        Ok(())
    }

    fn skip(&mut self, length: usize) -> Result<(), GifError> {
        self.position = self.end(length)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::OpenOptions;
    use std::io::{Seek, SeekFrom, Write};
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::OpenOptionsExt;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT: AtomicU64 = AtomicU64::new(0);
    const ONE: &[u8] = b"GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff\x2c\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02\x44\x01\x00\x3b";

    struct Fixture {
        file: File,
        path: PathBuf,
    }
    impl Fixture {
        fn new(bytes: &[u8]) -> Self {
            let path = std::env::temp_dir().join(format!(
                "wallmotion-gif-reader-{}-{}",
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
            file.write_all(bytes).unwrap();
            Self { file, path }
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.path);
        }
    }

    #[test]
    fn file_probe_matches_slice_for_every_prefix_and_keeps_original_offset() {
        let mut fixture = Fixture::new(ONE);
        fixture.file.seek(SeekFrom::Start(7)).unwrap();
        for size in (0..=ONE.len()).rev() {
            fixture.file.set_len(size as u64).unwrap();
            assert_eq!(
                crate::probe_gif_file_with_budget(&fixture.file, u64::MAX),
                crate::probe_gif(&ONE[..size])
            );
            assert_eq!(fixture.file.stream_position().unwrap(), 7);
        }
    }

    #[test]
    fn truncation_after_metadata_and_after_buffered_header_returns_eof() {
        let mut payload = ONE.to_vec();
        payload.resize(20_000, 0);
        let fixture = Fixture::new(&payload);
        let mut input = FileInput::new(&fixture.file).unwrap();
        let mut header = [0; 6];
        input.read(&mut header).unwrap();
        assert_eq!(&header, b"GIF89a");
        let mut short = FileInput::new(&fixture.file).unwrap();
        fixture.file.set_len(6).unwrap();
        // A partial pread is progress, not EOF: keep the complete header, then
        // report EOF only when the following byte is actually unavailable.
        short.read(&mut header).unwrap();
        assert_eq!(&header, b"GIF89a");
        assert_eq!(short.read(&mut [0]), Err(GifError::Truncated));
        // Skip beyond the already-read buffer, forcing a new pread at EOF.
        input.skip(9000).unwrap();
        assert_eq!(input.read(&mut [0]), Err(GifError::Truncated));
        let mut fresh = FileInput::new(&fixture.file).unwrap();
        fixture.file.set_len(0).unwrap();
        assert_eq!(fresh.read(&mut [0]), Err(GifError::Truncated));
    }

    #[test]
    fn read_ahead_handles_large_subblocks_and_stops_at_initial_length() {
        let mut bytes = ONE[..19].to_vec();
        bytes.extend_from_slice(&[0x21, 0xfe]);
        for _ in 0..200 {
            bytes.push(255);
            bytes.extend_from_slice(&[42; 255]);
        }
        bytes.push(0);
        bytes.extend_from_slice(&ONE[19..]);
        let fixture = Fixture::new(&bytes);
        assert_eq!(
            crate::probe_gif_file_with_budget(&fixture.file, 4),
            crate::probe_gif(&bytes)
        );
        let mut input = FileInput::new(&fixture.file).unwrap();
        fixture.file.set_len((bytes.len() + 100) as u64).unwrap();
        input.skip(bytes.len()).unwrap();
        assert_eq!(input.read(&mut [0]), Err(GifError::Truncated));
    }

    #[test]
    fn fd_ffi_preserves_output_on_error_and_does_not_close_caller_file() {
        let mut fixture = Fixture::new(ONE);
        fixture.file.seek(SeekFrom::Start(5)).unwrap();
        let mut output = crate::WMGifInfo::default();
        // SAFETY: The fixture owns a live regular-file descriptor and output is aligned.
        assert_eq!(
            unsafe { crate::wm_gif_probe_fd_bounded(fixture.file.as_raw_fd(), 4, &mut output) },
            0
        );
        assert_eq!(output.decoded_bytes, 4);
        let previous = output;
        // SAFETY: Same live descriptor/output contract; budget rejection must not write.
        assert_eq!(
            unsafe { crate::wm_gif_probe_fd_bounded(fixture.file.as_raw_fd(), 3, &mut output) },
            2
        );
        assert_eq!(output, previous);
        fixture.file.set_len(6).unwrap();
        // SAFETY: The truncated file is still open and readable, with aligned output.
        assert_eq!(
            unsafe { crate::wm_gif_probe_fd_bounded(fixture.file.as_raw_fd(), 4, &mut output) },
            1
        );
        assert_eq!(output, previous);
        assert_eq!(fixture.file.stream_position().unwrap(), 5);
        let write_only = OpenOptions::new().write(true).open(&fixture.path).unwrap();
        // SAFETY: The write-only descriptor is live; read failure must be reported.
        assert_eq!(
            unsafe { crate::wm_gif_probe_fd_bounded(write_only.as_raw_fd(), 4, &mut output) },
            1
        );
        assert_eq!(output, previous);
        assert!(fixture.file.metadata().is_ok());
    }
}
