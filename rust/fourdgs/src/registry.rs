// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! Well-known values, and the refusal a reader owes an unknown one.
//!
//! The registry's standing rule is that a value it does not list is legal but
//! unrecognized, and that a reader which does not know a value **must fail cleanly with a
//! message naming it** rather than guess. That rule is what makes every future extension
//! safe: a new temporal model, a new quantization scheme, a new codec can all be added
//! without a version bump precisely because an old reader stops instead of misreading.
//!
//! Until this module existed, this reader enforced neither. A file declaring a temporal
//! model it has never heard of decoded as though it were `gaussian-birth` — silently, and
//! into geometry that looks entirely plausible, because every other Header field is still
//! valid. Nothing downstream could tell that the motion it was drawing was not the motion
//! the file described.
//!
//! ## The messages here are contract
//!
//! Two things pin the exact wording, and neither is style:
//!
//! * the specification's refusal table names the identifier and the sentence, so that two
//!   readers refusing the same file say the same thing about it;
//! * the CLI cross-validator compares this implementation's findings against the Python
//!   one's **line for line**, so a difference in wording is a failing test.
//!
//! That is why [`Error::UnsupportedModel`] carries no `"...: "` type prefix in its
//! `Display`, where every other variant does. The prefix would be wrong twice over — a
//! temporal model is not a codec and not a version — and it would put this implementation's
//! internal taxonomy in front of a sentence the specification writes.

use crate::error::{Error, Result};

/// Temporal models this reader implements.
///
/// A name the registry lists as *reserved* is one this reader must refuse, not one it may
/// treat as the default. `keyframe-delta` belongs here only when this reader can decode
/// it; until then, accepting the name would mean accepting files it cannot read, which is
/// the opposite of the refusal the rule exists for.
pub const KNOWN_TEMPORAL_MODELS: &[&str] = &["gaussian-birth"];

/// Quantization schemes this reader implements.
pub const KNOWN_QUANTIZATION_SCHEMES: &[&str] = &["uniform-v1"];

fn listed(known: &[&str]) -> String {
    let mut names: Vec<&str> = known.to_vec();
    names.sort_unstable();
    names.join(", ")
}

pub fn check_temporal_model(model: &str) -> Result<()> {
    if KNOWN_TEMPORAL_MODELS.contains(&model) {
        return Ok(());
    }
    Err(Error::UnsupportedModel(format!(
        "the Header declares temporal model '{model}', which this reader does not implement \
         (it implements {})",
        listed(KNOWN_TEMPORAL_MODELS)
    )))
}

pub fn check_quantization_scheme(scheme: &str) -> Result<()> {
    if KNOWN_QUANTIZATION_SCHEMES.contains(&scheme) {
        return Ok(());
    }
    Err(Error::UnsupportedModel(format!(
        "the Quantization record declares scheme '{scheme}', which this reader does not implement \
         (it implements {})",
        listed(KNOWN_QUANTIZATION_SCHEMES)
    )))
}
