# 4dgs registry

Well-known string and integer values referenced by [the specification](./index.md).
Adding an entry here is a registry change, not a format version change.

Values not listed here are legal but unrecognized: a reader that does not know a value
MUST fail cleanly with a message naming it, rather than guess.

---

## Attribute ids

Used by the Attribute Stream record (`0x06`).

| id | name | channels | domain |
|---|---|---|---|
| 0 | `position` | 3 | integer bins × `step_pos`, offset by `pos_origin` |
| 1 | `scale` | 3 | log domain; `exp(bin × step_scale_log)` |
| 2 | `rotation_index` | 1 | 0–3, index of the omitted quaternion component |
| 3 | `rotation` | 3 | integer bins × `step_rot` |
| 4 | `color` | 3 | bins × `step_rgb`, after inverting the `(g, r−g, b−g)` transform |
| 5 | `opacity` | 1 | bins × `step_alpha` |
| 6 | `motion` | 3 | bins × per-gaussian velocity step (spec §6.3) |
| 7 | `mu_t` | 1 | bins × per-gaussian birth-time step (spec §6.3) |
| 8 | `sigma_t` | 1 | log domain; `exp(bin × step_sigma_log)` |
| 9 | `flags` | 1 | bit 0: never fades (`sigma_t = +inf`) |
| 10 | `window_index` | 1 | index into the Window Table |
| 11 | `source_group` | 1 | optional producer-side grouping id |
| 12 | `source_index` | 1 | optional producer-side stable id |
| 13–63 | reserved | | |
| 64–127 | private | | application-defined, readers skip |

Ids 0–10 are required in every chunk. Ids 11 and 12 are optional and exist so a producer
can round-trip stable identities through the format; readers that do not need them skip
the streams.

---

## Stream codecs

Used by the Attribute Stream `codec` field and the Chunk `compression` field.

| value | name | notes |
|---|---|---|
| 0 | `deflate` | RFC 1950 zlib stream. **The default.** Universally available |
| 1 | `zstd` | RFC 8878. Better on some content; requires a binding on some platforms |
| 2–127 | reserved | |
| 128–255 | private | |

`""` (empty string) in the Chunk `compression` field means the records are stored
uncompressed.

**On choosing a codec.** Byte-plane-shuffled quantized gaussian data is close to
incompressible, so the entropy coder is not where the bytes are: on representative
content, deflate lands within about 2 % of a strong zstd setting. Writers SHOULD default
to `deflate`, because a reader that already exists on every platform is worth more than
the difference. `zstd` is appropriate for archival encodes where every byte counts and the
consumer is known.

Because the codec is per-stream, a writer MAY mix them within one file.

---

## Quantization schemes

Used by the Quantization record's `scheme` field.

| value | notes |
|---|---|
| `uniform-v1` | Uniform grids of pitch `2ε` per attribute, log domain for scale and sigma, per-gaussian steps for velocity and birth time as in spec §6.3. The only scheme defined for version 1 |

---

## Temporal models

Used by the Header's `temporal_model` field.

| value | notes |
|---|---|
| `gaussian-birth` | Per-gaussian birth time, temporal sigma, linear velocity and validity window, as in spec §3. The only model defined for version 1 |
| `deformation-field` | **Reserved, not implemented.** See spec §10.1 |

---

## Audio codecs

Used by the Audio record's `codec` field.

| value | media type | notes |
|---|---|---|
| `wav` | `audio/wav` | Uncompressed PCM in a RIFF container. Lossless, large, universally decodable |
| `opus` | `audio/ogg` | Preferred for delivery: roughly an order of magnitude smaller at transparent quality |

An audio-bearing file MUST name one of these, or a private value the consumer is known to
understand. A file with **no** audio names nothing, because it carries no Audio record at
all — see spec §7.

---

## Camera interpolation

| value | notes |
|---|---|
| `linear` | Piecewise-linear between keyframes |
| `spline` | Catmull-Rom through the keyframes |

---

## Profiles

Used by the Header's `profile` field. A profile is a promise about what a file contains,
so a consumer can reject an unsuitable file up front instead of discovering a missing
attribute mid-decode.

| value | promises |
|---|---|
| `""` | Nothing beyond the base format |
| `capture` | Content fitted from a real capture: finite validity windows, a chunk index with more than one entry, statistics present. Seeks cheaply (spec §8) |
| `baked` | Content baked from a temporal field or otherwise long-lived: gaussians may span the whole timeline, the index may hold a single entry, and an instant may cost the whole scene. Correct, but not cheap to seek |

Profiles constrain writers, not readers: a reader MUST be able to read any conforming
file regardless of its profile.

---

## Metadata keys

Used by Metadata records and the Header's `attributes` map. All optional.

| key | meaning |
|---|---|
| `coordinate_system` | e.g. `y-up-right-handed`; the format imposes none |
| `source` | how the scene was produced, free-form |
| `license` | licence of the scene content |
| `title`, `description`, `author` | human-facing scene identification |
| `application` | producer of any private-range records in the file |
