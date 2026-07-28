//! Reader and writer for the 4dgs container format.
//!
//! Planned for v1.x — see README.md. The API below is a sketch of the shape the
//! implementation will take, and every body is unimplemented.

/// Anything that can report its size and read a byte range.
///
/// The core depends on this and nothing else: no HTTP, no filesystem. Transports are
/// separate and swappable.
pub trait Readable {
    /// Total size of the resource in bytes.
    fn size(&self) -> std::io::Result<u64>;

    /// Read `length` bytes starting at `offset`.
    fn read(&mut self, offset: u64, length: u64) -> std::io::Result<Vec<u8>>;
}

/// Gaussian state reconstructed at one instant.
#[derive(Debug, Default)]
pub struct GaussianSet {
    pub positions: Vec<f32>,
    pub scales: Vec<f32>,
    pub rotations: Vec<f32>,
    pub colors: Vec<f32>,
}

/// Decode the gaussians visible at scene time `t`.
pub fn decode_at<R: Readable>(_source: &mut R, _t: f64) -> std::io::Result<GaussianSet> {
    todo!("4dgs Rust decoder is planned; see README.md")
}
