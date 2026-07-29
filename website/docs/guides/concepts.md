# Concepts

The vocabulary every document and every SDK in this project uses. Where a language's conventions
differ in casing or style, follow the language; do not rename the concept.

**Gaussian** — one splat: a position, scale, rotation, colour and opacity, plus the temporal fields
that say when it exists and how it moves. The atom of the format.

**Scene** — everything one `.4dgs` file describes: its gaussians, its timeline, and optionally its
audio sources and camera.

**Scene clock** — time in seconds from 0, the single authoritative timeline every gaussian,
audio-source start and audio pose keyframe refers to. No audio payload is its master.

**Audio source** — one independently timed encoded payload plus a source id, gain, channel layout,
and optional scene-space pose trajectory. A spatial point source is mono; a non-spatial source is a
scene-global channel bed.

**Audio source state** — the source facts reconstructed at scene time `t`: whether it is active, its
source-local playback time, gain, position and orientation. This is where format audio
reconstruction ends.

**Listener pose** — the listener's position and orientation in scene space. It is runtime state
supplied by the player, not stored in the file. The player combines it with audio source state to
choose HRTF or speaker panning, attenuation, occlusion and mixing.

**Validity window** — the half-open interval `[win_lo, win_hi)` during which a gaussian exists at
all. The format's only hard temporal gate: outside its window a gaussian is not faded, it is absent.

**Marginal** — the soft temporal weight of a gaussian at a time, from its birth time `mu_t` and
temporal extent `sigma_t`. Multiplies opacity; a gaussian whose marginal falls below the file's
`cutoff` is not drawn.

**Chunk** — the gaussians of one time interval, stored together and independently decodable. The
unit of seeking and of transfer.

**Chunk index** — the map from time to chunk byte ranges. What makes an instant cheap to display
without reading the file.

**Attribute stream** — one attribute of one chunk, stored structure-of-arrays: all the positions,
then all the scales, and so on. The unit of compression.

**Record** — a length-prefixed, opcode-tagged top-level structure. Everything in the file is one,
which is why unknown ones can be skipped.

**Profile** — a named promise about what a file contains beyond the base format, so a consumer can
reject an unsuitable file before decoding it.

**Bounds** — the maximum deviation a decoder may observe for each attribute, declared in the file by
the encoder that verified them.
