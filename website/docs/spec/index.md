# 4dgs format specification

**Version 1 (draft).** This document is normative. Key words MUST, MUST NOT, SHOULD, SHOULD NOT and
MAY are to be interpreted as described in RFC 2119.

A `.4dgs` file is a single, self-contained, seekable container for a **4D gaussian splat scene**:
gaussians whose position, opacity and existence vary continuously over time, optionally with an
embedded audio track and a default camera trajectory.

The format is **renderer-agnostic**. It defines how to reconstruct splat state at a given time and
nothing beyond that. How that state is drawn is out of scope.

---

## 1. Design goals

1. **One resource.** A whole scene — geometry, appearance, motion, audio, camera — is one file, one
   URL, one cache entry.
2. **Seekable without a sidecar.** Displaying an arbitrary instant reads the file's own index and
   then only the byte ranges that instant needs.
3. **Bounded memory.** Every read path is streamable; no conforming reader ever needs the whole file
   resident.
4. **Continuous time, not sampled frames.** Each gaussian carries its own temporal description, so
   the number of live gaussians varies over time without any frame machinery.
5. **Forward compatible by construction.** Every top-level structure is a length-prefixed record, so
   a reader skips what it does not recognize instead of failing.
6. **Stated error bounds.** Lossy encodings declare, per attribute, the maximum deviation a decoder
   may observe, and the encoder is expected to verify it.

---

## 2. Conventions

- All integers are little-endian and unsigned unless stated.
- `u8`, `u16`, `u32`, `u64`, `f32`, `f64` denote fixed-width types.
- `string` is `u32` byte length followed by that many UTF-8 bytes. Not NUL-terminated.
- `bytes` is `u64` byte length followed by that many bytes.
- `map<string, string>` is `u32` byte length of the whole block, then repeated `string` key /
  `string` value pairs filling exactly that block.
- Times are `f64` seconds on the **scene clock**, which starts at 0.
- Positions, scales and velocities are in the file's own coordinate units. The format does not
  impose a handedness or an up-axis; producers SHOULD record one in metadata.

---

## 3. Rendering semantics

A decoder reconstructs, for each gaussian, this state:

| field              | type    | meaning                                                          |
| ------------------ | ------- | ---------------------------------------------------------------- |
| `position`         | 3 × f32 | rest position                                                    |
| `scale`            | 3 × f32 | gaussian scale, linear                                           |
| `rotation`         | 4 × f32 | unit quaternion, xyzw                                            |
| `color`            | 4 × f32 | linear RGB and opacity, each in [0, 1]                           |
| `motion`           | 3 × f32 | linear velocity, units per second                                |
| `mu_t`             | f32     | temporal center, seconds                                         |
| `sigma_t`          | f32     | temporal standard deviation, seconds; `+inf` means "never fades" |
| `win_lo`, `win_hi` | f32     | validity window, seconds                                         |
| `sh[band]`         | varies  | optional view-dependent colour coefficients                      |

At scene time `t`:

```
visible  =  win_lo <= t < win_hi  AND  marginal >= cutoff
marginal =  sigma_t == +inf ? 1 : exp(-0.5 * ((t - mu_t) / sigma_t)^2)
center   =  position + motion * (t - mu_t)
opacity  =  color.a * marginal
```

`cutoff` is declared in the Header (default `0.05`). Decoders MUST apply the window test; it is what
allows one file to hold gaussians fitted independently over different spans of the timeline without
them bleeding into each other's intervals.

### 3.1 Visibility profiles

The temporal fields describe a soft fade, but the model also expresses a **hard** one. A gaussian
flagged as never-fading has a marginal of 1 across its whole validity window and is absent outside
it: full opacity, hard edges, no fade. That is a genuinely different visibility curve from the usual
bell, reached with fields that already exist and no extra machinery.

Producers SHOULD declare which they intend with the `visibility_profile` metadata key — `gaussian`
for the soft fade, `box` for the hard-edged one. It is a statement of intent for consumers and
tooling; both decode by the same arithmetic. The registry also reserves a third profile that this
version's wire model cannot express, so that the distinction stays explicit rather than being
blurred into `box`.

**The validity window is the format's only hard temporal gate.** `mu_t` and `sigma_t` describe a
soft fade; `win_lo`/`win_hi` describe existence. A gaussian outside its window does not exist at
that time, regardless of its marginal.

---

## 4. File layout

```
<magic>
<Header record>
<Quantization record>
<Window Table record>
[<Audio record>]                 -- omitted entirely when the scene has no audio
[<Camera record>]
[<Metadata record> ...]
[<Attachment record> ...]
<Chunk record> ...               -- the gaussian data
<Chunk Index record> ...         -- one per chunk, THE SUMMARY starts here
[<Statistics record>]
[<Summary Offset record> ...]
<Footer record>
<magic>
```

Order is normative only where stated: the Header MUST be the first record, the Footer MUST be the
last, and the summary MUST be contiguous (§4.5). The magic appears at both ends so a reader that has
only the tail of a file can still identify it and locate the Footer.

### 4.1 Magic

8 bytes: `0x89 0x34 0x44 0x47 0x53 0x31 0x0D 0x0A`

- `0x89` has the high bit set, so byte-oriented tooling does not mistake the file for text.
- `0x34 0x44 0x47 0x53` is ASCII `4DGS`.
- `0x31` is ASCII `1` — the **major version**. A reader that does not implement this version MUST
  refuse the file rather than guess.
- `0x0D 0x0A` is CR LF, which detects transports that mangle line endings.

### 4.2 Record framing

Every top-level structure is a record:

```
u8   opcode
u64  content_length
...  content_length bytes of content
```

**A reader MUST skip any record whose opcode it does not recognize**, using `content_length`, and
continue. This is the format's forward-compatibility mechanism and it is not optional.

**Records may be extended by appending fields.** A reader MUST NOT assume a record's content ends
where the fields it knows about end; it MUST use `content_length`. A writer MUST NOT insert or
reorder fields in an existing record, only append.

### 4.3 Opcode space

| range         | meaning                                                                 |
| ------------- | ----------------------------------------------------------------------- |
| `0x00`        | reserved, never emitted                                                 |
| `0x01`–`0x7F` | specification-defined records; new ones may be added in minor revisions |
| `0x80`–`0xFF` | **private / application range**; never defined by this specification    |

The private range is the designed extension point. An application MAY embed its own records there —
provenance, proprietary indexes, editor state — and any conforming reader will skip them cleanly.
Producers using the private range SHOULD include a Metadata entry naming the application, so a human
inspecting the file can tell what wrote them.

### 4.4 Frozen records

These records and their currently defined fields are **frozen**: their existing fields will not
change meaning, type, or order in any version 1 revision. Only appended fields may be added.

`Header (0x01)`, `Footer (0x02)`, `Quantization (0x03)`, `Window Table (0x04)`, `Chunk (0x05)`,
`Attribute Stream (0x06)`, `Chunk Index (0x08)`.

Anything else is provisional and MAY change before version 1 is declared stable.

### 4.5 The summary is contiguous

The **summary** is exactly the Chunk Index, Statistics and Summary Offset records — the records that
describe where things are rather than carrying content. A writer MUST emit them as one contiguous
run immediately preceding the Footer, and MUST NOT emit any other record inside that run. The
Footer's `summary_start` names its first byte, so the run is precisely the range `summary_crc`
covers.

This exists so a **streamed** reader can verify that checksum without buffering the file. Front to
back, a reader does not learn where the range starts until it reads the Footer, which is the last
record; contiguity lets it instead retain the trailing run of summary records as it goes and check
that at the end. The cost of doing so is the index, which an indexed reader would have loaded
anyway.

**Attachments are not summary records.** They carry payload, and payload of unbounded size — a
thumbnail sheet, a provenance blob. Admitting them into the run would make verifying a checksum cost
whatever the attachments happen to weigh, which defeats the reason the rule exists. They belong with
the other content records ahead of the chunks.

---

## 5. Records

### 5.1 Header — opcode `0x01`

```
string  profile          -- well-known profile name, or "" (see registry)
string  library          -- free-form producer identification
f64     duration_sec     -- scene length; playback covers [0, duration_sec)
u64     gaussian_count   -- total across all chunks
f64     cutoff           -- marginal visibility threshold, default 0.05
string  temporal_model   -- "gaussian-birth" for version 1 (see registry)
f64[6]  aabb             -- min xyz, max xyz over all rest positions
u8      sh_degree        -- 0..3; 0 means no spherical harmonics
u8      flags            -- bit 0: file contains an Audio record
                         -- bit 1: chunk data is compressed
                         -- bits 2-7: reserved, MUST be 0
map<string,string> attributes   -- free-form; see registry for well-known keys
```

`flags` bit 0 is the **audio discovery rule**: a reader answers "does this scene have audio?" from
the Header alone, with no further reads. See §7.

### 5.2 Footer — opcode `0x02`

```
u64  summary_start        -- byte offset of the first Chunk Index record, or 0
u64  summary_offset_start -- byte offset of the first Summary Offset record, or 0
u32  summary_crc          -- CRC-32 (IEEE) over [summary_start, footer_start), or 0
```

A reader seeking a random instant reads the last `8 + 1 + 8 + 20` bytes, takes `summary_start`, and
range-reads the index from there. `0` in `summary_start` means the file has no index and MUST be
read sequentially.

### 5.3 Quantization — opcode `0x03`

Declares the dequantization grids and the error bounds they guarantee.

```
string  scheme        -- well-known quantization scheme name (see registry)
f64[3]  pos_origin    -- position grid origin
f64     step_pos
f64     step_scale_log
f64     step_rot
f64     step_rgb
f64     step_alpha
f64     step_motion
f64     step_time
f64     step_sigma_log
u8      step_sh
map<string,string> bounds  -- declared max deviation per attribute, as decimal strings
```

The `bounds` keys are `pos`, `scale_rel`, `rot`, `rgb`, `alpha`, `motion`, `time`, `sigma_rel` and
`sh`. `scale_rel` and `sigma_rel` are relative deviations in the log domain; the rest are absolute,
in the unit of the attribute they name. A reader MAY ignore the map entirely — it is a producer's
declaration, not an instruction — but a reader that surfaces it MUST use these names, so that two
readers report the same number for the same file.

**Every numeric parameter in this record MUST be finite** — the three components of `pos_origin` and
all eight steps. Neither an infinity nor a NaN is a legal value for any of them.

A non-finite step is not a coarser grid; it is not a grid at all. Every bin multiplied by it decodes
to infinity or NaN, so a single such field turns the whole file's geometry into values with no
position to occupy, and it does so for every gaussian at once rather than for the one that was
corrupted. The rule constrains the parameters a writer may emit. It says nothing about the decode
arithmetic in §6, which is unchanged, and it adds no obligation to a decoder: a decoder's duty on a
malformed file is the one it already had, and this rule neither creates a new refusal nor removes an
existing one. Validators are where it is enforced — a tool that reports why a file is wrong SHOULD
report a non-finite quantization parameter as an error, naming the field.

Each stored integer bin is multiplied by its step (and exponentiated, for the log-domain scale and
sigma) to recover the value. Because every grid pitch is exactly twice its declared bound,
`|decoded - original| <= bound` holds by construction. Producers SHOULD verify this exhaustively at
encode time and record the measured maxima in `bounds`.

Two steps are **per-gaussian** and derived from a value the decoder has already read. Both are
defined in §6.3.

### 5.4 Window Table — opcode `0x04`

```
u32  count
     count × { f64 lo; f64 hi }
```

A file with no Window Table record, or one whose `count` is 0, is read as though it declared exactly
one window `(0, 0)`. Every gaussian then references index 0 and has an empty validity window, which
is a scene with nothing visible at any time — degenerate, but well defined, and not an error.

Gaussians reference windows by index. The table is small — one entry per distinct span in the scene
— so the per-gaussian cost is an index, not a pair of floats.

**A writer MUST NOT emit a window index outside the table, and a reader MUST refuse a file that
does**, naming the index and the table size. Clamping an out-of-range index silently substitutes one
gaussian's lifetime for another's, and it does so in a file that is already corrupt in some way
nobody has diagnosed yet; a decoder that clamps turns a detectable fault into wrong output.

### 5.5 Chunk — opcode `0x05`

A chunk holds the gaussians of one temporal interval.

```
f64     t0, t1        -- the chunk's interval; its gaussians are invisible outside it
u32     level         -- producer's hierarchy level; informational only
u32     count         -- gaussians in this chunk
string  compression   -- codec applied to the records below (see registry), or ""
u64     uncompressed_size
bytes   records       -- concatenated Attribute Stream records
```

Chunks are **independently decodable**: nothing in a chunk references another chunk.

`compression` names a codec applied to the whole `records` block, and `uncompressed_size` is the
length that block decompresses to. When `compression` is `""` the block is stored as-is and
`uncompressed_size` equals its length. **A reader MUST honour `compression`**: a reader that ignores
it decodes a compressed chunk as though the compressed bytes were attribute streams, which produces
wrong gaussians rather than an error. A reader that does not implement the named codec MUST refuse
the file and name the codec, which is a different failure from a corrupt one.

Compression is normally per stream, because that lets a reader decompress a chunk's attributes in
parallel and skip the ones it does not want. A chunk-level codec is the exception, not the default.

### 5.6 Attribute Stream — opcode `0x06`

Appears only inside a Chunk's `records` block.

```
u8   attribute_id     -- see registry
u8   symbol_width     -- 1, 2 or 4 bytes
u8   mode             -- 0 raw, 1 delta along element order, 2 constant
u8   codec            -- see registry
u8   channels         -- interleaving width
u32  element_count
u64  payload_length
...  payload_length bytes
```

Payload decoding, in order: decompress with `codec`; if `symbol_width > 1`, reverse the byte-plane
shuffle (plane `j` holds byte `j` of every symbol, so symbol `i` is `raw[j * n + i] << 8j` summed
over `j`); zigzag-decode each symbol (`(u >> 1) ^ -(u & 1)`); then apply `mode`.

`mode = 2` (constant) stores exactly `channels` symbols and repeats them `element_count` times.

After decompression every stage is integer arithmetic, so decoders in different languages produce
bit-identical integers and error cannot accumulate.

### 5.7 SH Band Stream — opcode `0x07`

Identical to Attribute Stream, prefixed with `u8 band` (1–3). Each band is stored in its own record
with its own byte range in the Chunk Index, so a reader that has decided to evaluate fewer bands
**never transfers the ones it will not use**.

The stream header inside this record carries `0x07` — this record's own opcode — in its
`attribute_id` field. That value collides with the attribute id of `mu_t`, and it is a version-1
quirk rather than a design: **a reader MUST NOT dispatch an SH band stream by its attribute id.**
Band streams are identified by the record that contains them and by the `band` byte in front of
them, and a reader that routes on the attribute id decodes spherical harmonics as birth times. A
future major version may assign the field properly; within version 1 it is fixed, because the
records already written cannot change.

Coefficients are `u8`, stored as written and consumed as read: `step_sh` describes what the encoder
did before it stored them and is **not applied at decode**. See §6.5.

### 5.8 Chunk Index — opcode `0x08`

```
f64  t0, t1
u64  chunk_offset          -- byte offset of the Chunk record
u64  chunk_length
u32  gaussian_count
u32  band_count
     band_count × { u8 band; u64 offset; u64 length }
```

Every offset and length here frames a **whole record**, opcode byte and content length included, so
a reader fetches `[offset, offset + length)` and parses it exactly as it would parse that record
mid-stream. That holds for `chunk_offset`/`chunk_length` and for each band's pair alike; there is no
range in this record that points at a record's content rather than at the record.

### 5.9 Audio — opcode `0x09`

See §7. Present only when the scene has audio.

```
string  codec        -- well-known audio codec name (see registry)
f64     start_sec    -- scene time at which the track's first sample plays
bytes   data         -- the encoded track, verbatim
```

### 5.10 Camera — opcode `0x0A`

```
f64     fov_y_deg
f64[3]  position
f64[3]  target
u32     keyframe_count
        keyframe_count × { f64 time; f64[3] position; f64[3] target }
string  interpolation   -- see registry
u8      loop            -- 0 or 1
```

A default viewpoint and optional suggested path. Purely advisory: a reader MAY ignore it entirely.

### 5.11 Metadata — opcode `0x0B`

```
string  name
map<string,string> entries
```

### 5.12 Statistics — opcode `0x0C`

```
u64  gaussian_count
u32  chunk_count
f64  duration_sec
f64[6] aabb
```

A summary a reader can trust without scanning chunks. Advisory: a reader that needs certainty MUST
compute from the chunks.

### 5.13 Attachment / Attachment Index — opcodes `0x0D` / `0x0E`

```
string  name
string  media_type
bytes   data
```

Arbitrary payloads — thumbnails, provenance, licences. Attachments are NOT the mechanism for audio;
audio has its own record because it is a first-class part of the scene.

### 5.14 Summary Offset — opcode `0x0F`

```
u8   group_opcode
u64  group_start
u64  group_length
```

Lets a reader range-read one class of index record without reading the others.

### 5.15 Provenance family — opcodes `0x20`–`0x2F`, RESERVED

**Reserved, not normative, and not to be emitted by a version-1 writer.** Recorded here so the shape
is known before anyone needs it, and so the opcodes are not spent on something else.

Scenes reconstructed from sensors carry context that consumers downstream — analysis, simulation,
quality review — need and that nothing in the format currently expresses. The reserved family
covers:

- **Sensor description** — per-sensor intrinsics and extrinsics, with the rig they were measured
  against.
- **Rig and ego trajectory** — the pose of the capture platform over the scene clock, distinct from
  the camera trajectory in §5.10, which is a viewing suggestion rather than a measurement.
- **Source timing** — per-chunk or per-gaussian acquisition timestamps, so a consumer can
  distinguish scene time from capture time when a rolling or multi-sensor capture makes them differ.
- **Semantic and instance labels** — per-gaussian class or instance identifiers.
- **Static and dynamic segmentation** — which gaussians belong to the fixed scene and which to
  moving content, which a producer often knows and a consumer otherwise has to infer.
- **Spatial framing** — coordinate frame, units, up-axis, and an optional georeference.

Some of this is expressible today as metadata keys (see the registry) for producers who need it
before the records exist. The distinction is that metadata is free-form text and these records would
be typed and indexable; a scene that only needs to say "z is up" should use metadata and always
will.

---

## 6. Gaussian attributes

### 6.1 Attribute streams

A chunk stores one Attribute Stream per attribute, structure-of-arrays, all with the same
`element_count` equal to the chunk's `count`. Registry §"Attribute ids" lists the ids; the required
set for version 1 is position, scale, rotation index, rotation, colour, opacity, motion, `mu_t`,
`sigma_t`, flags and window index.

Gaussians within a chunk MAY be reordered freely by the encoder; nothing in the format depends on
their order, and readers MUST NOT rely on it.

Encoders in practice order them for spatial locality, which makes the position delta stream much
smaller. That is an **encoder technique, not a property of the format**: no decoder needs to know
which ordering was used, and none may assume one. A future encoder that finds a better ordering
changes nothing a decoder has to implement.

### 6.2 Colour

Colour bins are stored as `(g, r - g, b - g)`. The transform is exact in the integer domain, so it
changes the compressed size and never the error bound. Decoders invert it before applying
`step_rgb`.

### 6.3 Per-gaussian precision

Two attributes have a grid pitch that varies per gaussian, derived from that gaussian's
already-decoded `sigma_t` bin. There is no side channel: a decoder recomputes the pitch with the
formulas below.

**Velocity.** A velocity error only becomes visible as displacement over the span the gaussian is on
screen, so precision follows lifetime:

```
half   = flags.always_visible ? (win_hi - win_lo) : K * exp(sigma_bin * step_sigma_log)
half   = clamp(half, 0.02, 2.0)
class  = clamp(ceil(log2(half / 0.5)), -4, 2)
step_i = step_motion * 2^(-class)
```

where `K = sqrt(-2 * ln(cutoff))` and `cutoff` is **the value in this file's Header**, not the
default. A decoder that substitutes a constant decodes different velocities than the encoder wrote
for any file that declares a different threshold, and the file gives it no way to notice. `ceil` is
required: the class's nominal lifetime must be an upper bound on the real one, or the displacement
guarantee fails by up to `sqrt(2)`. The guarantee is therefore on **displacement**: a decoded
velocity moves its gaussian by at most `bounds.pos` over `min(lifetime, 2 s)`.

**Birth time.** The temporal term reads `(t - mu_t) / sigma_t`, never `mu_t` alone, so `mu_t`
precision must be a fraction of the gaussian's own sigma. A gaussian with `sigma_t = 1 ms` and a 2
ms birth-time error is not slightly wrong — it is on when it should be off.

```
target = flags.always_visible ? step_time : min(step_time, 0.05 * exp(sigma_bin * step_sigma_log))
class  = clamp(floor(log2(target / step_time)), -10, 0)
step_i = step_time * 2^class
```

### 6.4 Rotation

Rotations use smallest-three: the largest-magnitude component is omitted and its sign canonicalized
positive, the other three are quantized on the `step_rot` grid in ascending component order, and the
omitted one is recovered as `sqrt(1 - sum of squares)` before the quaternion is renormalized.

`step_rot` bounds the three **stored** components. Reconstruction of the omitted component and the
renormalization can amplify that; producers SHOULD measure and declare the post-reconstruction
maximum in the Quantization record's `bounds`.

### 6.5 Spherical harmonics

Coefficients are unsigned bytes. A scene declares one degree for all of its gaussians in the
Header's `sh_degree`, and each degree above the constant term is stored in its own SH Band Stream
record: band 1 carries 3 coefficients per colour component, band 2 carries 5, band 3 carries 7,
which is `2b + 1` for band `b` and `(d + 1)² − 1` for a whole degree `d`.

Within a band's stream the channels are component-major: every coefficient of red, then of green,
then of blue. Bands are whole and a reader takes them whole — bands 1..D give exactly a degree-D
scene, and **a reader MUST NOT assemble a partial degree** out of part of a band.

`step_sh` in the Quantization record is an **encode-side** value: an encoder that coarsens
coefficients records the pitch it used so the file declares its own error, and a decoder does
nothing with it. The stored byte is the coefficient. Multiplying by `step_sh` at decode scales
appearance by a factor of one to three and is the single most likely way to misread this record.

---

## 7. Audio

Audio is a first-class part of a 4dgs scene, and **its absence is equally first-class**.

- A scene without audio contains **no Audio record, no placeholder, and no reserved bytes**. Header
  `flags` bit 0 is clear, and that is the entire signal.
- **Encoders MUST NOT embed a silent track** to satisfy the format. There is nothing to satisfy:
  absence is a valid, complete, conforming file, and it is the common case.
- A reader determines audio presence from the Header alone — no probing, no speculative range
  request.
- Readers SHOULD expose audio as an optional value (`Option`, nullable, `null`). Absence is a normal
  value, never an error and never a warning.
- The Audio record's `data` is the encoded track verbatim. A reader MAY range-read it independently
  of any gaussian data, and MAY skip it entirely.

**Clock rule.** When audio is present, the scene clock is the audio clock: scene time `t`
corresponds to audio time `t - start_sec`, and a player SHOULD treat the audio track as the timing
master. When audio is absent, the scene clock is self-contained — defined by the Header's
`duration_sec` and the gaussians' own windows — and playback semantics are fully defined without
reference to audio.

---

## 8. Seeking

The index gives one rule, and it is the whole seek algorithm:

```
chunks_for(t) = every Chunk Index entry whose [t0, t1) contains t
```

A reader displays instant `t` by reading the Footer, the index, and then those chunks' byte ranges.
Nothing else is required, and no chunk depends on another.

**Seek efficiency is a property of the content, not of the container.** Content whose gaussians have
finite validity windows partitions into many small chunks, and an instant costs a fraction of the
file. Content in which every gaussian is alive for the whole clip — which is what a temporal-field
or deformation-based fit produces once baked — has no such partition: every chunk covers the whole
timeline, the index degenerates to a single entry, and seeking costs the whole scene. Such content
stores and decodes correctly; it simply does not seek cheaply, and producers SHOULD say so in
metadata rather than let a consumer discover it by fetching 100 MB.

---

## 9. Profiles

A profile names a set of expectations beyond the base format — which records are present, which
attributes are populated. Profiles are listed in the registry. `profile = ""` means the base format
with no additional promises.

---

## 10. Versioning

The magic's version byte gates the whole file: a reader that does not implement it MUST refuse.
Within version 1:

- new record opcodes MAY be added in the `0x01`–`0x7F` range; readers skip what they do not know;
- existing records MAY gain appended fields; readers use `content_length`;
- frozen records (§4.4) MUST NOT have existing fields changed;
- new well-known strings (codecs, schemes, profiles, temporal models) are registry additions and do
  not change the version.

A change that breaks any of the above is a new major version and a new magic byte.

### 10.1 Reserved for a future version

Declared here so implementers know the direction, **not implemented and not to be emitted**:

- **`temporal_model = "deformation-field"`** — gaussians whose motion comes from a learned field
  evaluated per frame rather than baked per-gaussian linear velocity. Its wire form needs six
  things, all of which are ordinary records or streams: a normalization AABB plus the convention
  used to map into it; the plane-grid configuration (dimensions, resolutions, multi-resolution level
  count); the plane textures themselves as standard quantized 2D streams; the decoder-head weights;
  the sampling semantics (bilinear, align-corners, border padding, multiply-within-level and
  concatenate-across-levels); and per-head enable flags. Note that this model's evaluation is
  per-frame work on the consumer's critical path — a fundamentally different performance profile
  from the baked model, where a gaussian's motion is three numbers read once.
- **Per-gaussian SH degree**, so a scene can spend coefficients where they matter.
- **Spatial subdivision within a temporal chunk**, for level-of-detail by region.

---

## 11. Converting other representations

The reference implementation ships a converter for **sequences of standard 3D gaussian splat PLY
frames**, the common interchange form.

Content that is simply a sequence of independent time steps — no correspondence between them —
imports into this format's temporal model **always, and always correctly**: one validity window per
step, zero velocity. That is what the reference converter does. It is worth being plain about what
that does and does not claim: the result is a correct scene at every instant, and it exploits no
correspondence the source may have had, because a frame sequence asserts none. A source that _does_
track gaussians across steps carries information this import discards, and a converter that knows
about that tracking can do better.

Sources whose motion is analytic or field-based can be imported to the baked model by **adaptive
temporal sampling**: subdivide a gaussian's window only where the residual against linear motion
exceeds `bounds.pos`, so a gaussian that does not move collapses to a single record and one that
accelerates gets exactly as many records as its curvature requires. This keeps the import honest —
the error bound is the same one the rest of the file declares — without inheriting a per-frame
evaluation cost.

---

## 12. Changelog

Corrections and clarifications to this document. A row here never changes what a conforming
version-1 file looks like on the wire: where the text and the wire disagreed, the wire is the format
and the text was the bug.

| Change                                                                                                | Kind                      |
| ----------------------------------------------------------------------------------------------------- | ------------------------- |
| §5.1 Header `aabb` corrected from `f32[6]` to `f64[6]`, matching every file ever written              | correction                |
| §5.3 named the `bounds` map's keys                                                                    | clarification             |
| §5.4 stated the reading of an absent or empty Window Table, and that an out-of-range index is refused | clarification, rule added |
| §5.5 stated that a reader must honour a chunk's `compression`, and what `uncompressed_size` means     | clarification             |
| §5.7 stated that a band stream's `attribute_id` carries `0x07` and must not be dispatched on          | clarification             |
| §5.8 stated that every offset and length in the index frames a whole record                           | clarification             |
| §6.3 stated that `K` uses the Header's `cutoff` rather than the default                               | clarification             |
| §6.5 added: spherical harmonic layout, whole degrees, and that `step_sh` is not applied at decode     | clarification             |
| §4.5 added: the summary is exactly Chunk Index, Statistics and Summary Offset, and is contiguous      | rule added                |
| §5.3 added: every quantization step and origin MUST be finite                                         | rule added                |

The §5.3 row is a tightening of what a **writer** may emit, and it changes no existing file: every
quantization parameter any encoder here has ever written is finite, all 34 conformance variants
already satisfy it, none was regenerated for it, and no file's bytes or meaning move. What it
forbids is a value that only ever arrives by corruption. It is stated because the failure was silent
in the wrong direction — a non-finite step decodes without complaint into geometry that is entirely
infinity or NaN, and the first sign of it is a renderer drawing nothing rather than a reader saying
why. Making it a rule is what lets a validator name the field instead of leaving the reader to infer
it. It adds nothing to what a decoder must do; §6's arithmetic and every decoder's succeed-or-refuse
behaviour are untouched.

The §4.5 row is a tightening of what a **writer** may emit, not a migration. It changes no existing
file: all 34 conformance variants already satisfy it, none was regenerated, and no file's bytes or
meaning move. What it forbids is a shape the layout diagram used to permit — an Attachment record
sitting between the Statistics and Summary Offset records — which no encoder ever produced and which
would have made a streamed checksum cost whatever the attachment weighed.

The `aabb` row is the one worth reading twice. The text said `f32[6]` from the first draft and every
implementation wrote `f64[6]`, so a reader built from the specification alone desynchronized on the
Header and on every record after it. It was found by writing a new implementation from the published
documents and nothing else, which is the only way that class of error is ever found.
