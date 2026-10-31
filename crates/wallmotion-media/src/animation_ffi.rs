use crate::GifError;
use crate::animation::{self, Animation, DecodeError, DecodeLimits, Repetitions};
use crate::compositor::CompositionError;
use std::ptr;
use std::sync::Arc;

/// Opaque C ABI object. No mutation is exposed after publication.
pub struct WMGifAnimation {
    animation: Animation,
}

#[repr(C)]
#[derive(Clone, Copy, Default, Debug, PartialEq, Eq)]
pub struct WMGifAnimationInfo {
    pub width: u32,
    pub height: u32,
    pub frames: u32,
    pub decoded_bytes: u64,
    pub repeat_count: u16,
    pub repeat_infinite: u8,
}
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct WMGifFrameView {
    pub pixels: *const u8,
    pub length: usize,
    pub delay_centiseconds: u16,
}
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct WMGifByteView {
    pub bytes: *const u8,
    pub length: usize,
}

pub(crate) fn status(error: DecodeError) -> i32 {
    match error {
        DecodeError::Preflight(GifError::EncodedBudgetExceeded) => 4,
        DecodeError::Preflight(GifError::StructureBudgetExceeded) => 3,
        DecodeError::Preflight(GifError::BudgetExceeded)
        | DecodeError::WorkingBudget
        | DecodeError::Composition(CompositionError::BudgetExceeded) => 2,
        DecodeError::FrameLimit => 5,
        DecodeError::AllocationFailure
        | DecodeError::Overflow
        | DecodeError::Composition(
            CompositionError::AllocationFailure | CompositionError::Overflow,
        ) => 6,
        DecodeError::ProfileLimit => 7,
        _ => 1,
    }
}

/// # Safety
/// bytes must name len readable bytes, immutable throughout the call, and out
/// must be valid aligned writable storage disjoint from them. Output is unchanged
/// on failure. A successful handle owns one reference, consumed by release.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn wm_gif_animation_decode(
    bytes: *const u8,
    len: usize,
    max_encoded: u64,
    max_decoded: u64,
    max_working: u64,
    max_frames: u32,
    out: *mut *const WMGifAnimation,
) -> i32 {
    if bytes.is_null() || out.is_null() || len > isize::MAX as usize {
        return 1;
    }
    if len as u64 > max_encoded {
        return 4;
    }
    let (Ok(encoded_bytes), Ok(working_bytes)) =
        (usize::try_from(max_encoded), usize::try_from(max_working))
    else {
        return 6;
    };
    // SAFETY: The caller guarantees a readable immutable region; basic slice
    // prerequisites are checked above. It is borrowed only for this call.
    let data = unsafe { std::slice::from_raw_parts(bytes, len) };
    match animation::decode(
        data,
        DecodeLimits {
            encoded_bytes,
            decoded_bytes: max_decoded,
            working_bytes,
            frames: max_frames as usize,
        },
    ) {
        Ok(animation) => {
            let owned = Arc::into_raw(Arc::new(WMGifAnimation { animation }));
            // SAFETY: Valid, aligned, disjoint output storage is the caller's contract.
            unsafe { ptr::write(out, owned) };
            0
        }
        Err(error) => status(error),
    }
}

/// # Safety
/// descriptor stays open for this call. out is aligned writable storage, not
/// aliasing the file or live handles. All failures preserve out. The duplicated
/// descriptor is closed on return; no file mapping or input storage is retained.
#[cfg(unix)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn wm_gif_animation_decode_fd(
    descriptor: i32,
    max_encoded: u64,
    max_decoded: u64,
    max_working: u64,
    max_frames: u32,
    out: *mut *const WMGifAnimation,
) -> i32 {
    use crate::animation_file::{self, FileDecodeError};
    use std::os::fd::BorrowedFd;
    if descriptor < 0 || out.is_null() || !out.is_aligned() {
        return 1;
    }
    let (Ok(encoded_bytes), Ok(working_bytes)) =
        (usize::try_from(max_encoded), usize::try_from(max_working))
    else {
        return 6;
    };
    // SAFETY: Caller keeps the descriptor open throughout duplication and use.
    let borrowed = unsafe { BorrowedFd::borrow_raw(descriptor) };
    let Ok(owned) = borrowed.try_clone_to_owned() else {
        return 1;
    };
    let file = std::fs::File::from(owned);
    match animation_file::decode_file(
        &file,
        DecodeLimits {
            encoded_bytes,
            decoded_bytes: max_decoded,
            working_bytes,
            frames: max_frames as usize,
        },
    ) {
        Ok(animation) => {
            let owned = Arc::into_raw(Arc::new(WMGifAnimation { animation }));
            // SAFETY: The caller supplies aligned writable disjoint output storage.
            unsafe { ptr::write(out, owned) };
            0
        }
        Err(FileDecodeError::Decode(error)) => status(error),
        Err(FileDecodeError::Changed) => 9,
        Err(FileDecodeError::Read) => 1,
    }
}

/// # Safety
/// A non-null handle must have a live owned reference throughout this call.
/// The returned same-address handle owns one additional reference. Null is allowed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn wm_gif_animation_retain(
    handle: *const WMGifAnimation,
) -> *const WMGifAnimation {
    if !handle.is_null() {
        // SAFETY: The caller keeps a strong reference alive until increment completes.
        unsafe { Arc::increment_strong_count(handle) };
    }
    handle
}

/// # Safety
/// Each non-null call consumes exactly one previously acquired reference. It
/// must not race the final release with any borrow/retain that lacks another owner.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn wm_gif_animation_release(handle: *const WMGifAnimation) {
    if !handle.is_null() {
        // SAFETY: Exactly one live reference is transferred back by the caller.
        unsafe { drop(Arc::from_raw(handle)) };
    }
}

/// # Safety
/// A live handle reference must remain held through this call. out is aligned,
/// writable and disjoint from the immutable handle and its storage.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn wm_gif_animation_info(
    handle: *const WMGifAnimation,
    out: *mut WMGifAnimationInfo,
) -> i32 {
    if handle.is_null() || out.is_null() {
        return 1;
    }
    // SAFETY: Caller retains a live immutable animation for the full call.
    let a = &unsafe { &*handle }.animation;
    let (repeat_count, repeat_infinite) = match a.repetitions() {
        Repetitions::Finite(n) => (n, 0),
        Repetitions::Infinite => (0, 1),
    };
    let info = WMGifAnimationInfo {
        width: a.width() as u32,
        height: a.height() as u32,
        frames: a.frames().len() as u32,
        decoded_bytes: a.payload_bytes() as u64,
        repeat_count,
        repeat_infinite,
    };
    // SAFETY: Output is caller-provided aligned writable storage.
    unsafe { ptr::write(out, info) };
    0
}

/// # Safety
/// Same output/handle contract as info. Returned bytes are borrowed, immutable,
/// and valid only while at least one owned handle reference remains alive.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn wm_gif_animation_frame(
    handle: *const WMGifAnimation,
    index: u32,
    out: *mut WMGifFrameView,
) -> i32 {
    if handle.is_null() || out.is_null() {
        return 1;
    }
    // SAFETY: The caller holds a live reference for the call and returned borrow.
    let a = &unsafe { &*handle }.animation;
    let Some(frame) = a.frames().get(index as usize) else {
        return 8;
    };
    let view = WMGifFrameView {
        pixels: frame.pixels().as_ptr().cast(),
        length: frame.pixels().len() * 4,
        delay_centiseconds: frame.delay_centiseconds(),
    };
    // SAFETY: Output is caller-provided aligned writable storage.
    unsafe { ptr::write(out, view) };
    0
}

/// # Safety
/// Same contract as frame. An absent ICC profile is represented by null/zero.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn wm_gif_animation_icc(
    handle: *const WMGifAnimation,
    out: *mut WMGifByteView,
) -> i32 {
    if handle.is_null() || out.is_null() {
        return 1;
    }
    // SAFETY: Caller holds a live reference for the call and returned borrow.
    let a = &unsafe { &*handle }.animation;
    let view = a.icc_profile().map_or(
        WMGifByteView {
            bytes: ptr::null(),
            length: 0,
        },
        |bytes| WMGifByteView {
            bytes: bytes.as_ptr(),
            length: bytes.len(),
        },
    );
    // SAFETY: Output is caller-provided aligned writable storage.
    unsafe { ptr::write(out, view) };
    0
}

#[cfg(test)]
mod tests;
