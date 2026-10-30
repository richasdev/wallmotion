use super::*;

const ONE: &[u8] = b"GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff\x2c\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02\x44\x01\x00\x3b";
fn decoded() -> *const WMGifAnimation {
    let mut handle = ptr::null();
    // SAFETY: Fixture input and output storage satisfy decode's contract.
    assert_eq!(
        unsafe { wm_gif_animation_decode(ONE.as_ptr(), ONE.len(), 1024, 4, 64, 1, &mut handle) },
        0
    );
    handle
}

#[test]
fn native_reference_owns_pixels_until_final_balanced_release() {
    let handle = decoded();
    // SAFETY: Reconstruct temporarily, then return exactly the same reference to ABI.
    let owner = unsafe { Arc::from_raw(handle) };
    let weak = Arc::downgrade(&owner);
    assert_eq!(Arc::into_raw(owner), handle);
    // SAFETY: Initial owned reference is alive throughout retain/read.
    let retained = unsafe { wm_gif_animation_retain(handle) };
    let mut view = WMGifFrameView {
        pixels: ptr::null(),
        length: 0,
        delay_centiseconds: 99,
    };
    // SAFETY: Both owned references are live; output is aligned and disjoint.
    assert_eq!(unsafe { wm_gif_animation_frame(handle, 0, &mut view) }, 0);
    assert_eq!((view.length, view.delay_centiseconds), (4, 0));
    // SAFETY: Consume only the first reference, leaving retained alive.
    unsafe { wm_gif_animation_release(handle) };
    assert!(weak.upgrade().is_some());
    // SAFETY: The retained reference still owns this borrowed pixel slice.
    assert_eq!(
        unsafe { std::slice::from_raw_parts(view.pixels, view.length) },
        &[0, 0, 0, 255]
    );
    // SAFETY: Consume the remaining owned reference, with no further pixel use.
    unsafe { wm_gif_animation_release(retained) };
    assert!(weak.upgrade().is_none());
}

#[test]
fn getters_and_decode_failures_preserve_outputs_and_allow_null_release() {
    let handle = decoded();
    let mut output = handle;
    // SAFETY: Input/output valid; budget rejection must preserve output.
    assert_eq!(
        unsafe { wm_gif_animation_decode(ONE.as_ptr(), ONE.len(), 1, 4, 64, 1, &mut output) },
        4
    );
    assert_eq!(output, handle);
    // SAFETY: Null input is explicitly rejected without dereference.
    assert_eq!(
        unsafe { wm_gif_animation_decode(ptr::null(), 0, 1024, 4, 64, 1, &mut output) },
        1
    );
    let mut view = WMGifFrameView {
        pixels: ptr::null(),
        length: 777,
        delay_centiseconds: 99,
    };
    let previous = view;
    // SAFETY: Handle and output valid; index outside bounds is rejected.
    assert_eq!(
        unsafe { wm_gif_animation_frame(handle, u32::MAX, &mut view) },
        8
    );
    assert_eq!(view, previous);
    let mut info = WMGifAnimationInfo::default();
    // SAFETY: Null handle is rejected and valid out remains unchanged.
    assert_eq!(unsafe { wm_gif_animation_info(ptr::null(), &mut info) }, 1);
    assert_eq!(info, WMGifAnimationInfo::default());
    // SAFETY: Null output is explicitly rejected; valid metadata output follows.
    assert_eq!(unsafe { wm_gif_animation_info(handle, ptr::null_mut()) }, 1);
    assert_eq!(unsafe { wm_gif_animation_info(handle, &mut info) }, 0);
    assert_eq!(
        (info.width, info.height, info.frames, info.decoded_bytes),
        (1, 1, 1, 4)
    );
    let mut profile = WMGifByteView {
        bytes: ptr::null(),
        length: 1,
    };
    // SAFETY: Live handle and aligned output; absent ICC is null/zero.
    assert_eq!(unsafe { wm_gif_animation_icc(handle, &mut profile) }, 0);
    assert_eq!(
        profile,
        WMGifByteView {
            bytes: ptr::null(),
            length: 0
        }
    );
    // SAFETY: Null retain/release are permitted; balance the real handle once.
    unsafe {
        assert!(wm_gif_animation_retain(ptr::null()).is_null());
        wm_gif_animation_release(ptr::null());
        wm_gif_animation_release(handle);
    }
}

#[test]
fn concurrent_getters_keep_independent_references_to_the_same_pixels() {
    let raw = decoded();
    // SAFETY: Take ownership of the single reference returned by decode.
    let owner = unsafe { Arc::from_raw(raw) };
    let mut tasks = Vec::new();
    for _ in 0..4 {
        let worker = Arc::clone(&owner);
        tasks.push(std::thread::spawn(move || {
            let pointer = Arc::as_ptr(&worker);
            let mut address = 0;
            for _ in 0..100 {
                // SAFETY: worker owns a reference throughout this getter/retain cycle.
                let retained = unsafe { wm_gif_animation_retain(pointer) };
                let mut view = WMGifFrameView {
                    pixels: ptr::null(),
                    length: 0,
                    delay_centiseconds: 0,
                };
                // SAFETY: retained is live and output is aligned writable storage.
                assert_eq!(unsafe { wm_gif_animation_frame(retained, 0, &mut view) }, 0);
                address = view.pixels as usize;
                // SAFETY: Consume only the reference acquired in this iteration.
                unsafe { wm_gif_animation_release(retained) };
            }
            address
        }));
    }
    let addresses: Vec<_> = tasks.into_iter().map(|task| task.join().unwrap()).collect();
    assert!(addresses.iter().all(|address| *address == addresses[0]));
    assert_eq!(Arc::strong_count(&owner), 1);
}
