# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""The `keyframe-delta` temporal model: composition, and the chain a seek walks.

State at time `t` is the nearest previous keyframe with the deltas between it and `t`
composed onto it. Everything here operates on **quantization bins**, not on values, and
that is the single load-bearing decision in the model:

    A delta is a difference of bins, never a quantization of a difference.

The keyframe stores `b0 = q(x0)`. Delta `j` stores the integer `q(xj) - q(x_{j-1})`. The
composition telescopes over integers, so the composed bin *is* `q(x_d)` — the bin the
encoder would have written had it stated that instant absolutely. The declared error
bound therefore holds on reconstructed absolute state at any depth, and dequantization is
the same arithmetic it has always been.

The alternative — quantizing the difference — bounds the composed error by `(d+1)*eps`
and by nothing tighter, which makes a file's declared bound a per-hop quantity no consumer
uses and turns keyframe cadence into an error parameter rather than a seek parameter.

Nothing here dequantizes. Composition produces bins; `stream_reader` turns bins into
gaussians exactly as it does for a `gaussian-birth` chunk, and the specification's
rendering arithmetic then applies verbatim.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from itertools import pairwise

import numpy as np

from . import opcode as op
from .exceptions import MalformedFile

#: Composed bins are signed 32-bit. Not a limit anyone meets — at a millimetre grid it
#: spans about 2,000 km — but stated so that two decoders in two languages agree on where
#: the boundary is, rather than one finding it on a 64-bit accumulator and the other on a
#: 32-bit one. Overflow is refused, never wrapped: a wrapped position bin is a gaussian at
#: a plausible-looking wrong place, which is the failure the bounds contract exists to
#: make impossible.
BIN_MIN = -(2**31)
BIN_MAX = 2**31 - 1

#: Attributes a delta's update group MUST NOT carry.
#:
#: The first three derive the per-gaussian grids for velocity and birth time, so a bin
#: difference across a change in any of them is a difference between bins on two
#: different grids — a number with no interpretation, which decodes silently into a wrong
#: velocity rather than into an error.
#:
#: `rotation_index` is the same shape of failure: the smallest-three coding omits the
#: largest-magnitude component, so the three stored bins mean different components either
#: side of a change. A rotating object crosses that boundary constantly, so rotation is
#: restated absolutely instead of forbidden — see `ABSOLUTE_IN_UPDATE`.
GOP_INVARIANT = frozenset({op.A_SIGMA_T, op.A_FLAGS, op.A_WINDOW_INDEX})

#: Attributes an update restates outright rather than differencing.
ABSOLUTE_IN_UPDATE = frozenset({op.A_ROTATION_INDEX, op.A_ROTATION})


@dataclass
class State:
    """A composed population: identities, and one bin array per attribute.

    `ids` and every row of `bins` are aligned, and the order is an implementation detail
    — nothing in the format depends on it and no reader may rely on it.
    """

    ids: np.ndarray  # (n,) int64
    bins: dict[int, np.ndarray] = field(default_factory=dict)  # attribute -> (n, ch) int64

    @property
    def count(self) -> int:
        return int(self.ids.shape[0])

    def copy(self) -> State:
        return State(ids=self.ids.copy(), bins={a: v.copy() for a, v in self.bins.items()})


def _refuse(message: str, code: str) -> MalformedFile:
    return MalformedFile(message, code=code)


def keyframe_state(ids: np.ndarray, bins: dict[int, np.ndarray]) -> State:
    """The state a keyframe chunk states outright, with its identities checked."""
    ids = np.asarray(ids, dtype=np.int64).reshape(-1)
    _check_unique(ids, "a keyframe")
    for attribute, values in bins.items():
        if values.shape[0] != ids.shape[0]:
            raise _refuse(
                f"attribute {attribute} carries {values.shape[0]} rows, the keyframe declares {ids.shape[0]} gaussians",
                "stream-element-count-mismatch",
            )
    return State(ids=ids, bins={a: np.asarray(v, dtype=np.int64) for a, v in bins.items()})


def apply_delta(
    state: State,
    *,
    update_ids: np.ndarray,
    update_bins: dict[int, np.ndarray],
    birth_ids: np.ndarray,
    birth_bins: dict[int, np.ndarray],
    death_ids: np.ndarray,
) -> State:
    """Compose one delta onto the state it references.

    Deaths, then updates, then births. The order is normative because a chunk that both
    kills and creates would otherwise be ambiguous — and an id may appear in only one of
    the three groups, so the order decides nothing a file is allowed to depend on. It is
    fixed anyway, because "nothing depends on it" is a claim a reader should not have to
    take on trust from a file it did not write.
    """
    update_ids = np.asarray(update_ids, dtype=np.int64).reshape(-1)
    birth_ids = np.asarray(birth_ids, dtype=np.int64).reshape(-1)
    death_ids = np.asarray(death_ids, dtype=np.int64).reshape(-1)

    _check_groups_disjoint(update_ids, birth_ids, death_ids)
    _check_unique(update_ids, "an update group")
    _check_unique(birth_ids, "a birth group")
    _check_unique(death_ids, "a death group")

    has_rotation_index = op.A_ROTATION_INDEX in update_bins
    has_rotation_bins = op.A_ROTATION in update_bins
    if has_rotation_index != has_rotation_bins:
        missing = op.A_ROTATION if has_rotation_index else op.A_ROTATION_INDEX
        raise _refuse(
            f"an update carries only one half of the smallest-three rotation pair; "
            f"attribute {missing} is missing",
            "incomplete-rotation-update",
        )

    for attribute in update_bins:
        if attribute in GOP_INVARIANT:
            raise _refuse(
                f"an update carries attribute {attribute}, which is fixed for a gaussian's lifetime "
                f"within a group: the per-gaussian grids for velocity and birth time are derived from it, "
                f"so a bin difference across a change in it has no defined meaning",
                "invariant-changed-in-update",
            )

    # --- deaths -----------------------------------------------------------
    if death_ids.size:
        missing = np.setdiff1d(death_ids, state.ids)
        if missing.size:
            raise _refuse(
                f"a delta kills gaussian id {int(missing[0])}, which is not live at its reference",
                "unknown-gaussian-id",
            )
        keep = ~np.isin(state.ids, death_ids)
        state = State(ids=state.ids[keep], bins={a: v[keep] for a, v in state.bins.items()})
    else:
        state = state.copy()

    # --- updates ----------------------------------------------------------
    if update_ids.size:
        rows = _rows_for(state.ids, update_ids, "updates")
        for attribute, raw in update_bins.items():
            delta = np.asarray(raw, dtype=np.int64)
            if delta.shape[0] != update_ids.shape[0]:
                raise _refuse(
                    f"attribute {attribute} carries {delta.shape[0]} rows, the update group declares "
                    f"{update_ids.shape[0]}",
                    "stream-element-count-mismatch",
                )
            if attribute not in state.bins:
                raise _refuse(
                    f"an update touches attribute {attribute}, which the referenced state does not carry",
                    "unknown-attribute-in-update",
                )
            if attribute in ABSOLUTE_IN_UPDATE:
                state.bins[attribute][rows] = delta
            else:
                state.bins[attribute][rows] = _add_checked(state.bins[attribute][rows], delta, attribute, update_ids)

    # --- births -----------------------------------------------------------
    if birth_ids.size:
        clash = np.intersect1d(birth_ids, state.ids)
        if clash.size:
            raise _refuse(
                f"a delta creates gaussian id {int(clash[0])}, which is already live; "
                f"ids are unique within a state and are not reused after a death",
                "duplicate-gaussian-id",
            )
        absent = sorted(set(state.bins) - set(birth_bins))
        if absent:
            raise _refuse(
                f"a birth group carries no value for attributes {absent}; a birth is absolute state, not a delta",
                "incomplete-birth",
            )
        for attribute, values in birth_bins.items():
            if np.asarray(values).shape[0] != birth_ids.shape[0]:
                raise _refuse(
                    f"attribute {attribute} carries {np.asarray(values).shape[0]} rows, the birth group "
                    f"declares {birth_ids.shape[0]}",
                    "stream-element-count-mismatch",
                )
        state = State(
            ids=np.concatenate([state.ids, birth_ids]),
            bins={
                attribute: np.concatenate([state.bins[attribute], np.asarray(birth_bins[attribute], dtype=np.int64)])
                if attribute in state.bins
                else np.asarray(birth_bins[attribute], dtype=np.int64)
                for attribute in (set(state.bins) | set(birth_bins))
            },
        )

    return state


def _add_checked(base: np.ndarray, delta: np.ndarray, attribute: int, ids: np.ndarray) -> np.ndarray:
    """`base + delta`, refusing rather than wrapping outside the composed-bin range."""
    out = base + delta
    bad = (out < BIN_MIN) | (out > BIN_MAX)
    if bad.any():
        row = int(np.argmax(bad.any(axis=1) if bad.ndim > 1 else bad))
        raise _refuse(
            f"composing attribute {attribute} for gaussian id {int(ids[row])} leaves the signed 32-bit "
            f"range a composed bin must stay inside",
            "bin-overflow",
        )
    return out


def _rows_for(state_ids: np.ndarray, wanted: np.ndarray, what: str) -> np.ndarray:
    """Where each wanted id sits in the state, refusing any that is not there.

    The lookup is by identity and never by position: an encoder may order a chunk however
    it likes, so a delta that found its gaussians by row would be correct only for the
    ordering its own encoder happened to choose.
    """
    missing = np.setdiff1d(wanted, state_ids)
    if missing.size:
        raise _refuse(
            f"a delta {what} gaussian id {int(missing[0])}, which is not live at its reference",
            "unknown-gaussian-id",
        )
    order = np.argsort(state_ids, kind="stable")
    return order[np.searchsorted(state_ids[order], wanted)]


def _check_unique(ids: np.ndarray, what: str) -> None:
    if ids.size and np.unique(ids).size != ids.size:
        counts = np.bincount(np.unique(ids, return_inverse=True)[1])
        repeated = int(np.unique(ids)[int(np.argmax(counts))])
        raise _refuse(f"{what} names gaussian id {repeated} more than once", "duplicate-gaussian-id")


def _check_groups_disjoint(update_ids: np.ndarray, birth_ids: np.ndarray, death_ids: np.ndarray) -> None:
    for a, b, names in (
        (update_ids, birth_ids, "updated and born"),
        (update_ids, death_ids, "updated and killed"),
        (birth_ids, death_ids, "born and killed"),
    ):
        both = np.intersect1d(a, b)
        if both.size:
            raise _refuse(
                f"gaussian id {int(both[0])} is {names} by the same delta; the outcome would depend on "
                f"the order the groups are applied in",
                "id-in-two-groups",
            )


# --------------------------------------------------------------------------
# Seeking: the chain, answered from the index alone
# --------------------------------------------------------------------------


def check_tiling(index, duration_sec: float | None = None) -> None:
    """State chunks tile the timeline: no overlap, no gap, and no uncovered end.

    This is what makes the seek predicate a lookup rather than a search, and it is a real
    constraint — under `gaussian-birth` chunks may overlap freely, and here they may not.

    §11.1 states the rule in three parts, and adjacency is only the middle one: "sorted by
    `t0`, each chunk's `t1` equals the next chunk's `t0`; the first `t0` is `0`; the last
    `t1` is the Header's `duration_sec`". Checking adjacency alone passes a file whose
    chunks are perfectly adjacent over the middle of its timeline and cover neither end —
    and a single-entry index, which has no adjacent pair at all, was checked by nothing.
    A reader asked for an instant in the uncovered part then refuses a file the validator
    called clean, which is the report being wrong rather than the file being unusual.

    `duration_sec` is optional because a caller may hold an index before it holds the
    Header — the ends cannot be checked against a duration nobody passed. Every caller in
    this package passes it.
    """
    ordered = sorted(index, key=lambda e: e.t0)
    for previous, entry in pairwise(ordered):
        if previous.t1 != entry.t0:
            what = "overlap" if entry.t0 < previous.t1 else "leave a gap"
            raise _refuse(
                f"state chunks {what}: [{previous.t0}, {previous.t1}) is followed by [{entry.t0}, {entry.t1})",
                "non-tiling-chunks",
            )
    if duration_sec is None or not ordered:
        return
    if ordered[0].t0 != 0.0:
        raise _refuse(
            f"state chunks leave a gap: the timeline starts at 0 and the first chunk covers "
            f"[{ordered[0].t0}, {ordered[0].t1})",
            "non-tiling-chunks",
        )
    if ordered[-1].t1 != duration_sec:
        what = "overlap" if ordered[-1].t1 > duration_sec else "leave a gap"
        raise _refuse(
            f"state chunks {what}: the last chunk covers [{ordered[-1].t0}, {ordered[-1].t1}) and the "
            f"Header declares a duration of {duration_sec}",
            "non-tiling-chunks",
        )


def chain_for(index, t: float) -> list:
    """The keyframe and deltas a reader must read to reconstruct instant `t`.

    Answered from the index alone — no chunk is fetched to learn what another references —
    and returned oldest first, which is the order `apply_delta` composes in. The total
    byte cost is the sum of the entries' `chunk_length`, so a consumer can budget a seek
    before it issues a request.
    """
    by_offset = {entry.chunk_offset: entry for entry in index}
    current = next((entry for entry in index if entry.t0 <= t < entry.t1), None)
    if current is None:
        raise _refuse(f"no state chunk covers t={t}", "non-tiling-chunks")

    chain = [current]
    while chain[0].kind != 0:
        head = chain[0]
        if head.reference_offset >= head.chunk_offset:
            raise _refuse(
                f"the chunk at {head.chunk_offset} references {head.reference_offset}, which is not behind it; "
                f"references point backwards only",
                "forward-reference",
            )
        reference = by_offset.get(head.reference_offset)
        if reference is None:
            raise _refuse(
                f"the chunk at {head.chunk_offset} references {head.reference_offset}, which the index does not name",
                "broken-reference",
            )
        chain.insert(0, reference)
        if len(chain) > len(index):
            raise _refuse("the chain does not reach a keyframe", "chain-without-keyframe")

    # `level` is not in the index — it is a chunk field — so the rule that a delta's
    # reference shares its level is enforced where the records are read, not here.
    if len(chain) - 1 != current.depth:
        raise _refuse(
            f"the chunk at {current.chunk_offset} declares depth {current.depth}, but its chain walks "
            f"{len(chain) - 1} delta chunks; the index and the file disagree about the cost of this seek",
            "depth-mismatch",
        )
    return chain
