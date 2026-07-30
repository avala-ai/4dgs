// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! Reader and writer for the 4dgs container format.
//!
//! A `.4dgs` file is a single, self-contained, seekable container for a 4D gaussian splat
//! scene: gaussians whose position, opacity and existence vary continuously over time,
//! optionally with multiple fixed or moving audio sources and a default camera trajectory.
//!
//! **Decoding ends at reconstructed gaussian state at time `t`.** The format is
//! renderer-agnostic and so is this crate: nothing here describes how that state should be
//! drawn, ordered, culled or budgeted.
//!
//! # Reading
//!
//! Two modes, both first-class. Neither is an optimization of the other.
//!
//! ```no_run
//! // Front to back: works on a pipe, on a file with no index, on a file cut short.
//! let scene = fourdgs::read_path("scene.4dgs")?;
//! let state = scene.state_at(1.5)?;
//! println!("{} gaussians visible at t=1.5", state.count());
//!
//! // Indexed: the Footer, then the index, then only the byte ranges an instant needs.
//! let source = fourdgs::FileReadable::open("scene.4dgs")?;
//! let mut reader = fourdgs::SceneReader::open(source)?;
//! let state = reader.state_at(1.5, 3)?;
//! # Ok::<(), fourdgs::Error>(())
//! ```
//!
//! # Transports
//!
//! The core depends on [`Readable`] — something that can report its size and read a byte
//! range — and on nothing else. A file, an HTTP range reader, a cache and an in-memory
//! buffer are all the same to it.

pub mod capi;
pub mod chunk;
pub mod codec;
pub mod error;
pub mod indexed_reader;
pub mod keyframe_delta;
pub mod keyframe_delta_file;
pub mod model;
pub mod object_layer;
pub mod opcode;
pub mod provenance;
pub mod quantization;
pub mod readable;
pub mod reader;
pub mod records;
pub mod registry;
pub mod serialization;
pub mod sh;
pub mod stream;
pub mod stream_reader;
pub mod writer;

pub use crate::error::{Error, Result};
pub use crate::model::{
    AudioSource, AudioSourceKeyframe, AudioSourceState, AudioTrack, CameraTrajectory, GaussianSet,
    StateAt,
};
pub use crate::object_layer::ObjectLayer;
pub use crate::provenance::{pose_at, slerp, Pose, PoseSampled, Provenance};
pub use crate::readable::{BytesReadable, FileReadable, Readable};
pub use crate::reader::{Mode, SceneReader};
pub use crate::records::{
    Attachment, Camera, ChunkIndexEntry, CoordinateFrame, Footer, GeodeticAnchor, Header, Metadata,
    ObjectTable, ObjectTableEntry, ObjectTrack, Quantization, RigTrajectory, SensorCalibration,
    Statistics, SummaryOffset, WindowTable,
};
pub use crate::serialization::{MAGIC, VERSION};
pub use crate::stream_reader::{read_bytes, read_from, read_path, ReadOptions, Scene};
pub use crate::writer::{write_path, write_to_vec, SceneExtras, WriteOptions};
