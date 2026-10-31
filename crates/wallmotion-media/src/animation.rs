//! Bounded, immutable full-canvas GIF frames for future shared playback.
//! This layer has no file I/O, FFI, clock or application cache.
use crate::compositor::{CompositionError, Compositor, Disposal, FrameRect, IndexedFrame, Pixel};
use crate::{GifError, probe_gif_with_limits};
use std::io::{Cursor, Read};
use std::num::NonZeroU64;

#[derive(Clone, Copy, Debug)]
pub struct DecodeLimits {
    pub encoded_bytes: usize,
    pub decoded_bytes: u64,
    /// Our retained RGBA, canvas, Previous backups and transient index/output payload.
    /// Excludes input, allocator overhead, frame metadata and third-party codec buffers.
    pub working_bytes: usize,
    pub frames: usize,
}

impl Default for DecodeLimits {
    fn default() -> Self {
        Self {
            encoded_bytes: 256 * 1024 * 1024,
            decoded_bytes: 256 * 1024 * 1024,
            working_bytes: 384 * 1024 * 1024,
            frames: 10_000,
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum DecodeError {
    Preflight(GifError),
    Composition(CompositionError),
    InvalidData,
    FrameLimit,
    WorkingBudget,
    Overflow,
    AllocationFailure,
    ProfileLimit,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Repetitions {
    Finite(u16),
    Infinite,
}

pub struct AnimationFrame {
    pixels: Vec<Pixel>,
    delay_centiseconds: u16,
}
impl AnimationFrame {
    pub fn pixels(&self) -> &[Pixel] {
        &self.pixels
    }
    /// Original file delay, including zero. Playback policy is a separate concern.
    pub fn delay_centiseconds(&self) -> u16 {
        self.delay_centiseconds
    }
}

pub struct Animation {
    width: usize,
    height: usize,
    frames: Vec<AnimationFrame>,
    repetitions: Repetitions,
    payload_bytes: usize,
    icc_profile: Option<Vec<u8>>,
}
impl Animation {
    pub fn width(&self) -> usize {
        self.width
    }
    pub fn height(&self) -> usize {
        self.height
    }
    pub fn frames(&self) -> &[AnimationFrame] {
        &self.frames
    }
    pub fn repetitions(&self) -> Repetitions {
        self.repetitions
    }
    /// Bounded source profile bytes, for a future consumer to validate and apply.
    /// Raw palette values above have not been transformed by this profile.
    pub fn icc_profile(&self) -> Option<&[u8]> {
        self.icc_profile.as_deref()
    }
    pub fn payload_bytes(&self) -> usize {
        self.payload_bytes
    }
}

/// Fully validates and decodes before publishing an Animation. Callers may put the
/// resulting immutable value in Arc; sharing/identity/cancellation belong to integration.
/// All background disposal uses transparent RGBA, matching a wallpaper alpha surface.
pub fn decode(data: &[u8], limits: DecodeLimits) -> Result<Animation, DecodeError> {
    let info = probe_gif_with_limits(data, limits.decoded_bytes, limits.encoded_bytes as u64)
        .map_err(DecodeError::Preflight)?;
    decode_reader(Cursor::new(data), info, limits)
}

/// Only callers that performed bounded structural admission may supply info.
/// File callers separately check observed identity around their bounded reads.
pub(crate) fn decode_reader(
    reader: impl Read,
    info: crate::GifInfo,
    limits: DecodeLimits,
) -> Result<Animation, DecodeError> {
    let frame_count = usize::try_from(info.frames).map_err(|_| DecodeError::Overflow)?;
    if frame_count > limits.frames {
        return Err(DecodeError::FrameLimit);
    }
    let width = info.width as usize;
    let height = info.height as usize;
    let canvas_count = width.checked_mul(height).ok_or(DecodeError::Overflow)?;
    let canvas_bytes = canvas_count.checked_mul(4).ok_or(DecodeError::Overflow)?;
    // Reserve canvas only after preflight and admission. Codec allocations have a
    // separate per-buffer limit; neither limit is a process RSS guarantee.
    if canvas_bytes > limits.working_bytes {
        return Err(DecodeError::WorkingBudget);
    }
    let mut compositor = Compositor::new(width, height, [0; 4], limits.working_bytes)
        .map_err(DecodeError::Composition)?;
    let mut frames = Vec::new();
    frames
        .try_reserve_exact(frame_count)
        .map_err(|_| DecodeError::AllocationFailure)?;
    let mut options = gif::DecodeOptions::new();
    options.set_color_output(gif::ColorOutput::Indexed);
    options.check_frame_consistency(true);
    options.check_lzw_end_code(true);
    // Keep ancillary XMP/ICC and codec output buffers bounded too, even when a
    // tiny image contains a disproportionately large metadata extension.
    let codec_limit = canvas_count.clamp(1024, 64 * 1024 * 1024);
    options.set_memory_limit(gif::MemoryLimit::Bytes(
        NonZeroU64::new(codec_limit as u64).unwrap(),
    ));
    let mut decoder = options
        .read_info(reader)
        .map_err(|_| DecodeError::InvalidData)?;
    if usize::from(decoder.width()) != width || usize::from(decoder.height()) != height {
        return Err(DecodeError::InvalidData);
    }
    let mut retained = 0usize;
    while let Some(frame) = decoder
        .next_frame_info()
        .map_err(|_| DecodeError::InvalidData)?
    {
        if frames.len() >= frame_count {
            return Err(DecodeError::InvalidData);
        }
        let rect = FrameRect {
            left: frame.left.into(),
            top: frame.top.into(),
            width: frame.width.into(),
            height: frame.height.into(),
        };
        let transparent = frame.transparent;
        let delay = frame.delay;
        let disposal = match frame.dispose {
            gif::DisposalMethod::Any | gif::DisposalMethod::Keep => Disposal::Keep,
            gif::DisposalMethod::Background => Disposal::Background,
            gif::DisposalMethod::Previous => Disposal::Previous,
        };
        let count = rect
            .width
            .checked_mul(rect.height)
            .ok_or(DecodeError::Overflow)?;
        if count == 0 || count > canvas_count {
            return Err(DecodeError::InvalidData);
        }
        let backup = if disposal == Disposal::Previous {
            count.checked_mul(4).ok_or(DecodeError::Overflow)?
        } else {
            0
        };
        // Conservative peak includes old/new backups, retained full frames, the
        // indexed frame and the next RGBA copy, before any of those allocations.
        let peak = [
            retained,
            compositor.owned_payload_bytes(),
            backup,
            count,
            canvas_bytes,
        ]
        .into_iter()
        .try_fold(0usize, |sum, bytes| sum.checked_add(bytes))
        .ok_or(DecodeError::Overflow)?;
        if peak > limits.working_bytes {
            return Err(DecodeError::WorkingBudget);
        }
        let mut indices = Vec::new();
        indices
            .try_reserve_exact(count)
            .map_err(|_| DecodeError::AllocationFailure)?;
        indices.resize(count, 0);
        decoder
            .read_into_buffer(&mut indices)
            .map_err(|_| DecodeError::InvalidData)?;
        let palette_bytes = decoder.palette().map_err(|_| DecodeError::InvalidData)?;
        if palette_bytes.is_empty() || palette_bytes.len() > 768 || palette_bytes.len() % 3 != 0 {
            return Err(DecodeError::InvalidData);
        }
        let mut palette = [[0; 3]; 256];
        for (output, input) in palette.iter_mut().zip(palette_bytes.chunks_exact(3)) {
            output.copy_from_slice(input);
        }
        compositor
            .compose(IndexedFrame {
                rect,
                indices: &indices,
                palette: &palette[..palette_bytes.len() / 3],
                transparent,
                disposal,
            })
            .map_err(DecodeError::Composition)?;
        let mut pixels = Vec::new();
        pixels
            .try_reserve_exact(canvas_count)
            .map_err(|_| DecodeError::AllocationFailure)?;
        pixels.extend_from_slice(compositor.pixels());
        frames.push(AnimationFrame {
            pixels,
            delay_centiseconds: delay,
        });
        retained = retained
            .checked_add(canvas_bytes)
            .ok_or(DecodeError::Overflow)?;
    }
    if frames.len() != frame_count {
        return Err(DecodeError::InvalidData);
    }
    let repetitions = match decoder.repeat() {
        gif::Repeat::Finite(value) => Repetitions::Finite(value),
        gif::Repeat::Infinite => Repetitions::Infinite,
    };
    let icc_profile = if let Some(profile) = decoder.icc_profile() {
        // Metadata is separate from pixel payload; cap the retained copy explicitly.
        if profile.len() > 1024 * 1024 {
            return Err(DecodeError::ProfileLimit);
        }
        let mut copy = Vec::new();
        copy.try_reserve_exact(profile.len())
            .map_err(|_| DecodeError::AllocationFailure)?;
        copy.extend_from_slice(profile);
        Some(copy)
    } else {
        None
    };
    Ok(Animation {
        width,
        height,
        frames,
        repetitions,
        payload_bytes: retained,
        icc_profile,
    })
}

#[cfg(test)]
mod tests;
