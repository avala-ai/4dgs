# Proposal: the `keyframe-delta` temporal model — landed

**This proposal has landed. Its design is now normative.**

The `keyframe-delta` temporal model was accepted and folded into the specification. Its content now
lives in the normative documents, not here:

- The model — state chunks, identity (`gaussian_id`), composition, chaining, GOP-invariants, error
  bounds, seeking, failure modes and truncation — is [specification §11](../index.md).
- The Delta Chunk record (`0x10`) is [specification §5.18](../index.md), and the six appended Chunk
  Index fields are [specification §5.8](../index.md).
- The registry entries — `temporal_model = keyframe-delta` implemented, `frame-sequence` as a
  tombstone, attribute id 13 `gaussian_id`, the `keyframed` profile, and the advisory
  `keyframe_interval_sec` / `gop_max_depth` metadata keys — are in [the registry](../registry.md).

This file is kept as a pointer so that links to the proposal resolve to where the design now lives.
The changelog row that records the landing is [specification §13](../index.md#13-changelog).
