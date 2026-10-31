use super::*;
use crate::animation_ffi::*;
use std::fs::OpenOptions;
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::OpenOptionsExt;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime};

static NEXT: AtomicU64 = AtomicU64::new(0);
const ONE: &[u8] = b"GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff\x2c\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02\x44\x01\x00\x3b";
struct Fixture {
    file: File,
    path: PathBuf,
}
impl Fixture {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "wallmotion-animation-fd-{}-{}",
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
        file.write_all(ONE).unwrap();
        Self { file, path }
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

#[test]
fn fd_decode_preserves_offset_and_pixels_survive_file_close_and_unlink() {
    let mut fixture = Fixture::new();
    fixture.file.seek(SeekFrom::Start(7)).unwrap();
    let mut handle = std::ptr::null();
    // SAFETY: The descriptor stays open and out is valid aligned storage.
    assert_eq!(
        unsafe {
            wm_gif_animation_decode_fd(fixture.file.as_raw_fd(), 1024, 4, 64, 1, &mut handle)
        },
        0
    );
    assert_eq!(fixture.file.stream_position().unwrap(), 7);
    assert!(fixture.file.metadata().is_ok());
    drop(fixture);
    let mut frame = WMGifFrameView {
        pixels: std::ptr::null(),
        length: 0,
        delay_centiseconds: 0,
    };
    // SAFETY: handle owns an independent immutable decoded allocation.
    assert_eq!(unsafe { wm_gif_animation_frame(handle, 0, &mut frame) }, 0);
    // SAFETY: Live handle owns exactly the returned byte region.
    assert_eq!(
        unsafe { std::slice::from_raw_parts(frame.pixels, frame.length) },
        &[0, 0, 0, 255]
    );
    // SAFETY: Balance the only acquired reference after its final pixel use.
    unsafe { wm_gif_animation_release(handle) };
}

#[test]
fn fd_budget_rejection_is_metadata_only_and_preserves_output() {
    let fixture = Fixture::new();
    fixture.file.set_len(1_048_576).unwrap();
    let write_only = OpenOptions::new().write(true).open(&fixture.path).unwrap();
    let mut sentinel = std::ptr::NonNull::<WMGifAnimation>::dangling()
        .as_ptr()
        .cast_const();
    let before = sentinel;
    // SAFETY: Descriptor is live; sentinel is only output storage, never dereferenced.
    assert_eq!(
        unsafe {
            wm_gif_animation_decode_fd(write_only.as_raw_fd(), 1024, 4, 64, 1, &mut sentinel)
        },
        4
    );
    assert_eq!(sentinel, before);
}

#[test]
fn rejects_nonregular_descriptors_and_keeps_them_open() {
    let (socket, _peer) = std::os::unix::net::UnixStream::pair().unwrap();
    let (reader, _writer) = std::io::pipe().unwrap();
    let directory = File::open(std::env::temp_dir()).unwrap();
    let device = File::open("/dev/null").unwrap();
    for fd in [
        socket.as_raw_fd(),
        reader.as_raw_fd(),
        directory.as_raw_fd(),
        device.as_raw_fd(),
        -1,
    ] {
        let mut sentinel = std::ptr::null();
        // SAFETY: Every non-negative descriptor remains open; output is valid.
        assert_eq!(
            unsafe { wm_gif_animation_decode_fd(fd, 1024, 4, 64, 1, &mut sentinel) },
            1
        );
        assert!(sentinel.is_null());
    }
    assert!(directory.metadata().unwrap().is_dir());
}

#[test]
fn metadata_change_during_stream_rejects_publication() {
    let fixture = Fixture::new();
    fixture.file.set_len(140_000).unwrap();
    let mut changed = false;
    let result = decode_with_reader(&fixture.file, DecodeLimits::default(), |buffer, offset| {
        let read = fixture.file.read_at(buffer, offset)?;
        if !changed {
            changed = true;
            fixture
                .file
                .set_modified(SystemTime::UNIX_EPOCH + Duration::from_secs(123))?;
        }
        Ok(read)
    });
    assert!(matches!(result, Err(FileDecodeError::Changed)));
}

#[test]
fn truncation_and_growth_during_stream_never_publish_changed_input() {
    for truncate in [true, false] {
        let fixture = Fixture::new();
        fixture.file.set_len(140_000).unwrap();
        let mut changed = false;
        let result =
            decode_with_reader(&fixture.file, DecodeLimits::default(), |buffer, offset| {
                let read = fixture.file.read_at(buffer, offset)?;
                if !changed {
                    changed = true;
                    fixture.file.set_len(if truncate { 0 } else { 140_001 })?;
                }
                Ok(read)
            });
        assert!(matches!(result, Err(FileDecodeError::Changed)));
    }
}

#[test]
fn interrupted_and_partial_positional_reads_preserve_exact_content_and_offset() {
    let mut fixture = Fixture::new();
    fixture.file.seek(SeekFrom::Start(9)).unwrap();
    let identity = Identity::read(&fixture.file).unwrap();
    let mut interrupted = false;
    let mut reader = PositionedReader {
        length: identity.length,
        position: 0,
        read_at: |buffer: &mut [u8], offset| {
            if !interrupted {
                interrupted = true;
                return Err(io::Error::from(ErrorKind::Interrupted));
            }
            let size = buffer.len().min(3);
            fixture.file.read_at(&mut buffer[..size], offset)
        },
    };
    let mut bytes = Vec::new();
    reader.read_to_end(&mut bytes).unwrap();
    assert_eq!(bytes, ONE);
    assert_eq!(fixture.file.stream_position().unwrap(), 9);
}

#[test]
fn trailing_sparse_file_bytes_are_not_copied_or_read_in_full() {
    let fixture = Fixture::new();
    fixture.file.set_len(64 * 1024 * 1024).unwrap();
    let mut read_bytes = 0;
    let animation = decode_with_reader(&fixture.file, DecodeLimits::default(), |buffer, offset| {
        let count = fixture.file.read_at(buffer, offset)?;
        read_bytes += count;
        Ok(count)
    })
    .unwrap();
    assert_eq!(animation.payload_bytes(), 4);
    assert!(
        read_bytes < 64 * 1024,
        "Only bounded codec read-ahead should follow the early trailer"
    );
}

#[test]
fn truncation_mid_header_and_initial_length_boundary_fail_without_overread() {
    let fixture = Fixture::new();
    let mut changed = false;
    let result = decode_with_reader(&fixture.file, DecodeLimits::default(), |buffer, offset| {
        let count = fixture.file.read_at(&mut buffer[..3], offset)?;
        if !changed {
            changed = true;
            fixture.file.set_len(0)?;
        }
        Ok(count)
    });
    assert!(matches!(
        result,
        Err(FileDecodeError::Decode(DecodeError::InvalidData))
    ));
    let mut reads = 0;
    let mut reader = PositionedReader {
        length: 2,
        position: 0,
        read_at: |buffer: &mut [u8], offset| {
            reads += 1;
            assert_eq!(offset, 0);
            assert_eq!(buffer.len(), 2);
            buffer.copy_from_slice(&[1, 2]);
            Ok(2)
        },
    };
    let mut out = [0; 4];
    assert_eq!(reader.read(&mut out).unwrap(), 2);
    assert_eq!(reader.read(&mut out).unwrap(), 0);
    assert_eq!(reads, 1);
}
