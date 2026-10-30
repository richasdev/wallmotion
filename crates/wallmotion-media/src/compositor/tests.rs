use super::*;

const CLEAR: Pixel = [0, 0, 0, 0];
const RED: Pixel = [255, 0, 0, 255];
const BLUE: Pixel = [0, 0, 255, 255];
const GREEN: Pixel = [0, 255, 0, 255];
const PALETTE: [[u8; 3]; 4] = [[0, 0, 0], [255, 0, 0], [0, 0, 255], [0, 255, 0]];
const FULL: FrameRect = FrameRect {
    left: 0,
    top: 0,
    width: 2,
    height: 2,
};
fn frame(rect: FrameRect, indices: &[u8], disposal: Disposal) -> IndexedFrame<'_> {
    IndexedFrame {
        rect,
        indices,
        palette: &PALETTE,
        transparent: Some(0),
        disposal,
    }
}

#[test]
fn partial_frames_keep_pixels_and_transparency_skips_destination() {
    let mut screen = Compositor::new(2, 2, CLEAR, 64).unwrap();
    screen
        .compose(frame(FULL, &[1; 4], Disposal::Keep))
        .unwrap();
    screen
        .compose(frame(
            FrameRect {
                left: 1,
                top: 0,
                width: 1,
                height: 2,
            },
            &[2, 0],
            Disposal::Keep,
        ))
        .unwrap();
    assert_eq!(screen.pixels(), &[RED, BLUE, RED, RED]);
    assert_eq!(
        (
            screen.width(),
            screen.height(),
            screen.owned_payload_bytes()
        ),
        (2, 2, 16)
    );
}

#[test]
fn background_disposes_only_old_rectangle_to_explicit_rgba_background() {
    let background = [9, 8, 7, 128];
    let mut screen = Compositor::new(2, 2, background, 64).unwrap();
    screen
        .compose(frame(FULL, &[1; 4], Disposal::Keep))
        .unwrap();
    screen
        .compose(frame(
            FrameRect {
                left: 1,
                top: 0,
                width: 1,
                height: 1,
            },
            &[2],
            Disposal::Background,
        ))
        .unwrap();
    assert_eq!(screen.pixels(), &[RED, BLUE, RED, RED]);
    screen
        .compose(frame(
            FrameRect {
                left: 0,
                top: 1,
                width: 1,
                height: 1,
            },
            &[3],
            Disposal::Keep,
        ))
        .unwrap();
    assert_eq!(screen.pixels(), &[RED, background, GREEN, RED]);
}

#[test]
fn repeated_overlapping_previous_saves_after_disposing_old_frame() {
    let mut screen = Compositor::new(2, 2, CLEAR, 64).unwrap();
    let corner = FrameRect {
        left: 0,
        top: 0,
        width: 1,
        height: 1,
    };
    screen
        .compose(frame(FULL, &[1; 4], Disposal::Keep))
        .unwrap();
    screen
        .compose(frame(corner, &[2], Disposal::Previous))
        .unwrap();
    assert_eq!(screen.pixels(), &[BLUE, RED, RED, RED]);
    assert_eq!(screen.owned_payload_bytes(), 20);
    screen
        .compose(frame(corner, &[3], Disposal::Previous))
        .unwrap();
    assert_eq!(screen.pixels(), &[GREEN, RED, RED, RED]);
    screen
        .compose(frame(FULL, &[0; 4], Disposal::Keep))
        .unwrap();
    assert_eq!(screen.pixels(), &[RED; 4]);
    assert_eq!(screen.owned_payload_bytes(), 16);
}

#[test]
fn invalid_palette_index_does_not_consume_pending_disposal() {
    let mut screen = Compositor::new(2, 2, CLEAR, 64).unwrap();
    screen
        .compose(frame(FULL, &[1; 4], Disposal::Background))
        .unwrap();
    assert_eq!(
        screen.compose(frame(FULL, &[1, 1, 1, 255], Disposal::Keep)),
        Err(CompositionError::UnknownPaletteIndex)
    );
    assert_eq!(screen.pixels(), &[RED; 4]);
    screen
        .compose(frame(
            FrameRect {
                left: 0,
                top: 0,
                width: 1,
                height: 1,
            },
            &[3],
            Disposal::Keep,
        ))
        .unwrap();
    assert_eq!(screen.pixels(), &[GREEN, CLEAR, CLEAR, CLEAR]);
}

#[test]
fn budget_accounts_old_and_new_backups_before_any_state_change() {
    let mut screen = Compositor::new(2, 2, CLEAR, 47).unwrap();
    screen
        .compose(frame(FULL, &[1; 4], Disposal::Previous))
        .unwrap();
    assert_eq!(screen.owned_payload_bytes(), 32);
    assert_eq!(
        screen.compose(frame(FULL, &[2; 4], Disposal::Previous)),
        Err(CompositionError::BudgetExceeded)
    );
    assert_eq!(screen.pixels(), &[RED; 4]);
    assert_eq!(screen.owned_payload_bytes(), 32);
    screen
        .compose(frame(FULL, &[0; 4], Disposal::Keep))
        .unwrap();
    assert_eq!(screen.pixels(), &[CLEAR; 4]);
    let mut exact = Compositor::new(2, 2, CLEAR, 48).unwrap();
    exact
        .compose(frame(FULL, &[1; 4], Disposal::Previous))
        .unwrap();
    exact
        .compose(frame(FULL, &[2; 4], Disposal::Previous))
        .unwrap();
    assert_eq!(exact.pixels(), &[BLUE; 4]);
}

#[test]
fn validation_rejects_bad_geometry_lengths_and_palettes_without_mutation() {
    let mut screen = Compositor::new(2, 2, CLEAR, 64).unwrap();
    for (rect, indices, expected) in [
        (
            FrameRect {
                left: usize::MAX,
                ..FULL
            },
            &[1; 4][..],
            CompositionError::Overflow,
        ),
        (
            FrameRect { left: 1, ..FULL },
            &[1; 4][..],
            CompositionError::OutsideCanvas,
        ),
        (
            FrameRect { width: 0, ..FULL },
            &[][..],
            CompositionError::InvalidDimensions,
        ),
        (FULL, &[1][..], CompositionError::InvalidBuffer),
    ] {
        assert_eq!(
            screen.compose(frame(rect, indices, Disposal::Keep)),
            Err(expected)
        );
        assert_eq!(screen.pixels(), &[CLEAR; 4]);
    }
    let mut invalid = frame(FULL, &[1; 4], Disposal::Keep);
    invalid.palette = &[];
    assert_eq!(
        screen.compose(invalid),
        Err(CompositionError::InvalidPalette)
    );
}

#[test]
fn transparent_index_can_be_outside_palette_without_being_looked_up() {
    let mut screen = Compositor::new(2, 2, RED, 64).unwrap();
    let mut transparent = frame(FULL, &[255; 4], Disposal::Keep);
    transparent.transparent = Some(255);
    screen.compose(transparent).unwrap();
    assert_eq!(screen.pixels(), &[RED; 4]);
}

#[test]
fn constructor_checks_dimensions_overflow_and_budget_before_allocation() {
    assert!(matches!(
        Compositor::new(0, 1, CLEAR, 64),
        Err(CompositionError::InvalidDimensions)
    ));
    assert!(matches!(
        Compositor::new(usize::MAX, 2, CLEAR, usize::MAX),
        Err(CompositionError::Overflow)
    ));
    assert!(matches!(
        Compositor::new(2, 2, CLEAR, 15),
        Err(CompositionError::BudgetExceeded)
    ));
}

#[test]
fn non_square_canvas_restores_offset_rectangle_with_correct_row_stride() {
    let mut screen = Compositor::new(3, 2, CLEAR, 48).unwrap();
    let whole = FrameRect {
        left: 0,
        top: 0,
        width: 3,
        height: 2,
    };
    let right = FrameRect {
        left: 1,
        top: 0,
        width: 2,
        height: 2,
    };
    screen
        .compose(frame(whole, &[1, 2, 3, 3, 2, 1], Disposal::Keep))
        .unwrap();
    let original = [RED, BLUE, GREEN, GREEN, BLUE, RED];
    screen
        .compose(frame(right, &[3, 1, 1, 3], Disposal::Previous))
        .unwrap();
    assert_eq!(screen.pixels(), &[RED, GREEN, RED, GREEN, RED, GREEN]);
    // 24-byte canvas plus only the 16-byte rectangle, not a full 24-byte backup.
    assert_eq!(screen.owned_payload_bytes(), 40);
    // A malformed next frame must preserve the saved pre-draw rectangle, too.
    assert_eq!(
        screen.compose(frame(whole, &[1; 5], Disposal::Keep)),
        Err(CompositionError::InvalidBuffer)
    );
    screen
        .compose(frame(whole, &[0; 6], Disposal::Keep))
        .unwrap();
    assert_eq!(screen.pixels(), &original);
    assert_eq!(screen.owned_payload_bytes(), 24);
    let bottom = FrameRect {
        left: 1,
        top: 1,
        width: 2,
        height: 1,
    };
    screen
        .compose(frame(bottom, &[1, 3], Disposal::Background))
        .unwrap();
    screen
        .compose(frame(whole, &[0; 6], Disposal::Keep))
        .unwrap();
    assert_eq!(screen.pixels(), &[RED, BLUE, GREEN, GREEN, CLEAR, CLEAR]);
}

#[test]
fn rejects_oversized_palette_and_bottom_overflow_without_consuming_previous() {
    let mut screen = Compositor::new(2, 2, CLEAR, 48).unwrap();
    screen
        .compose(frame(FULL, &[1; 4], Disposal::Previous))
        .unwrap();
    let palette = [[1, 2, 3]; 257];
    let mut invalid = frame(FULL, &[1; 4], Disposal::Keep);
    invalid.palette = &palette;
    assert_eq!(
        screen.compose(invalid),
        Err(CompositionError::InvalidPalette)
    );
    assert_eq!(
        screen.compose(frame(
            FrameRect {
                top: usize::MAX,
                ..FULL
            },
            &[1; 4],
            Disposal::Keep
        )),
        Err(CompositionError::Overflow)
    );
    assert_eq!(screen.pixels(), &[RED; 4]);
    assert_eq!(screen.owned_payload_bytes(), 32);
    screen
        .compose(frame(FULL, &[0; 4], Disposal::Keep))
        .unwrap();
    assert_eq!(screen.pixels(), &[CLEAR; 4]);
}
