use super::*;
use std::borrow::Cow;

const RED: Pixel = [255, 0, 0, 255];
const BLUE: Pixel = [0, 0, 255, 255];
const GREEN: Pixel = [0, 255, 0, 255];
const CLEAR: Pixel = [0; 4];
const PALETTE: &[u8] = &[0, 0, 0, 255, 0, 0, 0, 0, 255, 0, 255, 0];
fn encoded(width: u16, height: u16, frames: &[gif::Frame<'_>]) -> Vec<u8> {
    let mut bytes = Vec::new();
    let mut encoder = gif::Encoder::new(&mut bytes, width, height, PALETTE).unwrap();
    encoder.set_repeat(gif::Repeat::Infinite).unwrap();
    for frame in frames {
        encoder.write_frame(frame).unwrap();
    }
    encoder.into_inner().unwrap();
    bytes
}
fn frame(width: u16, height: u16, pixels: &[u8], disposal: gif::DisposalMethod) -> gif::Frame<'_> {
    gif::Frame {
        width,
        height,
        buffer: Cow::Borrowed(pixels),
        dispose: disposal,
        transparent: Some(0),
        ..gif::Frame::default()
    }
}

#[test]
fn real_lzw_frames_compose_partial_previous_background_and_local_palette() {
    let first = frame(3, 2, &[1, 2, 3, 3, 2, 1], gif::DisposalMethod::Keep);
    let mut overlay = frame(2, 2, &[1, 0, 0, 1], gif::DisposalMethod::Previous);
    overlay.left = 1;
    overlay.palette = Some(vec![0, 0, 0, 255, 255, 255]);
    overlay.delay = 7;
    let mut bottom = frame(1, 1, &[2], gif::DisposalMethod::Background);
    bottom.left = 1;
    bottom.top = 1;
    let empty = frame(3, 2, &[0; 6], gif::DisposalMethod::Keep);
    let bytes = encoded(3, 2, &[first, overlay, bottom, empty]);
    let animation = decode(&bytes, DecodeLimits::default()).unwrap();
    assert_eq!(
        (
            animation.width(),
            animation.height(),
            animation.frames().len(),
            animation.payload_bytes()
        ),
        (3, 2, 4, 96)
    );
    assert_eq!(animation.repetitions(), Repetitions::Infinite);
    assert_eq!(
        animation.frames()[0].pixels(),
        &[RED, BLUE, GREEN, GREEN, BLUE, RED]
    );
    assert_eq!(
        animation.frames()[1].pixels(),
        &[RED, [255; 4], GREEN, GREEN, BLUE, [255; 4]]
    );
    assert_eq!(animation.frames()[1].delay_centiseconds(), 7);
    assert_eq!(
        animation.frames()[2].pixels(),
        &[RED, BLUE, GREEN, GREEN, BLUE, RED]
    );
    assert_eq!(
        animation.frames()[3].pixels(),
        &[RED, BLUE, GREEN, GREEN, CLEAR, RED]
    );
}

#[test]
fn interlaced_rows_are_deinterlaced_before_composition() {
    // GIF passes for five rows: 0, 4, 2, 1, 3.
    let mut interlaced = frame(1, 5, &[1, 2, 3, 2, 1], gif::DisposalMethod::Keep);
    interlaced.interlaced = true;
    let bytes = encoded(1, 5, &[interlaced]);
    let animation = decode(&bytes, DecodeLimits::default()).unwrap();
    assert_eq!(
        animation.frames()[0].pixels(),
        &[RED, BLUE, GREEN, RED, BLUE]
    );
}

#[test]
fn raw_zero_and_long_delays_are_not_silently_normalized() {
    let zero = frame(1, 1, &[1], gif::DisposalMethod::Keep);
    let mut long = frame(1, 1, &[2], gif::DisposalMethod::Keep);
    long.delay = u16::MAX;
    let bytes = encoded(1, 1, &[zero, long]);
    let animation = decode(&bytes, DecodeLimits::default()).unwrap();
    assert_eq!(
        animation
            .frames()
            .iter()
            .map(|f| f.delay_centiseconds())
            .collect::<Vec<_>>(),
        [0, u16::MAX]
    );
}

#[test]
fn working_budget_counts_retained_frames_indices_and_transition_backups() {
    let bytes = encoded(
        1,
        1,
        &[
            frame(1, 1, &[1], gif::DisposalMethod::Previous),
            frame(1, 1, &[2], gif::DisposalMethod::Previous),
        ],
    );
    let limits = DecodeLimits {
        working_bytes: 21,
        ..DecodeLimits::default()
    };
    assert_eq!(decode(&bytes, limits).unwrap().payload_bytes(), 8);
    assert!(matches!(
        decode(
            &bytes,
            DecodeLimits {
                working_bytes: 20,
                ..limits
            }
        ),
        Err(DecodeError::WorkingBudget)
    ));
    let bytes = encoded(
        1,
        1,
        &[
            frame(1, 1, &[1], gif::DisposalMethod::Keep),
            frame(1, 1, &[2], gif::DisposalMethod::Keep),
        ],
    );
    assert!(
        decode(
            &bytes,
            DecodeLimits {
                working_bytes: 13,
                ..limits
            }
        )
        .is_ok()
    );
    assert!(matches!(
        decode(
            &bytes,
            DecodeLimits {
                working_bytes: 12,
                ..limits
            }
        ),
        Err(DecodeError::WorkingBudget)
    ));
}

#[test]
fn preflight_and_frame_admission_reject_before_decode() {
    let bytes = encoded(1, 1, &[frame(1, 1, &[1], gif::DisposalMethod::Keep)]);
    let limits = DecodeLimits {
        encoded_bytes: bytes.len(),
        decoded_bytes: 4,
        frames: 1,
        ..DecodeLimits::default()
    };
    assert!(decode(&bytes, limits).is_ok());
    assert!(matches!(
        decode(
            &bytes,
            DecodeLimits {
                encoded_bytes: bytes.len() - 1,
                ..limits
            }
        ),
        Err(DecodeError::Preflight(GifError::EncodedBudgetExceeded))
    ));
    assert!(matches!(
        decode(
            &bytes,
            DecodeLimits {
                decoded_bytes: 3,
                ..limits
            }
        ),
        Err(DecodeError::Preflight(GifError::BudgetExceeded))
    ));
    assert!(matches!(
        decode(
            &bytes,
            DecodeLimits {
                frames: 0,
                ..limits
            }
        ),
        Err(DecodeError::FrameLimit)
    ));
    for length in 0..bytes.len() {
        assert!(decode(&bytes[..length], limits).is_err());
    }
}

#[test]
fn structurally_valid_but_invalid_lzw_cannot_publish_animation() {
    let bytes = b"GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff\x2c\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02\xff\xff\x00\x3b";
    assert!(crate::probe_gif(bytes).is_ok());
    assert!(matches!(
        decode(bytes, DecodeLimits::default()),
        Err(DecodeError::InvalidData)
    ));
}

#[test]
fn ancillary_metadata_is_bounded_even_for_tiny_canvas() {
    let source = encoded(1, 1, &[frame(1, 1, &[1], gif::DisposalMethod::Keep)]);
    // Header (13) plus four-entry global palette (12).
    let mut bytes = source[..25].to_vec();
    bytes.extend_from_slice(b"\x21\xff\x0bXMP DataXMP");
    for _ in 0..5 {
        bytes.push(255);
        bytes.extend_from_slice(&[42; 255]);
    }
    bytes.push(0);
    bytes.extend_from_slice(&source[25..]);
    assert!(crate::probe_gif(&bytes).is_ok());
    assert!(matches!(
        decode(&bytes, DecodeLimits::default()),
        Err(DecodeError::InvalidData)
    ));
}

#[test]
fn lzw_without_end_code_is_rejected_even_when_pixel_count_is_complete() {
    // Clear + pixel0, but no end code. The structure-only inspector accepts it.
    let bytes = b"GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff\x2c\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x01\x04\x00\x3b";
    assert!(crate::probe_gif(bytes).is_ok());
    assert!(matches!(
        decode(bytes, DecodeLimits::default()),
        Err(DecodeError::InvalidData)
    ));
}

#[test]
fn preserves_bounded_icc_bytes_without_claiming_to_apply_color_conversion() {
    let source = encoded(1, 1, &[frame(1, 1, &[1], gif::DisposalMethod::Keep)]);
    let mut bytes = source[..25].to_vec();
    bytes.extend_from_slice(b"\x21\xff\x0bICCRGBG1012\x04test\x00");
    bytes.extend_from_slice(&source[25..]);
    let animation = decode(&bytes, DecodeLimits::default()).unwrap();
    assert_eq!(animation.icc_profile(), Some(&b"test"[..]));
    assert_eq!(animation.frames()[0].pixels(), &[RED]);
    assert!(
        decode(&source, DecodeLimits::default())
            .unwrap()
            .icc_profile()
            .is_none()
    );
}

#[test]
fn retained_icc_copy_has_an_inclusive_one_mebibyte_limit() {
    let indices = vec![1; 1025 * 1025];
    let source = encoded(
        1025,
        1025,
        &[frame(1025, 1025, &indices, gif::DisposalMethod::Keep)],
    );
    for length in [1024 * 1024, 1024 * 1024 + 1] {
        let mut bytes = source[..25].to_vec();
        bytes.extend_from_slice(b"\x21\xff\x0bICCRGBG1012");
        let mut remaining = length;
        while remaining > 0 {
            let count = remaining.min(255);
            bytes.push(count as u8);
            bytes.resize(bytes.len() + count, 42);
            remaining -= count;
        }
        bytes.push(0);
        bytes.extend_from_slice(&source[25..]);
        let result = decode(&bytes, DecodeLimits::default());
        if length == 1024 * 1024 {
            assert_eq!(result.unwrap().icc_profile().unwrap().len(), length);
        } else {
            assert!(matches!(result, Err(DecodeError::ProfileLimit)));
        }
    }
}
