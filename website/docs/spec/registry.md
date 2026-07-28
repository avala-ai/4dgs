# 4dgs registry

Well-known string and integer values referenced by [the specification](./index.md). Adding an entry
here is a registry change, not a format version change.

Values not listed here are legal but unrecognized: a reader that does not know a value MUST fail
cleanly with a message naming it, rather than guess.

---

## Attribute ids

Used by the Attribute Stream record (`0x06`).

| id     | name             | channels | domain                                                           |
| ------ | ---------------- | -------- | ---------------------------------------------------------------- |
| 0      | `position`       | 3        | integer bins × `step_pos`, offset by `pos_origin`                |
| 1      | `scale`          | 3        | log domain; `exp(bin × step_scale_log)`                          |
| 2      | `rotation_index` | 1        | 0–3, index of the omitted quaternion component                   |
| 3      | `rotation`       | 3        | integer bins × `step_rot`                                        |
| 4      | `color`          | 3        | bins × `step_rgb`, after inverting the `(g, r−g, b−g)` transform |
| 5      | `opacity`        | 1        | bins × `step_alpha`                                              |
| 6      | `motion`         | 3        | bins × per-gaussian velocity step (spec §6.3)                    |
| 7      | `mu_t`           | 1        | bins × per-gaussian birth-time step (spec §6.3)                  |
| 8      | `sigma_t`        | 1        | log domain; `exp(bin × step_sigma_log)`                          |
| 9      | `flags`          | 1        | bit 0: never fades (`sigma_t = +inf`)                            |
| 10     | `window_index`   | 1        | index into the Window Table                                      |
| 11     | `source_group`   | 1        | optional producer-side grouping id                               |
| 12     | `source_index`   | 1        | optional producer-side stable id                                 |
| 13–63  | reserved         |          |                                                                  |
| 64–127 | private          |          | application-defined, readers skip                                |

Ids 0–10 are required in every chunk. Ids 11 and 12 are optional and exist so a producer can
round-trip stable identities through the format; readers that do not need them skip the streams.

---

## Stream codecs

Used by the Attribute Stream `codec` field and the Chunk `compression` field.

| value   | name      | notes                                                                                                                        |
| ------- | --------- | ---------------------------------------------------------------------------------------------------------------------------- |
| 0       | `deflate` | RFC 1950 zlib stream. **The default.** Universally available                                                                 |
| 1       | `zstd`    | RFC 8878. Better on some content; requires a binding on some platforms                                                       |
| 2       | reserved  | `atlas-image` — attributes packed into 2D atlases and coded with a standard image codec. A research direction, unimplemented |
| 3       | reserved  | `atlas-video` — the same, coded as video across time. A research direction, unimplemented                                    |
| 4–127   | reserved  |                                                                                                                              |
| 128–255 | private   |                                                                                                                              |

`""` (empty string) in the Chunk `compression` field means the records are stored uncompressed.

**On choosing a codec.** Byte-plane-shuffled quantized gaussian data is close to incompressible, so
the entropy coder is not where the bytes are: on representative content, deflate lands within about
2 % of a strong zstd setting. Writers SHOULD default to `deflate`, because a reader that already
exists on every platform is worth more than the difference. `zstd` is appropriate for archival
encodes where every byte counts and the consumer is known.

Rows 2 and 3 are named because packing attributes into images to let mature hardware codecs do the
compression is a real line of work — not because it is planned. Nothing here commits to either, and
no writer should emit them.

Because the codec is per-stream, a writer MAY mix them within one file.

---

## Quantization schemes

Used by the Quantization record's `scheme` field.

| value        | notes                                                                                                                                                                            |
| ------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `uniform-v1` | Uniform grids of pitch `2ε` per attribute, log domain for scale and sigma, per-gaussian steps for velocity and birth time as in spec §6.3. The only scheme defined for version 1 |

---

## Temporal models

Used by the Header's `temporal_model` field.

Dynamic gaussian scenes are produced by several distinct approaches, and a container that hard-codes
one of them is useless to the rest. This format implements one model and reserves names for the
others, so a producer from any of these lineages has somewhere to put its data without a
specification change.

| value               | status          | notes                                                                                                                                                                    |
| ------------------- | --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `gaussian-birth`    | **implemented** | Per-gaussian birth time, temporal sigma, linear velocity and validity window, as in spec §3. Motion belongs to each gaussian and is evaluated in closed form at any time |
| `frame-sequence`    | reserved        | Each time step is an independent set of gaussians, with no correspondence between steps                                                                                  |
| `keyframe-delta`    | reserved        | A base set plus per-step deltas against it, with correspondence maintained across steps                                                                                  |
| `deformation-field` | reserved        | Motion comes from a learned field evaluated per time step rather than baked per gaussian. See spec §10.1                                                                 |

**`frame-sequence`** would need a per-step record carrying that step's complete gaussian set, a
step-to-time mapping, and a statement of whether steps are uniformly spaced. The chunk and index
machinery already addresses time ranges, so the work is the record, not the container. Note that
importing such content into `gaussian-birth` — one validity window per step, zero velocity — is
always possible and always correct, and is what the reference converter does; it simply does not
exploit any correspondence the source had.

**`keyframe-delta`** would need a base gaussian set, delta records typed per attribute, a rule for
which gaussians a delta applies to, and a declared keyframe interval so a reader knows how far back
it must go to reconstruct a step. Its natural chunk boundary is the keyframe, which the existing
index expresses unchanged.

Both are reserved rather than designed. Naming them fixes the vocabulary and stops the names being
spent elsewhere; neither is implemented, and a version-1 writer must not emit them.

---

## Audio codecs

Used by the Audio record's `codec` field.

| value  | media type  | notes                                                                                |
| ------ | ----------- | ------------------------------------------------------------------------------------ |
| `wav`  | `audio/wav` | Uncompressed PCM in a RIFF container. Lossless, large, universally decodable         |
| `opus` | `audio/ogg` | Preferred for delivery: roughly an order of magnitude smaller at transparent quality |

An audio-bearing file MUST name one of these, or a private value the consumer is known to
understand. A file with **no** audio names nothing, because it carries no Audio record at all — see
spec §7.

---

## Visibility profiles

Declared with the `visibility_profile` metadata key. A statement of producer intent — no wire fields
and no decoding difference, because each of these is the existing arithmetic. See spec §3.1.

| value      | notes                                                                                                                                                                |
| ---------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `gaussian` | The usual soft temporal fade: opacity follows the marginal, a bell centred on `mu_t` with width `sigma_t`                                                            |
| `flat-top` | Full opacity across a core interval rather than peaking at a single instant. Recent literature describes this shape with smooth shoulders either side of the plateau |

Both are reached with the fields that already exist. `gaussian` is the marginal as written.
`flat-top` is reached by making the marginal saturate across the window — a gaussian wide enough
that its value stays at the ceiling for the whole validity window, with the window's own edges
bounding it.

One precision worth stating, because it decides whether a producer can round-trip its intent: the
plateau is exact, and the **shoulders are not**. A single gaussian has one width and no plateau, so
the version-1 wire model reaches the flat top by saturation and ends it at the window edge, which is
abrupt. A producer that needs a specific shoulder falloff cannot express it in one gaussian today,
and should either accept the window edge or split the gaussian into several records.

## Colour spaces

Declared with the `color_space` metadata key. The format stores colour as linear values in [0, 1]
and does not transform them; this key states what those values mean.

| value                   | notes                                                           |
| ----------------------- | --------------------------------------------------------------- |
| `srgb-rec709-display`   | Non-linear sRGB display-referred values with Rec. 709 primaries |
| `linear-rec709-display` | Linear display-referred values with Rec. 709 primaries          |

A file that declares neither leaves the interpretation to the consumer, which in practice means
display-referred sRGB. Producers SHOULD declare it: the same numbers mean visibly different things
under the two, and a consumer cannot tell them apart by inspection.

## Camera interpolation

| value    | notes                              |
| -------- | ---------------------------------- |
| `linear` | Piecewise-linear between keyframes |
| `spline` | Catmull-Rom through the keyframes  |

---

## Profiles

Used by the Header's `profile` field. A profile is a promise about what a file contains, so a
consumer can reject an unsuitable file up front instead of discovering a missing attribute
mid-decode.

| value     | promises                                                                                                                                                                                                       |
| --------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `""`      | Nothing beyond the base format                                                                                                                                                                                 |
| `capture` | Content fitted from a real capture: finite validity windows, a chunk index with more than one entry, statistics present. Seeks cheaply (spec §8)                                                               |
| `baked`   | Content baked from a temporal field or otherwise long-lived: gaussians may span the whole timeline, the index may hold a single entry, and an instant may cost the whole scene. Correct, but not cheap to seek |

Profiles constrain writers, not readers: a reader MUST be able to read any conforming file
regardless of its profile.

---

## Metadata keys

Used by Metadata records and the Header's `attributes` map. All optional.

| key                              | meaning                                           |
| -------------------------------- | ------------------------------------------------- |
| `coordinate_system`              | e.g. `y-up-right-handed`; the format imposes none |
| `source`                         | how the scene was produced, free-form             |
| `license`                        | licence of the scene content                      |
| `title`, `description`, `author` | human-facing scene identification                 |
| `application`                    | producer of any private-range records in the file |
