use crate::animation::{self, Animation, DecodeError, DecodeLimits};
use crate::{GifError, probe_gif_file_with_limits};
use std::fs::{File, Metadata};
use std::io::{self, ErrorKind};
use std::os::unix::fs::{FileExt, MetadataExt};

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum FileDecodeError {
    Decode(DecodeError),
    Changed,
    Read,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Identity {
    device: u64,
    inode: u64,
    length: u64,
    modified: (i64, i64),
    changed: (i64, i64),
}
impl Identity {
    fn from(metadata: Metadata) -> Result<Self, FileDecodeError> {
        if !metadata.is_file() {
            return Err(FileDecodeError::Read);
        }
        Ok(Self {
            device: metadata.dev(),
            inode: metadata.ino(),
            length: metadata.len(),
            modified: (metadata.mtime(), metadata.mtime_nsec()),
            changed: (metadata.ctime(), metadata.ctime_nsec()),
        })
    }
    fn read(file: &File) -> Result<Self, FileDecodeError> {
        Self::from(file.metadata().map_err(|_| FileDecodeError::Read)?)
    }
    fn verify(self, file: &File) -> Result<(), FileDecodeError> {
        if Self::read(file)? == self {
            Ok(())
        } else {
            Err(FileDecodeError::Changed)
        }
    }
}

/// Observed metadata stability, not a kernel-atomic snapshot against hostile writers.
/// Input is bounded to initial file length; no full encoded copy or mmap is retained.
pub(crate) fn decode_file(file: &File, limits: DecodeLimits) -> Result<Animation, FileDecodeError> {
    decode_with_reader(file, limits, |buffer, offset| file.read_at(buffer, offset))
}

fn decode_with_reader(
    file: &File,
    limits: DecodeLimits,
    read_at: impl FnMut(&mut [u8], u64) -> io::Result<usize>,
) -> Result<Animation, FileDecodeError> {
    let identity = Identity::read(file)?;
    if identity.length > limits.encoded_bytes as u64 {
        return Err(FileDecodeError::Decode(DecodeError::Preflight(
            GifError::EncodedBudgetExceeded,
        )));
    }
    let info = probe_gif_file_with_limits(file, limits.decoded_bytes, limits.encoded_bytes as u64)
        .map_err(|e| FileDecodeError::Decode(DecodeError::Preflight(e)))?;
    if info.frames as usize > limits.frames {
        return Err(FileDecodeError::Decode(DecodeError::FrameLimit));
    }
    identity.verify(file)?;
    let reader = PositionedReader {
        read_at,
        length: identity.length,
        position: 0,
    };
    let animation =
        animation::decode_reader(reader, info, limits).map_err(FileDecodeError::Decode)?;
    identity.verify(file)?;
    Ok(animation)
}

struct PositionedReader<F> {
    read_at: F,
    length: u64,
    position: u64,
}
impl<F: FnMut(&mut [u8], u64) -> io::Result<usize>> std::io::Read for PositionedReader<F> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        let count = (self.length - self.position).min(buffer.len() as u64) as usize;
        if count == 0 {
            return Ok(0);
        }
        loop {
            match (self.read_at)(&mut buffer[..count], self.position) {
                Ok(0) => return Err(io::Error::from(ErrorKind::UnexpectedEof)),
                Ok(read) if read <= count => {
                    self.position += read as u64;
                    return Ok(read);
                }
                Ok(_) => return Err(io::Error::from(ErrorKind::InvalidData)),
                Err(error) if error.kind() == ErrorKind::Interrupted => continue,
                Err(error) => return Err(error),
            }
        }
    }
}

#[cfg(test)]
mod tests;
