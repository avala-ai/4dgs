// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! The object layer: what the Object Table and the SE(3) tracks mean once read.
//!
//! [`crate::records`] knows the bytes; this module knows the composition and the one rule
//! that spans more than one record — that at most one track moves any object.
//!
//! The layer changes a reconstructed instant in exactly one way, and it is the
//! load-bearing rule of the whole design (spec section 5.15.6):
//!
//! > A track transforms the base state; it does not replace it.
//!
//! For a gaussian belonging to object `k`, with the base centre `c0` that the temporal
//! model produced (spec section 3), and the track's pose `(R, T)` at `t`:
//!
//! ```text
//! center(t) = R * c0 + T
//! ```
//!
//! The pose is relative to the object's stored (rest) configuration, so ignoring the whole
//! layer leaves every object at rest — a valid scene — rather than a pile at the origin.
//! The transform is rigid: it moves the centre and touches neither opacity nor the temporal
//! fields, so section 3's visibility runs unchanged on the base. A gaussian that carries
//! per-gaussian motion AND belongs to a moving track is neither forbidden nor track-wins:
//! its motion moves it inside the object's frame (folded into `c0`), and the track then
//! transports the object. The two compose, base first.
//!
//! Nothing here is required to decode gaussians. A file with no object layer produces an
//! empty [`ObjectLayer`], which is a value and never an error.

use crate::error::{Error, Result};
use crate::provenance::{pose_at, PoseSampled};
use crate::records::{ObjectTable, ObjectTrack};

/// Background / unassigned. A gaussian carrying this id belongs to no object and is never
/// transformed; a track may not name it (refused at parse).
pub const BACKGROUND: u32 = 0;

impl PoseSampled for ObjectTrack {
    fn name(&self) -> &str {
        // Tracks are named by object id, not a string; this is only for messages.
        "object track"
    }
    fn interpolation(&self) -> u8 {
        self.interpolation
    }
    fn sample_count(&self) -> usize {
        self.times.len()
    }
    fn time(&self, i: usize) -> f64 {
        self.times[i]
    }
    fn rotation(&self, i: usize) -> [f64; 4] {
        self.rotations[i]
    }
    fn translation(&self, i: usize) -> [f64; 3] {
        self.translations[i]
    }
}

/// Every object-layer record a file carried, and the rule that spans the tracks.
///
/// `table` is the file's one Object Table, or `None`. `tracks` is the SE(3) tracks, at
/// most one per object. An empty instance is what a scene with no objects produces.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ObjectLayer {
    pub table: Option<ObjectTable>,
    pub tracks: Vec<ObjectTrack>,
}

impl ObjectLayer {
    pub fn is_empty(&self) -> bool {
        self.table.is_none() && self.tracks.is_empty()
    }

    pub fn track(&self, object_id: u32) -> Option<&ObjectTrack> {
        self.tracks.iter().find(|t| t.object_id == object_id)
    }

    /// At most one track per object.
    ///
    /// Two tracks for one object would move its gaussians by two poses, which is the
    /// duplicate-name failure section 5.15.2 refuses for frames and sensors. Each track's
    /// own rules are enforced at parse; this is the one rule no single record can see.
    pub fn check(&self) -> Result<()> {
        let mut seen: Vec<u32> = Vec::with_capacity(self.tracks.len());
        for t in &self.tracks {
            if seen.contains(&t.object_id) {
                return Err(Error::Malformed(format!(
                    "two ObjectTrack records move object {}; a gaussian has one object and cannot \
                     be transported by two poses (section 5.15.6)",
                    t.object_id
                )));
            }
            seen.push(t.object_id);
        }
        Ok(())
    }

    /// The rigid pose that transforms object `object_id` at scene time `t`.
    ///
    /// `None` when the object has no track — background, or an untracked object — in which
    /// case its gaussians keep their base state. A track reuses the trajectory
    /// clamp-and-slerp of [`pose_at`], so a query outside the sample range returns the
    /// nearest end sample rather than extrapolating.
    pub fn pose_at(&self, object_id: u32, t: f64) -> Result<Option<crate::provenance::Pose>> {
        if object_id == BACKGROUND {
            return Ok(None);
        }
        match self.track(object_id) {
            Some(track) if track.sample_count() > 0 => pose_at(track, t),
            _ => Ok(None),
        }
    }

    /// Compose the tracks onto reconstructed centres: `center = R * c0 + T`.
    ///
    /// `centers` is `3 * n` flat, `object_ids` is `n`. Each gaussian whose object has a
    /// track is transformed in place; the rest pass through unchanged, so a file with no
    /// tracks is a no-op. The transform is applied once, after the base state is fully
    /// reconstructed.
    pub fn apply(&self, centers: &mut [f32], object_ids: &[u32], t: f64) -> Result<()> {
        if self.tracks.is_empty() {
            return Ok(());
        }
        for (i, &object_id) in object_ids.iter().enumerate() {
            let Some(pose) = self.pose_at(object_id, t)? else {
                continue;
            };
            let c0 = [
                centers[i * 3] as f64,
                centers[i * 3 + 1] as f64,
                centers[i * 3 + 2] as f64,
            ];
            let moved = pose.apply(c0);
            centers[i * 3] = moved[0] as f32;
            centers[i * 3 + 1] = moved[1] as f32;
            centers[i * 3 + 2] = moved[2] as f32;
        }
        Ok(())
    }
}
