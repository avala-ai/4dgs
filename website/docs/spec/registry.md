# 4dgs registry

Well-known string and integer values referenced by [the specification](./index.md). Adding an entry
here is a registry change, not a format version change.

Values not listed here are legal but unrecognized: a reader that does not know a value MUST fail
cleanly with a message naming it, rather than guess.

---

## Attribute ids

Used by the Attribute Stream structure (`0x06`), which lives bare inside a Chunk rather than as a
top-level record — see spec §5.6.

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

**Spherical harmonics have no attribute id.** They travel in SH Band Stream records (`0x07`), one
per band, and the stream header inside such a record carries `0x07` in its `attribute_id` field —
the record's own opcode, which collides with `mu_t`'s id of 7. A reader identifies a band stream by
the record that contains it, never by that field. The collision is a version-1 quirk that a future
major version may clean up; see spec §5.7. Coefficients are `u8`, stored as written and read as
stored: `step_sh` records what the encoder did and is not applied at decode (spec §6.5).

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
and no decoding difference, because each representable profile is the existing arithmetic. See spec
§3.1.

| value      | status                          | notes                                                                                                                                                                  |
| ---------- | ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `gaussian` | representable                   | The usual soft temporal fade: opacity follows the marginal, a bell centred on `mu_t` with width `sigma_t`                                                              |
| `box`      | representable                   | Full opacity across the whole validity window and absent outside it, with no fade. Reached with the never-fades flag plus the window                                   |
| `flat-top` | **reserved, not representable** | A plateau at full opacity over a core interval with smooth shoulders either side. Distinct from `box`, whose edges are hard, and from `gaussian`, which has no plateau |

`flat-top` is reserved rather than defined because the version-1 wire model **cannot express it**: a
gaussian has one width and no plateau, so a curve that is flat in the middle and smooth at the edges
needs a temporal shape this format does not carry. Recent literature describes profiles of that
shape, which is exactly why the name is reserved here — it stops the term being applied loosely to
`box`, which is a different curve and the one this format actually has.

A producer needing a specific shoulder falloff cannot express it in a single gaussian today. It can
approximate one with several records, or accept the hard window edge that `box` gives.

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

## Provenance

Values used by the provenance records of spec §5.15. Every record in the family is optional; a file
that carries none of them is complete, and no Header flag announces them (spec §5.15.1).

### Handedness

Used by the Coordinate Frame record's `handedness` field.

| value | name          | notes                                                               |
| ----- | ------------- | ------------------------------------------------------------------- |
| 0     | `unspecified` | The producer did not state one. Not the same as either answer below |
| 1     | `right`       | Right-handed: `x × y = z` for the frame's own axes                  |
| 2     | `left`        | Left-handed                                                         |

`unspecified` is a value rather than an omission because a Coordinate Frame record that states an
up-axis and declines to state a handedness is a real and useful thing to write, and a reader has to
be able to tell that from a producer who meant `right` and wrote a zero.

### Signed axes

Used by the Coordinate Frame record's `up_axis` and `forward_axis` fields.

| value | axis |
| ----- | ---- |
| 0     | `+x` |
| 1     | `+y` |
| 2     | `+z` |
| 3     | `-x` |
| 4     | `-y` |
| 5     | `-z` |

`up_axis` and `forward_axis` must name different axes ignoring sign, so `+y` with `-y` is refused
along with `+y` with `+y`. See spec §5.15.2.

The Geodetic Anchor record's `heading_deg` is measured against `forward_axis`, so a frame that does
not state a meaningful forward axis cannot be georeferenced meaningfully either.

### Units of length

Used by the Coordinate Frame record's `length_unit` field. The record also carries
`metres_per_unit`. The two MUST agree — a file where they do not is non-conforming and a validator
reports it as an error — and a consumer handed such a file anyway takes `metres_per_unit`, which is
the number it computes with (spec §5.15.2).

| value | name          | metres per unit |
| ----- | ------------- | --------------- |
| 0     | `unspecified` | —               |
| 1     | `metre`       | 1               |
| 2     | `centimetre`  | 0.01            |
| 3     | `millimetre`  | 0.001           |
| 4     | `kilometre`   | 1000            |
| 5     | `foot`        | 0.3048          |
| 6     | `inch`        | 0.0254          |

A unit not on this list is spelled by leaving `length_unit` at `unspecified` and putting the ratio
in `metres_per_unit`, which is exactly the case the second field exists for.

### Sensor modalities

Used by the Sensor Calibration record's `modality` field. Unlike the fields above this one is a
string, because the set of things a rig can carry is open in a way an axis is not.

| value    | notes                                                        |
| -------- | ------------------------------------------------------------ |
| `""`     | Unstated                                                     |
| `camera` | Any imaging sensor with a projection model                   |
| `lidar`  | Time-of-flight ranging, spinning or solid-state              |
| `radar`  | Radio ranging                                                |
| `imu`    | Inertial measurement, no geometry of its own beyond its pose |
| `depth`  | A sensor producing per-pixel range, with a camera-like model |

A reader that does not recognize a modality still reads the record: `modality` describes the sensor,
`camera_model` describes the arithmetic, and it is the latter a consumer needs to project with.

### Camera models

Used by the Sensor Calibration record's `camera_model` field. `distortion_count` must match the
count this table gives, and the coefficients appear in the stated order.

| value | name             | coefficients | order                                                            |
| ----- | ---------------- | ------------ | ---------------------------------------------------------------- |
| 0     | `none`           | 0            | The sensor is not a camera, or its intrinsics were not recovered |
| 1     | `pinhole`        | 0            | No distortion term                                               |
| 2     | `brown-conrady`  | 5 or 8       | `k1 k2 p1 p2 k3` or `k1 k2 p1 p2 k3 k4 k5 k6`                    |
| 3     | `kannala-brandt` | 4            | `k1 k2 k3 k4` — the equidistant fisheye model                    |

Two lengths are legal for `brown-conrady` because the rational eight-coefficient form is a superset
of the five-coefficient one and both are in wide use; a reader implementing the five-coefficient
form that meets an eight-coefficient sensor has not met an unknown model, it has met one it can only
partly apply, and spec §5.15.3 says what to do about that — decline, and say so.

### Trajectory interpolation

Used by the Rig Trajectory record's `interpolation` field.

| value | name     | notes                                                                         |
| ----- | -------- | ----------------------------------------------------------------------------- |
| 0     | `linear` | Translation lerped, rotation slerped along the shortest arc. See spec §5.15.4 |
| 1     | `step`   | Both held at the earlier sample until the next one                            |

Distinct from the Camera record's `interpolation` field, which is a string and offers `spline`. A
rig trajectory is a measurement and a `spline` through measured poses invents intermediate poses the
platform did not occupy, so the name is deliberately not offered here.

---

## Metadata keys

Used by Metadata records and the Header's `attributes` map. All optional.

| key                              | meaning                                                                                                                                          |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `coordinate_system`              | e.g. `y-up-right-handed`. **Superseded** by the Coordinate Frame record (`0x20`); where both appear the record wins, in whole — see spec §5.15.2 |
| `source`                         | how the scene was produced, free-form                                                                                                            |
| `license`                        | licence of the scene content                                                                                                                     |
| `title`, `description`, `author` | human-facing scene identification                                                                                                                |
| `application`                    | producer of any private-range records in the file                                                                                                |

`coordinate_system` is superseded rather than removed. Files that predate the Coordinate Frame
record use it, it is the only way to say anything about a frame in a file whose reader is older than
§5.15, and a registry entry that vanished would make those files unreadable by the document that
described them. New producers should write the record.
