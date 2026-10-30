//! Pure composition of already decoded, deinterlaced indexed GIF frames.
//! No file, decoder, clock, FFI or application renderer is owned here.

/// Straight (not premultiplied) RGBA, row-major. Consumers choose their surface format.
pub type Pixel = [u8; 4];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Disposal {
    Keep,
    Background,
    Previous,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FrameRect {
    pub left: usize,
    pub top: usize,
    pub width: usize,
    pub height: usize,
}

pub struct IndexedFrame<'a> {
    pub rect: FrameRect,
    /// Row-major, already deinterlaced, exactly width * height indices.
    pub indices: &'a [u8],
    /// Effective local-or-global RGB palette, with 1...256 entries.
    pub palette: &'a [[u8; 3]],
    pub transparent: Option<u8>,
    pub disposal: Disposal,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CompositionError {
    InvalidDimensions,
    OutsideCanvas,
    InvalidBuffer,
    InvalidPalette,
    UnknownPaletteIndex,
    Overflow,
    BudgetExceeded,
    AllocationFailure,
}

enum Pending {
    Keep,
    Background(FrameRect),
    Previous { rect: FrameRect, pixels: Vec<Pixel> },
}

impl Pending {
    fn payload_bytes(&self) -> usize {
        match self {
            Self::Previous { pixels, .. } => pixels.len() * size_of::<Pixel>(),
            _ => 0,
        }
    }
}

/// Budget counts pixel payload owned by this instance, including old/new Previous
/// backups during a transition. Allocator overhead and caller buffers are separate.
pub struct Compositor {
    width: usize,
    height: usize,
    pixels: Vec<Pixel>,
    background: Pixel,
    pending: Pending,
    canvas_bytes: usize,
    owned_bytes: usize,
    maximum_bytes: usize,
}

impl Compositor {
    pub fn new(
        width: usize,
        height: usize,
        background: Pixel,
        maximum_bytes: usize,
    ) -> Result<Self, CompositionError> {
        if width == 0 || height == 0 {
            return Err(CompositionError::InvalidDimensions);
        }
        let count = width
            .checked_mul(height)
            .ok_or(CompositionError::Overflow)?;
        let bytes = count
            .checked_mul(size_of::<Pixel>())
            .ok_or(CompositionError::Overflow)?;
        if bytes > maximum_bytes {
            return Err(CompositionError::BudgetExceeded);
        }
        let pixels = allocate_pixels(count, background)?;
        Ok(Self {
            width,
            height,
            pixels,
            background,
            pending: Pending::Keep,
            canvas_bytes: bytes,
            owned_bytes: bytes,
            maximum_bytes,
        })
    }

    pub fn width(&self) -> usize {
        self.width
    }
    pub fn height(&self) -> usize {
        self.height
    }
    pub fn pixels(&self) -> &[Pixel] {
        &self.pixels
    }
    pub fn owned_payload_bytes(&self) -> usize {
        self.owned_bytes
    }

    /// Rejects all validation/budget/allocation failures before applying pending
    /// disposal. A rejected frame leaves both visible pixels and pending state intact.
    pub fn compose(&mut self, frame: IndexedFrame<'_>) -> Result<(), CompositionError> {
        let count = self.validate(&frame)?;
        let backup_bytes = if frame.disposal == Disposal::Previous {
            count
                .checked_mul(size_of::<Pixel>())
                .ok_or(CompositionError::Overflow)?
        } else {
            0
        };
        let peak = self
            .owned_bytes
            .checked_add(backup_bytes)
            .ok_or(CompositionError::Overflow)?;
        if peak > self.maximum_bytes {
            return Err(CompositionError::BudgetExceeded);
        }
        let mut next = match frame.disposal {
            Disposal::Keep => Pending::Keep,
            Disposal::Background => Pending::Background(frame.rect),
            Disposal::Previous => Pending::Previous {
                rect: frame.rect,
                pixels: allocate_pixels(count, [0; 4])?,
            },
        };
        // All fallible work is complete. Dispose the old frame, then save the
        // pre-draw pixels of the new frame, not the visible old frame's pixels.
        self.apply_pending();
        if let Pending::Previous { rect, pixels } = &mut next {
            self.copy_rect_to(*rect, pixels);
        }
        for row in 0..frame.rect.height {
            let destination = (frame.rect.top + row) * self.width + frame.rect.left;
            let source = row * frame.rect.width;
            for column in 0..frame.rect.width {
                let index = frame.indices[source + column];
                if frame.transparent == Some(index) {
                    continue;
                }
                let [r, g, b] = frame.palette[usize::from(index)];
                self.pixels[destination + column] = [r, g, b, 255];
            }
        }
        // Checked peak above includes the canvas and new backup, even when an
        // old backup was also present. This sum cannot overflow or exceed budget.
        self.owned_bytes = self.canvas_bytes + next.payload_bytes();
        self.pending = next;
        Ok(())
    }

    fn validate(&self, frame: &IndexedFrame<'_>) -> Result<usize, CompositionError> {
        let rect = frame.rect;
        if rect.width == 0 || rect.height == 0 {
            return Err(CompositionError::InvalidDimensions);
        }
        let right = rect
            .left
            .checked_add(rect.width)
            .ok_or(CompositionError::Overflow)?;
        let bottom = rect
            .top
            .checked_add(rect.height)
            .ok_or(CompositionError::Overflow)?;
        if right > self.width || bottom > self.height {
            return Err(CompositionError::OutsideCanvas);
        }
        let count = rect
            .width
            .checked_mul(rect.height)
            .ok_or(CompositionError::Overflow)?;
        if frame.indices.len() != count {
            return Err(CompositionError::InvalidBuffer);
        }
        if frame.palette.is_empty() || frame.palette.len() > 256 {
            return Err(CompositionError::InvalidPalette);
        }
        if frame.indices.iter().any(|&index| {
            frame.transparent != Some(index) && usize::from(index) >= frame.palette.len()
        }) {
            return Err(CompositionError::UnknownPaletteIndex);
        }
        Ok(count)
    }

    fn apply_pending(&mut self) {
        match std::mem::replace(&mut self.pending, Pending::Keep) {
            Pending::Keep => {}
            Pending::Background(rect) => {
                for row in 0..rect.height {
                    let start = (rect.top + row) * self.width + rect.left;
                    self.pixels[start..start + rect.width].fill(self.background);
                }
            }
            Pending::Previous { rect, pixels } => {
                for row in 0..rect.height {
                    let start = (rect.top + row) * self.width + rect.left;
                    let source = row * rect.width;
                    self.pixels[start..start + rect.width]
                        .copy_from_slice(&pixels[source..source + rect.width]);
                }
            }
        }
    }

    fn copy_rect_to(&self, rect: FrameRect, output: &mut [Pixel]) {
        for row in 0..rect.height {
            let start = (rect.top + row) * self.width + rect.left;
            let destination = row * rect.width;
            output[destination..destination + rect.width]
                .copy_from_slice(&self.pixels[start..start + rect.width]);
        }
    }
}

fn allocate_pixels(count: usize, value: Pixel) -> Result<Vec<Pixel>, CompositionError> {
    let mut pixels = Vec::new();
    pixels
        .try_reserve_exact(count)
        .map_err(|_| CompositionError::AllocationFailure)?;
    pixels.resize(count, value);
    Ok(pixels)
}

#[cfg(test)]
mod tests;
