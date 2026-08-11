// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! The `keyframe-delta` temporal model: composition, and the chain a seek walks.
//!
//! State at time `t` is the nearest previous keyframe with the deltas between it and `t`
//! composed onto it. Everything here operates on **quantization bins**, not on values, and
//! that is the single load-bearing decision in the model:
//!
//! > A delta is a difference of bins, never a quantization of a difference.
//!
//! The keyframe stores `b0 = q(x0)`. Delta `j` stores the integer `q(xj) - q(x_{j-1})`. The
//! composition telescopes over integers, so the composed bin *is* `q(x_d)` — the bin the
//! encoder would have written had it stated that instant absolutely. Nothing here
//! dequantizes: composition produces bins, and `keyframe_delta_file` turns bins into
//! gaussians exactly as a `gaussian-birth` chunk would.

use std::collections::{BTreeMap, BTreeSet};

use crate::error::Error;
use crate::opcode as op;
use crate::records::ChunkIndexEntry;

/// Composed bins are signed 32-bit. Not a limit anyone meets — at a millimetre grid it
/// spans about 2,000 km — but stated so that two decoders in two languages agree on where
/// the boundary is. Overflow is refused, never wrapped: a wrapped position bin is a
/// gaussian at a plausible-looking wrong place, which is the failure the bounds contract
/// exists to make impossible.
pub const BIN_MIN: i64 = -(1i64 << 31);
pub const BIN_MAX: i64 = (1i64 << 31) - 1;

/// Attributes a delta's update group MUST NOT carry: the three that derive the per-gaussian
/// grids for velocity and birth time, so a bin difference across a change in any of them is
/// a difference between bins on two different grids.
pub const GOP_INVARIANT: [u8; 3] = [op::A_SIGMA_T, op::A_FLAGS, op::A_WINDOW_INDEX];

/// Attributes an update restates outright rather than differencing: the smallest-three
/// rotation coding omits the largest-magnitude component, so the three stored bins mean
/// different components either side of a change.
pub const ABSOLUTE_IN_UPDATE: [u8; 2] = [op::A_ROTATION_INDEX, op::A_ROTATION];

fn is_gop_invariant(attribute: u8) -> bool {
    GOP_INVARIANT.contains(&attribute)
}

fn is_absolute_in_update(attribute: u8) -> bool {
    ABSOLUTE_IN_UPDATE.contains(&attribute)
}

/// A refusal carrying the specification's exact refusal code alongside its message.
///
/// It converts into [`Error::Malformed`] with `?`, so the file-level read paths surface it
/// like any other malformed-file error while the composition layer's own tests can assert
/// on the code the way the Python reference's tests assert on `MalformedFile.code`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Refusal {
    pub code: &'static str,
    pub message: String,
}

impl std::fmt::Display for Refusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.message)
    }
}

impl From<Refusal> for Error {
    fn from(r: Refusal) -> Error {
        Error::Malformed(r.message)
    }
}

fn refuse<T>(code: &'static str, message: String) -> Result<T, Refusal> {
    Err(Refusal { code, message })
}

/// One attribute's bins: `count` rows of `channels` symbols each, row-major.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct BinArray {
    pub values: Vec<i64>,
    pub channels: usize,
}

impl BinArray {
    pub fn new(values: Vec<i64>, channels: usize) -> BinArray {
        BinArray { values, channels }
    }

    pub fn count(&self) -> usize {
        self.values.len().checked_div(self.channels).unwrap_or(0)
    }

    fn row(&self, i: usize) -> &[i64] {
        &self.values[i * self.channels..(i + 1) * self.channels]
    }
}

/// A composed population: identities, and one bin array per attribute.
///
/// `ids` and every row of `bins` are aligned, and the order is an implementation detail —
/// nothing in the format depends on it and no reader may rely on it.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct State {
    pub ids: Vec<i64>,
    pub bins: BTreeMap<u8, BinArray>,
}

impl State {
    pub fn count(&self) -> usize {
        self.ids.len()
    }
}

/// The state a keyframe chunk states outright, with its identities checked.
pub fn keyframe_state(ids: Vec<i64>, bins: BTreeMap<u8, BinArray>) -> Result<State, Refusal> {
    check_unique(&ids, "a keyframe")?;
    for (attribute, values) in &bins {
        if values.count() != ids.len() {
            return refuse(
                "stream-element-count-mismatch",
                format!(
                    "attribute {attribute} carries {} rows, the keyframe declares {} gaussians",
                    values.count(),
                    ids.len()
                ),
            );
        }
    }
    Ok(State { ids, bins })
}

/// Compose one delta onto the state it references.
///
/// Deaths, then updates, then births. The order is normative because a chunk that both
/// kills and creates would otherwise be ambiguous — and an id may appear in only one of the
/// three groups, so the order decides nothing a file is allowed to depend on.
pub fn apply_delta(
    state: &State,
    update_ids: &[i64],
    update_bins: &BTreeMap<u8, BinArray>,
    birth_ids: &[i64],
    birth_bins: &BTreeMap<u8, BinArray>,
    death_ids: &[i64],
) -> Result<State, Refusal> {
    check_groups_disjoint(update_ids, birth_ids, death_ids)?;
    check_unique(update_ids, "an update group")?;
    check_unique(birth_ids, "a birth group")?;
    check_unique(death_ids, "a death group")?;

    for attribute in update_bins.keys() {
        if is_gop_invariant(*attribute) {
            return refuse(
                "invariant-changed-in-update",
                format!(
                    "an update carries attribute {attribute}, which is fixed for a gaussian's \
                     lifetime within a group: the per-gaussian grids for velocity and birth time \
                     are derived from it, so a bin difference across a change in it has no defined \
                     meaning"
                ),
            );
        }
    }

    // --- deaths -----------------------------------------------------------
    let mut state = if !death_ids.is_empty() {
        let death_set: BTreeSet<i64> = death_ids.iter().copied().collect();
        if let Some(missing) = death_ids.iter().find(|id| !state.ids.contains(id)) {
            return refuse(
                "unknown-gaussian-id",
                format!("a delta kills gaussian id {missing}, which is not live at its reference"),
            );
        }
        let keep: Vec<usize> = (0..state.ids.len())
            .filter(|&i| !death_set.contains(&state.ids[i]))
            .collect();
        select_rows(state, &keep)
    } else {
        state.clone()
    };

    // --- updates ----------------------------------------------------------
    if !update_ids.is_empty() {
        let rows = rows_for(&state.ids, update_ids, "updates")?;
        for (attribute, delta) in update_bins {
            if delta.count() != update_ids.len() {
                return refuse(
                    "stream-element-count-mismatch",
                    format!(
                        "attribute {attribute} carries {} rows, the update group declares {}",
                        delta.count(),
                        update_ids.len()
                    ),
                );
            }
            let Some(base) = state.bins.get_mut(attribute) else {
                return refuse(
                    "unknown-attribute-in-update",
                    format!(
                        "an update touches attribute {attribute}, which the referenced state does \
                         not carry"
                    ),
                );
            };
            let channels = base.channels;
            if is_absolute_in_update(*attribute) {
                for (k, &row) in rows.iter().enumerate() {
                    base.values[row * channels..(row + 1) * channels].copy_from_slice(delta.row(k));
                }
            } else {
                for (k, &row) in rows.iter().enumerate() {
                    for c in 0..channels {
                        let sum = base.values[row * channels + c] + delta.values[k * channels + c];
                        if !(BIN_MIN..=BIN_MAX).contains(&sum) {
                            return refuse(
                                "bin-overflow",
                                format!(
                                    "composing attribute {attribute} for gaussian id {} leaves the \
                                     signed 32-bit range a composed bin must stay inside",
                                    update_ids[k]
                                ),
                            );
                        }
                        base.values[row * channels + c] = sum;
                    }
                }
            }
        }
    }

    // --- births -----------------------------------------------------------
    if !birth_ids.is_empty() {
        if let Some(clash) = birth_ids.iter().find(|id| state.ids.contains(id)) {
            return refuse(
                "duplicate-gaussian-id",
                format!(
                    "a delta creates gaussian id {clash}, which is already live; ids are unique \
                     within a state and are not reused after a death"
                ),
            );
        }
        let mut absent: Vec<u8> = state
            .bins
            .keys()
            .copied()
            .filter(|a| !birth_bins.contains_key(a))
            .collect();
        absent.sort_unstable();
        if !absent.is_empty() {
            return refuse(
                "incomplete-birth",
                format!(
                    "a birth group carries no value for attributes {absent:?}; a birth is absolute \
                     state, not a delta"
                ),
            );
        }
        for (attribute, values) in birth_bins {
            if values.count() != birth_ids.len() {
                return refuse(
                    "stream-element-count-mismatch",
                    format!(
                        "attribute {attribute} carries {} rows, the birth group declares {}",
                        values.count(),
                        birth_ids.len()
                    ),
                );
            }
        }
        state.ids.extend_from_slice(birth_ids);
        let attributes: BTreeSet<u8> = state
            .bins
            .keys()
            .copied()
            .chain(birth_bins.keys().copied())
            .collect();
        let mut merged: BTreeMap<u8, BinArray> = BTreeMap::new();
        for attribute in attributes {
            let birth = birth_bins.get(&attribute);
            match state.bins.get(&attribute) {
                Some(base) => {
                    let mut values = base.values.clone();
                    if let Some(b) = birth {
                        values.extend_from_slice(&b.values);
                    }
                    merged.insert(attribute, BinArray::new(values, base.channels));
                }
                None => {
                    let b = birth.expect("attribute came from one of the two maps");
                    merged.insert(attribute, b.clone());
                }
            }
        }
        state.bins = merged;
    }

    Ok(state)
}

/// A new state holding only the named rows of `state`, in `keep` order.
fn select_rows(state: &State, keep: &[usize]) -> State {
    let ids = keep.iter().map(|&i| state.ids[i]).collect();
    let bins = state
        .bins
        .iter()
        .map(|(attribute, array)| {
            let mut values = Vec::with_capacity(keep.len() * array.channels);
            for &i in keep {
                values.extend_from_slice(array.row(i));
            }
            (*attribute, BinArray::new(values, array.channels))
        })
        .collect();
    State { ids, bins }
}

/// Where each wanted id sits in the state, refusing any that is not there.
///
/// The lookup is by identity and never by position: an encoder may order a chunk however it
/// likes, so a delta that found its gaussians by row would be correct only for the ordering
/// its own encoder happened to choose.
fn rows_for(state_ids: &[i64], wanted: &[i64], what: &str) -> Result<Vec<usize>, Refusal> {
    let mut position: BTreeMap<i64, usize> = BTreeMap::new();
    for (i, id) in state_ids.iter().enumerate() {
        position.entry(*id).or_insert(i);
    }
    let mut rows = Vec::with_capacity(wanted.len());
    for id in wanted {
        match position.get(id) {
            Some(row) => rows.push(*row),
            None => {
                return refuse(
                    "unknown-gaussian-id",
                    format!("a delta {what} gaussian id {id}, which is not live at its reference"),
                )
            }
        }
    }
    Ok(rows)
}

fn check_unique(ids: &[i64], what: &str) -> Result<(), Refusal> {
    let mut seen: BTreeSet<i64> = BTreeSet::new();
    for id in ids {
        if !seen.insert(*id) {
            return refuse(
                "duplicate-gaussian-id",
                format!("{what} names gaussian id {id} more than once"),
            );
        }
    }
    Ok(())
}

fn check_groups_disjoint(
    update_ids: &[i64],
    birth_ids: &[i64],
    death_ids: &[i64],
) -> Result<(), Refusal> {
    for (a, b, names) in [
        (update_ids, birth_ids, "updated and born"),
        (update_ids, death_ids, "updated and killed"),
        (birth_ids, death_ids, "born and killed"),
    ] {
        let set: BTreeSet<i64> = a.iter().copied().collect();
        if let Some(both) = b.iter().find(|id| set.contains(id)) {
            return refuse(
                "id-in-two-groups",
                format!(
                    "gaussian id {both} is {names} by the same delta; the outcome would depend on \
                     the order the groups are applied in"
                ),
            );
        }
    }
    Ok(())
}

// --------------------------------------------------------------------------
// Seeking: the chain, answered from the index alone
// --------------------------------------------------------------------------

/// State chunks tile the timeline: no overlap, no gap.
///
/// This is what makes the seek predicate a lookup rather than a search, and it is a real
/// constraint — under `gaussian-birth` chunks may overlap freely, and here they may not.
pub fn check_tiling(index: &[ChunkIndexEntry]) -> Result<(), Refusal> {
    let mut ordered: Vec<&ChunkIndexEntry> = index.iter().collect();
    ordered.sort_by(|a, b| a.t0.partial_cmp(&b.t0).unwrap_or(std::cmp::Ordering::Equal));
    for pair in ordered.windows(2) {
        let (previous, entry) = (pair[0], pair[1]);
        if previous.t1 != entry.t0 {
            let what = if entry.t0 < previous.t1 {
                "overlap"
            } else {
                "leave a gap"
            };
            return refuse(
                "non-tiling-chunks",
                format!(
                    "state chunks {what}: [{}, {}) is followed by [{}, {})",
                    previous.t0, previous.t1, entry.t0, entry.t1
                ),
            );
        }
    }
    Ok(())
}

/// The two ends of that tiling, which the index alone cannot answer for.
///
/// Spec §11.1 is one sentence with three clauses: sorted by `t0`, each chunk's `t1` equals
/// the next chunk's `t0`, **the first `t0` is `0`, and the last `t1` is the Header's
/// `duration_sec`**. [`check_tiling`] compares neighbours, which is a complete check of the
/// interior and says nothing about either end — an index whose entries run `[0.4, 0.6)` and
/// `[0.6, 0.9)` is internally adjacent and tiles none of a one-second clip. A reader that
/// accepted it would answer a seek to `t=0.1` with "no state chunk covers t=0.1" on a file
/// it had already called conforming.
///
/// Separate from `check_tiling` only because the duration comes from the Header and that
/// function is handed the index by itself.
pub fn check_timeline_endpoints(
    index: &[ChunkIndexEntry],
    duration_sec: f64,
) -> Result<(), Refusal> {
    let mut ordered: Vec<&ChunkIndexEntry> = index.iter().collect();
    ordered.sort_by(|a, b| a.t0.partial_cmp(&b.t0).unwrap_or(std::cmp::Ordering::Equal));
    // No entries is no index, which is a different file — one read front to back — and not
    // a timeline with the wrong ends.
    let (Some(first), Some(last)) = (ordered.first(), ordered.last()) else {
        return Ok(());
    };
    if first.t0 != 0.0 {
        return refuse(
            "non-tiling-chunks",
            format!(
                "the state chunks start at {}; they tile the timeline from 0 (section 11.1)",
                first.t0
            ),
        );
    }
    if last.t1 != duration_sec {
        return refuse(
            "non-tiling-chunks",
            format!(
                "the state chunks end at {}; the Header declares a duration of {duration_sec}, \
                 and they tile the whole of it (section 11.1)",
                last.t1
            ),
        );
    }
    Ok(())
}

/// The keyframe and deltas a reader must read to reconstruct instant `t`.
///
/// Answered from the index alone — no chunk is fetched to learn what another references —
/// and returned oldest first, which is the order [`apply_delta`] composes in.
pub fn chain_for(index: &[ChunkIndexEntry], t: f64) -> Result<Vec<ChunkIndexEntry>, Refusal> {
    let mut by_offset: BTreeMap<u64, &ChunkIndexEntry> = BTreeMap::new();
    for entry in index {
        by_offset.insert(entry.chunk_offset, entry);
    }
    let current = match index.iter().find(|e| e.t0 <= t && t < e.t1) {
        Some(e) => e.clone(),
        None => return refuse("non-tiling-chunks", format!("no state chunk covers t={t}")),
    };

    let mut chain: Vec<ChunkIndexEntry> = vec![current.clone()];
    while chain[0].kind != 0 {
        let head = chain[0].clone();
        if head.reference_offset >= head.chunk_offset {
            return refuse(
                "forward-reference",
                format!(
                    "the chunk at {} references {}, which is not behind it; references point \
                     backwards only",
                    head.chunk_offset, head.reference_offset
                ),
            );
        }
        let Some(reference) = by_offset.get(&head.reference_offset) else {
            return refuse(
                "broken-reference",
                format!(
                    "the chunk at {} references {}, which the index does not name",
                    head.chunk_offset, head.reference_offset
                ),
            );
        };
        chain.insert(0, (*reference).clone());
        if chain.len() > index.len() {
            return refuse(
                "chain-without-keyframe",
                "the chain does not reach a keyframe".to_string(),
            );
        }
    }

    if chain.len() - 1 != current.depth as usize {
        return refuse(
            "depth-mismatch",
            format!(
                "the chunk at {} declares depth {}, but its chain walks {} delta chunks; the index \
                 and the file disagree about the cost of this seek",
                current.chunk_offset,
                current.depth,
                chain.len() - 1
            ),
        );
    }
    Ok(chain)
}
