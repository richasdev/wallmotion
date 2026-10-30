//! Allocation-free GIF structure inspection. Compressed image data is skipped,
//! never decoded. The estimate accounts for a full RGBA canvas for every frame.

#[cfg(unix)]
mod file_input;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct GifInfo {
    pub width: u32,
    pub height: u32,
    pub frames: u32,
    pub decoded_bytes: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GifError {
    InvalidHeader,
    Truncated,
    InvalidDimensions,
    InvalidBlock,
    FrameOutsideCanvas,
    NoFrames,
    Overflow,
    BudgetExceeded,
    EncodedBudgetExceeded,
    StructureBudgetExceeded,
    ReadFailure,
}

/// Maximum main-block plus subblock loop iterations in every public probe.
/// This bounds parser work, not I/O latency, codec work, or total CPU time.
pub const DEFAULT_MAX_STRUCTURE_STEPS: u64 = 1_000_000;

trait Input {
    fn read(&mut self, output: &mut [u8]) -> Result<(), GifError>;
    fn skip(&mut self, length: usize) -> Result<(), GifError>;
}

struct SliceInput<'a> {
    bytes: &'a [u8],
    position: usize,
}

impl Input for SliceInput<'_> {
    fn read(&mut self, output: &mut [u8]) -> Result<(), GifError> {
        let end = self
            .position
            .checked_add(output.len())
            .ok_or(GifError::Overflow)?;
        output.copy_from_slice(
            self.bytes
                .get(self.position..end)
                .ok_or(GifError::Truncated)?,
        );
        self.position = end;
        Ok(())
    }

    fn skip(&mut self, length: usize) -> Result<(), GifError> {
        let end = self
            .position
            .checked_add(length)
            .ok_or(GifError::Overflow)?;
        self.bytes
            .get(self.position..end)
            .ok_or(GifError::Truncated)?;
        self.position = end;
        Ok(())
    }
}

struct Cursor<R> {
    input: R,
    remaining_steps: u64,
}

impl<R: Input> Cursor<R> {
    fn step(&mut self) -> Result<(), GifError> {
        if self.remaining_steps == 0 {
            return Err(GifError::StructureBudgetExceeded);
        }
        self.remaining_steps -= 1;
        Ok(())
    }

    fn read<const N: usize>(&mut self) -> Result<[u8; N], GifError> {
        let mut bytes = [0; N];
        self.input.read(&mut bytes)?;
        Ok(bytes)
    }

    fn skip(&mut self, length: usize) -> Result<(), GifError> {
        self.input.skip(length)
    }

    fn byte(&mut self) -> Result<u8, GifError> {
        Ok(self.read::<1>()?[0])
    }

    fn word(&mut self) -> Result<u32, GifError> {
        let low = u32::from(self.byte()?);
        let high = u32::from(self.byte()?);
        Ok(low | (high << 8))
    }

    fn color_table(&mut self, packed: u8) -> Result<(), GifError> {
        if packed & 0x80 != 0 {
            let entries = 1usize
                .checked_shl(u32::from(packed & 7) + 1)
                .ok_or(GifError::Overflow)?;
            self.skip(entries.checked_mul(3).ok_or(GifError::Overflow)?)?;
        }
        Ok(())
    }

    /// Returns whether at least one nonempty data block was present.
    fn subblocks(&mut self) -> Result<bool, GifError> {
        let mut present = false;
        loop {
            self.step()?;
            let length = usize::from(self.byte()?);
            if length == 0 {
                return Ok(present);
            }
            self.skip(length)?;
            present = true;
        }
    }

    fn extension(&mut self) -> Result<(), GifError> {
        match self.byte()? {
            // Graphic Control Extension has one fixed-size block and terminator.
            0xf9 => {
                if self.byte()? != 4 {
                    return Err(GifError::InvalidBlock);
                }
                self.skip(4)?;
                if self.byte()? != 0 {
                    return Err(GifError::InvalidBlock);
                }
            }
            // Application and Plain Text Extensions begin with fixed-size headers.
            label @ (0xff | 0x01) => {
                let expected = if label == 0xff { 11 } else { 12 };
                if self.byte()? != expected {
                    return Err(GifError::InvalidBlock);
                }
                self.skip(usize::from(expected))?;
                self.subblocks()?;
            }
            // Comments and unknown extensions are sequences of data subblocks.
            _ => {
                self.subblocks()?;
            }
        }
        Ok(())
    }
}

/// Validates GIF container structure without allocating or decoding LZW data.
/// Requires a trailer and at least one image. Bytes after the trailer are ignored.
/// This is a metadata probe, not validation of the compressed pixel stream.
/// At most DEFAULT_MAX_STRUCTURE_STEPS structural iterations are permitted.
pub fn probe_gif(bytes: &[u8]) -> Result<GifInfo, GifError> {
    probe_gif_with_budget(bytes, u64::MAX)
}

/// Stops at the first complete frame that exceeds the decoded canvas budget.
/// A budget rejection does not validate the remaining bytes or require a trailer.
pub fn probe_gif_with_budget(bytes: &[u8], max_decoded_bytes: u64) -> Result<GifInfo, GifError> {
    probe_input(SliceInput { bytes, position: 0 }, max_decoded_bytes)
}

/// Checks the complete encoded input length, including bytes after a trailer,
/// before inspecting structure. Does not allocate or decode pixels.
pub fn probe_gif_with_limits(
    bytes: &[u8],
    max_decoded_bytes: u64,
    max_encoded_bytes: u64,
) -> Result<GifInfo, GifError> {
    if bytes.len() as u64 > max_encoded_bytes {
        return Err(GifError::EncodedBudgetExceeded);
    }
    probe_gif_with_budget(bytes, max_decoded_bytes)
}

fn probe_input(input: impl Input, max_decoded_bytes: u64) -> Result<GifInfo, GifError> {
    probe_input_with_steps(input, max_decoded_bytes, DEFAULT_MAX_STRUCTURE_STEPS)
}

fn probe_input_with_steps(
    input: impl Input,
    max_decoded_bytes: u64,
    max_steps: u64,
) -> Result<GifInfo, GifError> {
    let mut cursor = Cursor {
        input,
        remaining_steps: max_steps,
    };
    match &cursor.read::<6>()? {
        b"GIF87a" | b"GIF89a" => {}
        _ => return Err(GifError::InvalidHeader),
    }
    let width = cursor.word()?;
    let height = cursor.word()?;
    if width == 0 || height == 0 {
        return Err(GifError::InvalidDimensions);
    }
    let packed = cursor.byte()?;
    cursor.skip(2)?; // Background color index and pixel aspect ratio.
    cursor.color_table(packed)?;
    let mut frames = 0u32;
    loop {
        cursor.step()?;
        match cursor.byte()? {
            0x21 => cursor.extension()?,
            0x2c => {
                let left = cursor.word()?;
                let top = cursor.word()?;
                let frame_width = cursor.word()?;
                let frame_height = cursor.word()?;
                if frame_width == 0 || frame_height == 0 {
                    return Err(GifError::InvalidDimensions);
                }
                if left.checked_add(frame_width).ok_or(GifError::Overflow)? > width
                    || top.checked_add(frame_height).ok_or(GifError::Overflow)? > height
                {
                    return Err(GifError::FrameOutsideCanvas);
                }
                let packed = cursor.byte()?;
                cursor.color_table(packed)?;
                if !(2..=8).contains(&cursor.byte()?) {
                    return Err(GifError::InvalidBlock);
                }
                if !cursor.subblocks()? {
                    return Err(GifError::InvalidBlock);
                }
                frames = frames.checked_add(1).ok_or(GifError::Overflow)?;
                if decoded_size(width, height, frames)? > max_decoded_bytes {
                    return Err(GifError::BudgetExceeded);
                }
            }
            0x3b => {
                if frames == 0 {
                    return Err(GifError::NoFrames);
                }
                let decoded_bytes = decoded_size(width, height, frames)?;
                return Ok(GifInfo {
                    width,
                    height,
                    frames,
                    decoded_bytes,
                });
            }
            _ => return Err(GifError::InvalidBlock),
        }
    }
}

/// Scans a regular file using 8 KiB of read-ahead. Does not change its seek
/// offset or map pages; concurrent truncation becomes EOF/read failure. Buffered
/// bytes are a partial snapshot, not a guarantee of a coherent mutable file.
#[cfg(unix)]
pub fn probe_gif_file_with_budget(
    file: &std::fs::File,
    max_decoded_bytes: u64,
) -> Result<GifInfo, GifError> {
    probe_input(file_input::FileInput::new(file)?, max_decoded_bytes)
}

/// Like the compatible file probe, with an additional initial encoded-length
/// limit checked from the same descriptor before any input read. Appends after
/// metadata remain outside the initial snapshot; this is not a coherent snapshot.
#[cfg(unix)]
pub fn probe_gif_file_with_limits(
    file: &std::fs::File,
    max_decoded_bytes: u64,
    max_encoded_bytes: u64,
) -> Result<GifInfo, GifError> {
    probe_input(
        file_input::FileInput::with_input_limit(file, max_encoded_bytes)?,
        max_decoded_bytes,
    )
}

fn decoded_size(width: u32, height: u32, frames: u32) -> Result<u64, GifError> {
    u64::from(width)
        .checked_mul(u64::from(height))
        .and_then(|value| value.checked_mul(4))
        .and_then(|value| value.checked_mul(u64::from(frames)))
        .ok_or(GifError::Overflow)
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct WMGifInfo {
    pub width: u32,
    pub height: u32,
    pub frames: u32,
    pub decoded_bytes: u64,
}

/// Returns 0 on success, 1 on invalid input, 3 on structural work exhaustion.
/// On failure, `out` is unchanged.
///
/// # Safety
/// `bytes` must point to `len` readable bytes in a single allocation, and `out`
/// must be aligned and writable for one `WMGifInfo`. Null pointers are rejected.
/// No data is retained after this call. The checked parser cannot panic.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn wm_gif_probe(bytes: *const u8, len: usize, out: *mut WMGifInfo) -> i32 {
    // SAFETY: This compatibility entry point forwards its identical pointer contract.
    unsafe { wm_gif_probe_bounded(bytes, len, u64::MAX, out) }
}

/// Returns 0 on success, 1 for invalid input, 2 for decoded-byte budget,
/// 3 for structural loop-step budget exhaustion.
/// All error paths leave `out` unchanged; rejection may skip the remaining input.
///
/// # Safety
/// The caller must provide the same readable buffer and writable aligned output
/// contract as `wm_gif_probe`. No references or data are retained after return.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn wm_gif_probe_bounded(
    bytes: *const u8,
    len: usize,
    max_decoded_bytes: u64,
    out: *mut WMGifInfo,
) -> i32 {
    if bytes.is_null() || out.is_null() || !out.is_aligned() || len > isize::MAX as usize {
        return 1;
    }
    // SAFETY: The caller provides the readable allocation documented above.
    let input = unsafe { core::slice::from_raw_parts(bytes, len) };
    match probe_gif_with_budget(input, max_decoded_bytes) {
        Ok(info) => {
            // SAFETY: The caller provides aligned writable output storage.
            unsafe {
                out.write(WMGifInfo {
                    width: info.width,
                    height: info.height,
                    frames: info.frames,
                    decoded_bytes: info.decoded_bytes,
                });
            }
            0
        }
        Err(GifError::BudgetExceeded) => 2,
        Err(GifError::StructureBudgetExceeded) => 3,
        Err(_) => 1,
    }
}

/// Like wm_gif_probe_bounded, plus result 4 when the complete encoded length
/// exceeds max_encoded_bytes. Error paths preserve output storage.
///
/// # Safety
/// The buffer and output have the same readable/aligned/writable contract as
/// wm_gif_probe_bounded, even when a size limit rejects the input early.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn wm_gif_probe_limited(
    bytes: *const u8,
    len: usize,
    max_decoded_bytes: u64,
    max_encoded_bytes: u64,
    out: *mut WMGifInfo,
) -> i32 {
    if bytes.is_null() || out.is_null() || !out.is_aligned() || len > isize::MAX as usize {
        return 1;
    }
    if len as u64 > max_encoded_bytes {
        return 4;
    }
    // SAFETY: Identical buffer/output contract, checked above and required of caller.
    unsafe { wm_gif_probe_bounded(bytes, len, max_decoded_bytes, out) }
}

/// Same result codes as wm_gif_probe_bounded; read errors are invalid input.
/// Duplicates the descriptor for this call and never changes the caller's offset.
/// No file-backed memory mapping or whole-file allocation is used.
///
/// # Safety
/// `descriptor` must be an open descriptor throughout this call. `out` must be
/// aligned and writable for one WMGifInfo. No descriptor/data is retained.
#[cfg(unix)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn wm_gif_probe_fd_bounded(
    descriptor: i32,
    max_decoded_bytes: u64,
    out: *mut WMGifInfo,
) -> i32 {
    // SAFETY: Identical descriptor/output contract; legacy entry has no encoded cap.
    unsafe { wm_gif_probe_fd_limited(descriptor, max_decoded_bytes, u64::MAX, out) }
}

/// Metadata-only size check for a regular input file. Does not validate GIF data.
/// Returns 0 when size is allowed, 1 for invalid/read metadata, 4 for encoded size.
///
/// # Safety
/// The caller must keep descriptor open throughout this call. The descriptor is
/// duplicated, never sought or read, and no descriptor or data is retained.
#[cfg(unix)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn wm_gif_check_input_fd(descriptor: i32, max_encoded_bytes: u64) -> i32 {
    use std::os::fd::BorrowedFd;
    if descriptor < 0 {
        return 1;
    }
    // SAFETY: The caller keeps the supplied descriptor open throughout the call.
    let borrowed = unsafe { BorrowedFd::borrow_raw(descriptor) };
    let owned = match borrowed.try_clone_to_owned() {
        Ok(owned) => owned,
        Err(_) => return 1,
    };
    let file = std::fs::File::from(owned);
    match file_input::checked_length(&file, max_encoded_bytes) {
        Ok(_) => 0,
        Err(GifError::EncodedBudgetExceeded) => 4,
        Err(_) => 1,
    }
}

/// Like wm_gif_probe_fd_bounded, plus result 4 when the initial regular-file
/// length exceeds max_encoded_bytes. Uses the same descriptor metadata as the
/// bounded read-ahead input, without reading a rejected file's contents.
///
/// # Safety
/// The caller keeps descriptor open and supplies writable aligned WMGifInfo
/// storage throughout the call. No descriptor, mapping or data is retained.
#[cfg(unix)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn wm_gif_probe_fd_limited(
    descriptor: i32,
    max_decoded_bytes: u64,
    max_encoded_bytes: u64,
    out: *mut WMGifInfo,
) -> i32 {
    use std::os::fd::BorrowedFd;
    if descriptor < 0 || out.is_null() || !out.is_aligned() {
        return 1;
    }
    // SAFETY: The caller keeps this descriptor open for the documented duration.
    let borrowed = unsafe { BorrowedFd::borrow_raw(descriptor) };
    let owned = match borrowed.try_clone_to_owned() {
        Ok(owned) => owned,
        Err(_) => return 1,
    };
    let file = std::fs::File::from(owned);
    match probe_gif_file_with_limits(&file, max_decoded_bytes, max_encoded_bytes) {
        Ok(info) => {
            // SAFETY: The caller provides aligned writable output storage.
            unsafe {
                out.write(WMGifInfo {
                    width: info.width,
                    height: info.height,
                    frames: info.frames,
                    decoded_bytes: info.decoded_bytes,
                });
            }
            0
        }
        Err(GifError::EncodedBudgetExceeded) => 4,
        Err(GifError::BudgetExceeded) => 2,
        Err(GifError::StructureBudgetExceeded) => 3,
        Err(_) => 1,
    }
}

#[cfg(test)]
mod work_budget_tests;

#[cfg(test)]
mod tests {
    use super::*;

    // Real 1x1 GIF with a two-color global palette and a valid LZW pixel stream.
    const ONE: &[u8] = b"GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff\x2c\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02\x44\x01\x00\x3b";
    const IMAGE: &[u8] = b"\x2c\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02\x44\x01\x00";

    #[test]
    fn bounded_probe_stops_before_rejected_tail_and_preserves_output() {
        assert_eq!(probe_gif_with_budget(ONE, 4), probe_gif(ONE));
        assert_eq!(probe_gif_with_budget(ONE, 3), Err(GifError::BudgetExceeded));
        let mut truncated_animation = ONE[..ONE.len() - 1].to_vec();
        truncated_animation.extend_from_slice(IMAGE);
        // No trailer: over-budget scans reject without parsing the tail. A scan
        // within budget must still validate the rest and report truncation.
        assert_eq!(
            probe_gif_with_budget(&truncated_animation, 7),
            Err(GifError::BudgetExceeded)
        );
        assert_eq!(
            probe_gif_with_budget(&truncated_animation, 8),
            Err(GifError::Truncated)
        );
        let mut out = WMGifInfo {
            width: 9,
            height: 8,
            frames: 7,
            decoded_bytes: 6,
        };
        let previous = out;
        assert_eq!(
            unsafe { wm_gif_probe_bounded(ONE.as_ptr(), ONE.len(), 3, &mut out) },
            2
        );
        assert_eq!(out, previous);
        assert_eq!(
            unsafe { wm_gif_probe_bounded(ONE.as_ptr(), ONE.len(), 4, &mut out) },
            0
        );
        assert_eq!(out.decoded_bytes, 4);
    }

    #[test]
    fn real_single_and_two_frame_gifs() {
        assert_eq!(
            probe_gif(ONE),
            Ok(GifInfo {
                width: 1,
                height: 1,
                frames: 1,
                decoded_bytes: 4
            })
        );
        let mut animation = ONE[..ONE.len() - 1].to_vec();
        animation.extend_from_slice(b"\x21\xf9\x04\x00\x0a\x00\x00\x00");
        animation.extend_from_slice(IMAGE);
        animation.push(0x3b);
        assert_eq!(probe_gif(&animation).unwrap().decoded_bytes, 8);
        assert_eq!(probe_gif(&animation).unwrap().frames, 2);
        animation[3] = b'8';
        animation[4] = b'7';
        assert!(probe_gif(&animation).is_ok());
    }

    #[test]
    fn every_truncated_prefix_is_rejected_without_panicking() {
        for end in 0..ONE.len() {
            assert!(probe_gif(&ONE[..end]).is_err(), "prefix {end}");
        }
        let mut invalid = ONE.to_vec();
        invalid[0] = b'X';
        assert_eq!(probe_gif(&invalid), Err(GifError::InvalidHeader));
        assert_eq!(
            probe_gif(b"GIF89a\x01\x00\x01\x00\x00\x00\x00\x3b"),
            Err(GifError::NoFrames)
        );
    }

    #[test]
    fn skips_local_palette_and_multi_subblock_extensions() {
        let mut gif = b"GIF89a\x01\x00\x01\x00\x00\x00\x00".to_vec();
        gif.extend_from_slice(b"\x21\xff\x0bNETSCAPE2.0\x03\x01\x00\x00\x00");
        gif.extend_from_slice(b"\x21\xfe\x03abc\x02de\x00");
        gif.extend_from_slice(
            b"\x21\x01\x0c\x00\x00\x00\x00\x01\x00\x01\x00\x01\x01\x00\x01\x01x\x00",
        );
        gif.extend_from_slice(b"\x2c\x00\x00\x00\x00\x01\x00\x01\x00\x80\x00\x00\x00\xff\xff\xff\x02\x01\x44\x01\x01\x00\x3b");
        assert_eq!(probe_gif(&gif).unwrap().frames, 1);
        for end in 13..gif.len() {
            assert!(probe_gif(&gif[..end]).is_err(), "prefix {end}");
        }
    }

    #[test]
    fn dimensions_and_canvas_estimate_are_conservative() {
        let mut gif = ONE.to_vec();
        gif[6..10].copy_from_slice(&[0xff, 0xff, 0xff, 0xff]);
        assert_eq!(probe_gif(&gif).unwrap().decoded_bytes, 65535u64 * 65535 * 4);
        gif[6..8].copy_from_slice(&[0, 0]);
        assert_eq!(probe_gif(&gif), Err(GifError::InvalidDimensions));
        gif = ONE.to_vec();
        gif[24..26].copy_from_slice(&[0, 0]);
        assert_eq!(probe_gif(&gif), Err(GifError::InvalidDimensions));
        gif = ONE.to_vec();
        gif[20] = 1;
        assert_eq!(probe_gif(&gif), Err(GifError::FrameOutsideCanvas));
        assert_eq!(
            decoded_size(u32::MAX, u32::MAX, u32::MAX),
            Err(GifError::Overflow)
        );
    }

    #[test]
    fn rejects_malformed_blocks_and_missing_image_payload() {
        let mut gif = ONE.to_vec();
        gif[29] = 1;
        assert_eq!(probe_gif(&gif), Err(GifError::InvalidBlock));
        gif = ONE.to_vec();
        gif[30] = 0;
        assert_eq!(probe_gif(&gif), Err(GifError::InvalidBlock));
        gif = ONE.to_vec();
        gif[19] = 0;
        assert_eq!(probe_gif(&gif), Err(GifError::InvalidBlock));
        let mut extension = ONE[..19].to_vec();
        extension.extend_from_slice(b"\x21\xf9\x03abc\x00");
        extension.extend_from_slice(&ONE[19..]);
        assert_eq!(probe_gif(&extension), Err(GifError::InvalidBlock));
    }

    #[test]
    fn ffi_returns_info_and_preserves_output_on_failure() {
        let mut output = WMGifInfo::default();
        assert_eq!(
            unsafe { wm_gif_probe(ONE.as_ptr(), ONE.len(), &mut output) },
            0
        );
        assert_eq!(
            output,
            WMGifInfo {
                width: 1,
                height: 1,
                frames: 1,
                decoded_bytes: 4
            }
        );
        let previous = output;
        assert_eq!(unsafe { wm_gif_probe(ONE.as_ptr(), 0, &mut output) }, 1);
        assert_eq!(
            unsafe { wm_gif_probe(core::ptr::null(), 1, &mut output) },
            1
        );
        assert_eq!(
            unsafe { wm_gif_probe(ONE.as_ptr(), ONE.len(), core::ptr::null_mut()) },
            1
        );
        assert_eq!(
            unsafe { wm_gif_probe(ONE.as_ptr(), usize::MAX, &mut output) },
            1
        );
        assert_eq!(output, previous);
    }
}

#[cfg(test)]
mod input_budget_tests;
