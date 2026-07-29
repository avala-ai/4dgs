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

## 3. Reconstruction semantics

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
| `object_id`        | u32     | optional object membership; `0` means background / unassigned    |

At scene time `t`:

```
visible  =  win_lo <= t < win_hi  AND  marginal >= cutoff
marginal =  sigma_t == +inf ? 1 : exp(-0.5 * ((t - mu_t) / sigma_t)^2)
base_center = position + motion * (t - mu_t)
center      = base_center
orientation = rotation
opacity  =  color.a * marginal
```

`cutoff` is declared in the Header (default `0.05`). Decoders MUST apply the window test; it is what
allows one file to hold gaussians fitted independently over different spans of the timeline without
them bleeding into each other's intervals.

When a non-zero `object_id` has an Object Track (§5.15.7), the decoder then applies that track's
pose `(R(t), T(t))` exactly once, after reconstructing the base state:

```
center      = R(t) * base_center + T(t)
orientation = R(t) ⊗ rotation
```

The track is rigid: it changes only center and orientation. Scale, colour, temporal fields,
visibility and opacity remain the base values. A gaussian that also carries per-gaussian motion
therefore composes base first, track second; neither source of motion replaces the other. A gaussian
with `object_id = 0`, or whose object has no track, keeps the base center and orientation.

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
[<Provenance record> ...]        -- 0x20-0x2F; omitted entirely when the scene has none
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
`Attribute Stream (0x06)`, `Chunk Index (0x08)`. The Attribute Stream is a structure rather than a
top-level record (§5.6); it is frozen on the same terms, and `0x06` is its registry number.

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

A reader seeking a random instant reads the last **37 bytes**, takes `summary_start`, and
range-reads the index from there. `0` in `summary_start` means the file has no index and MUST be
read sequentially.

The 37 is worth spelling out, because it is the one number every seeking reader hardcodes and the
only way to check it is to know what it is made of:

| bytes | what                                                          |
| ----- | ------------------------------------------------------------- |
| 8     | the trailing magic (§4.1)                                     |
| 1     | the Footer's opcode (§4.2)                                    |
| 8     | the Footer's `content_length` (§4.2)                          |
| 20    | the Footer's content — `8 + 8 + 4` for the three fields above |

A reader that gets this wrong does not fail cleanly: it lands mid-field and reads a plausible
`summary_start` that points nowhere in particular.

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
-- appended fields follow; a record that ends here declares none of them
u8      sh_depth_count     -- number of per-band SH bit depths; the field is absent, not 0,
                           -- when a file declares none
        sh_depth_count × u8   -- band b's bit depth, 3..8, band 1 first (see §6.5)
```

The `bounds` keys are `pos`, `scale_rel`, `rot`, `rgb`, `alpha`, `motion`, `time`, `sigma_rel` and
`sh`, plus `sh_band1`, `sh_band2` and `sh_band3` on a file that declares per-band SH bit depths.
`scale_rel` and `sigma_rel` are relative deviations in the log domain; the rest are absolute, in the
unit of the attribute they name, and the `sh` keys are in **code units** — a stored byte's grid, not
a coefficient's — because that is the domain the bytes live in. A reader MAY ignore the map entirely
— it is a producer's declaration, not an instruction — but a reader that surfaces it MUST use these
names, so that two readers report the same number for the same file.

`object_id` is an exact label (§6.6), not a metric value. A writer MUST NOT put `object_id` in
`bounds`, and a reader MUST refuse a Quantization record that does: there is no meaningful error
bound between two different labels.

**The SH bit depths are a declaration, not an instruction.** A writer that quantizes coefficients by
bit depth MUST emit one entry per band it writes, in band order, each in the range 3–8, and MUST set
`bounds.sh_band<b>` from each depth by the rule in §6.5. A reader MAY ignore the field: nothing at
decode depends on it, because the byte a band stream carries is already the quantized value. A
reader that finds it malformed — a count the record is too short for, or a depth outside 3–8 — MUST
read the file as declaring none rather than refuse it. Appended fields are positional, so bytes
appended by some other writer land exactly where this field is, and a declaration about encoding
that has already happened is not worth failing a decodable file over. A validator SHOULD report the
inconsistency.

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
bytes   records       -- concatenated attribute streams (§5.6), back to back
```

The `records` block is **not** a sequence of records. It is a bare run of §5.6 field layouts laid
end to end, with no opcode and no length in front of each — the first byte of the block is the first
stream's `attribute_id`. A reader walks it by decoding each stream's header and stepping over its
`payload_length`, not by the record framing of §4.2. The field keeps the name `records` because it
is frozen (§4.4); the name is a misnomer, and this paragraph is the correction.

Chunks are **independently decodable**: nothing in a chunk references another chunk.

`compression` names a codec applied to the whole `records` block, and `uncompressed_size` is the
length that block decompresses to. When `compression` is `""` the block is stored as-is and
`uncompressed_size` equals its length. **A reader MUST honour `compression`**: a reader that ignores
it decodes a compressed chunk as though the compressed bytes were attribute streams, which produces
wrong gaussians rather than an error. A reader that does not implement the named codec MUST refuse
the file and name the codec, which is a different failure from a corrupt one.

Compression is normally per stream, because that lets a reader decompress a chunk's attributes in
parallel and skip the ones it does not want. A chunk-level codec is the exception, not the default.

### 5.6 Attribute Stream — structure `0x06`

**This is a structure, not a top-level record, and `0x06` is not an opcode that appears on the
wire.** An attribute stream exists only inside a Chunk's `records` block (§5.5), where it is written
bare — no opcode byte, no `content_length` — so `0x06` never frames anything. The number is the
registry identifier for the structure, and it is what a stream carries in its own `attribute_id`
field; it is listed among the frozen records in §4.4 for the same reason, as a registry entry rather
than as a record a reader will ever encounter at the top level.

The distinction matters to anyone writing a parser from this document: a reader that expects §4.2
framing here finds an `attribute_id` where it expects an opcode, and a `symbol_width` where it
expects the first byte of a 64-bit length. §5.7's SH Band Stream **is** a real top-level record —
`0x07` does appear on the wire — and its content is a `u8 band` followed by one of these bare
structures, which is the only place a stream is wrapped in record framing.

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

### 5.13 Attachment — opcode `0x0D`

```
string  name
string  media_type
bytes   data
```

Arbitrary payloads — thumbnails, provenance, licences. Attachments are NOT the mechanism for audio;
audio has its own record because it is a first-class part of the scene.

**`0x0E` (Attachment Index) is reserved; its body is not yet defined.** Earlier drafts of this
section gave `0x0D` and `0x0E` a single layout, which cannot have been right: the body above is one
attachment's name, type and payload, and an index over attachments is a different shape entirely.
Nothing has ever emitted `0x0E`, so no file is affected. It keeps its number, and a reader treats it
as it treats any record it does not recognize — step over it by `content_length` (§4.2). A writer
MUST NOT emit `0x0E` until this section defines it.

### 5.14 Summary Offset — opcode `0x0F`

```
u8   group_opcode
u64  group_start
u64  group_length
```

Lets a reader range-read one class of index record without reading the others.

### 5.15 Provenance family — opcodes `0x20`–`0x2F`

Scenes reconstructed from sensors carry context that consumers downstream — analysis, simulation,
quality review — need and that the rest of the format does not express. The family also carries the
scene's optional object table and rigid object tracks. Six opcodes are defined here; the rest stay
reserved (§5.15.8).

| opcode        | record             | §       | status   |
| ------------- | ------------------ | ------- | -------- |
| `0x20`        | Coordinate Frame   | §5.15.2 | defined  |
| `0x21`        | Sensor Calibration | §5.15.3 | defined  |
| `0x22`        | Rig Trajectory     | §5.15.4 | defined  |
| `0x23`        | Geodetic Anchor    | §5.15.5 | defined  |
| `0x24`        | Object Table       | §5.15.6 | defined  |
| `0x25`        | Object Track       | §5.15.7 | defined  |
| `0x26`–`0x2F` | —                  | §5.15.8 | reserved |

The first three run in dependency order, lowest first: a sensor's extrinsic and a rig's pose are
poses **in** a frame, and `0x20` is the record that names that frame. Geodetic Anchor holds `0x23`
because it was defined after them, not because it belongs last — a registry grows by taking the next
free number, and an opcode is not something a later revision gets to renumber for tidiness.

Nothing requires a reader to see these in any order; records are skipped and dispatched by opcode,
not by position. But a writer that emits them in ascending opcode order produces a file whose front
matter reads close to the order a human would explain it.

Every record in the family is **optional**. A file may carry a frame and nothing else, a rig
trajectory alone, object membership without a table, or a track for an object the table does not
name. References among the four capture-provenance records resolve as their sections require. The
three pieces of the object layer — membership, table and tracks — are independently optional by
design (§6.6).

These records are **provisional** in the sense of §4.4: they are not frozen, and their fields may
change before version 1 is declared stable. They may only be extended by appending, like every other
record.

#### 5.15.1 What the family costs when it is absent

**Nothing, and that is a rule rather than an accident.** A scene that uses none of this family
carries none of its records, no placeholder and no reserved bytes. Every record is optional,
whatever the profile, except that the `objects` profile makes its own promises (registry).

This is the audio precedent (§7) applied one record family further out, and it decides one question
explicitly: **the Header gets no presence flags for provenance.** Audio has one because audio
presence changes how the scene's clock is defined — when a track is present the audio clock is the
timing master — so a reader must know the answer _before_ it can interpret a time, and the Header is
the only place it can learn that without a read it might not otherwise make. A consumer already
walks the front matter record-by-record and learns which family records exist, and their byte
ranges, at no read beyond it. A flag would announce one record-header hop early something a reader
is about to learn anyway, and would spend the Header's scarce reserved flag bits doing it.

So the discovery rule for this family is: **walk the front matter; what is there is there.** A
reader MUST NOT infer the absence of a provenance record from anything but the walk, and MUST NOT
treat absence as an error or a warning. A file with no georeference is not an incomplete file.

**These are not summary records** (§4.5). They carry content, and trajectories are unbounded — a
ten-minute capture logged at 100 Hz is sixty thousand samples. They belong with the other content
records ahead of the chunks, for exactly the reason attachments do.

#### 5.15.2 Coordinate Frame — opcode `0x20`

```
string  name             -- frame identifier; "" is the file's own scene frame
u8      handedness       -- see registry
u8      up_axis          -- signed axis, see registry
u8      forward_axis     -- signed axis, see registry
u8      length_unit      -- see registry; 0 means unspecified
f64     metres_per_unit  -- length of one file unit in metres; 0.0 means unknown
```

The record describes **the frame the file's own coordinates are expressed in** — the frame §2 refers
to as "the file's own coordinate units" and declines to constrain. Every position, scale, velocity
and pose in the file is in this frame, including the extrinsics of §5.15.3 and the poses of §5.15.4.

The record is a **fixed shape**: every field is always present, and a reader that knows these six
knows exactly where an appended seventh would begin. That is deliberate, and it is why the
georeference is a separate record (§5.15.5) rather than an optional tail on this one. A conditional
block inside a record makes the offset of everything after it depend on a value, which is a rule a
future revision has to remember forever in order to append safely. The format already has an idiom
for something optional that costs nothing when absent: a record that is not there. Applying it here
costs a nine-byte record header in the files that carry a georeference at all, and keeps every
record in the format one shape.

`name` exists so a georeference can say which frame it anchors, the same way a sensor says which rig
it rides. `""` is the file's own scene frame and is what a single-frame file uses; a file that
defines exactly one frame need never mention the name again. **A reader MUST refuse a file with two
Coordinate Frame records of the same name**, for §5.15.3's reason about duplicate sensor names: a
frame is referred to by name and nothing else.

`up_axis` and `forward_axis` MUST name different axes, ignoring sign: a frame whose up and forward
are the same axis, or exact opposites, is not a basis. **A reader MUST refuse a file that declares
one**, naming both fields. The reasoning is §5.4's: a degenerate basis does not announce itself, it
silently re-orients everything a consumer computes from it, and a reader that repairs it by guessing
the third axis has turned a detectable fault into plausible wrong output.

`metres_per_unit` MUST be finite and MUST NOT be negative, for the reason §5.3 gives about
quantization steps: a non-finite scale is not a coarse scale, it is not a scale, and every
measurement derived from it becomes infinity at once. `0.0` is the legal way to say the scene has no
known physical size, which is the honest state of a great deal of reconstructed content.

**`length_unit` and `metres_per_unit` MUST agree.** A file declaring `metre` and `0.01` is
non-conforming, and a validator MUST report the disagreement as an error naming both fields — this
is not a shape a writer is allowed to emit, and calling it a warning would bless it.

That is a separate question from what a consumer does when handed such a file anyway, and the answer
to that is stated so that two consumers do not answer it differently: **`metres_per_unit` is the
authority.** The number is what a consumer computes with, the enum is what it prints, and a file
that disagrees with itself still has to produce one measurement rather than two. A reader is not
required to refuse here — unlike the degenerate basis above, a disagreement between these two fields
is detectable, reportable and recoverable, so refusing would cost a consumer a file it can use — but
it MUST NOT resolve it the other way, and a tool that reports files SHOULD say the file is wrong.

**Precedence over the `coordinate_system` metadata key.** The registry defines a free-form
`coordinate_system` key (e.g. `y-up-right-handed`), and files written before this record existed use
it. When a file carries **both** a Coordinate Frame record and a `coordinate_system` metadata entry:

- **the record wins, in whole**;
- a reader MUST NOT merge them, and MUST NOT fall back to the key for a field it did not like in the
  record;
- a writer SHOULD emit only the record, and a writer that emits both MUST make them agree.

Merging is called out because it is the tempting thing to do and it is wrong: the key is one string
describing a whole convention, so half of it cannot be true. A reader that took the handedness from
the record and the up-axis from the key would produce a frame no producer ever described.

#### 5.15.3 Sensor Calibration — opcode `0x21`

**One record per sensor.** A file with five cameras carries five of these, each with its own `name`,
each independently range-readable. This follows §5.7's shape for spherical harmonic bands and
§5.11's for metadata: a consumer that wants one sensor fetches one record.

```
string  name              -- sensor identifier, unique within the file
string  modality          -- see registry; "" when unstated
u8      camera_model      -- see registry; 0 when the sensor is not a camera
u32     width_px          -- 0 when camera_model is 0
u32     height_px         -- 0 when camera_model is 0
f64     fx, fy            -- focal length in pixels
f64     cx, cy            -- principal point in pixels, from the top-left corner
u8      distortion_count
        distortion_count × f64   -- coefficients, in the order the model defines
f64[4]  rotation          -- unit quaternion, xyzw
f64[3]  translation
u8      pose_reference    -- 0: the pose maps sensor to the scene frame
                          -- 1: the pose maps sensor to a rig frame; compose with §5.15.4
string  rig_name          -- the Rig Trajectory this composes with; "" when pose_reference is 0
```

`name` MUST be unique within a file. **A reader MUST refuse a file with two Sensor Calibration
records of the same name**, naming it: sensors are referred to by name and nothing else, so a
duplicate makes every such reference ambiguous, and picking the first or the last is a coin toss
performed silently.

**The extrinsic maps sensor coordinates into the frame `pose_reference` names**, in that direction:

```
p_target = R(rotation) * p_sensor + translation
```

The direction is stated because the opposite convention is equally common in the field, both are
plausible, and a consumer that assumes wrongly gets a scene that is merely mis-placed rather than
one that fails. `rotation` is a unit quaternion in `xyzw` order — the same order and the same
convention as §3 and §6.4, so no component shuffle is ever needed inside this format. A reader
SHOULD renormalize it, as §6.4 does, and MUST refuse one whose norm is zero or non-finite.

`pose_reference` exists because "the sensor's pose" has two different answers depending on whether
the rig moved. A static rig has one pose per sensor and `pose_reference = 0` says so directly. A
moving rig's sensors have a fixed pose **relative to the rig** and a time-varying pose in the scene,
and `pose_reference = 1` says that the extrinsic is the fixed part, to be composed with the named
Rig Trajectory:

```
p_scene(t) = R(q_rig(t)) * (R(rotation) * p_sensor + translation) + t_rig(t)
```

When `pose_reference` is `1`, `rig_name` MUST match the `name` of a Rig Trajectory record in the
same file, and **a reader MUST refuse a file where it does not**, naming the missing trajectory. An
extrinsic relative to a rig that is not in the file is not a pose at all, and a reader that fell
back to treating it as a scene-frame pose would place every sensor at the rig's origin — plausible,
wrong, and silent, which is the combination this format refuses everywhere else.

**Intrinsics.** Every `f64` in this record MUST be finite. When `camera_model` is not `0`, `fx` and
`fy` MUST be non-zero and `width_px` and `height_px` MUST be non-zero. When `camera_model` **is**
`0` — a lidar, a radar, an IMU, or a camera whose intrinsics were not recovered — `width_px`,
`height_px`, `fx`, `fy`, `cx`, `cy` MUST all be `0` and `distortion_count` MUST be `0`. Those
thirty-two zero bytes are the one place this design accepts a placeholder, and it buys a single
record shape for every sensor a rig carries: the alternative is a second record type that differs
only by omission, and two shapes to keep in step forever.

`distortion_count` MUST match what the named model defines (see the registry). **A reader that does
not implement the named `camera_model` MUST NOT apply a partial correction** — it MUST either
decline to undistort and report the sensor as uncorrected, or refuse the file, naming the model. A
half-applied distortion model is worse than none: undistorting with the first two coefficients of a
five-coefficient model produces an image that looks corrected and is not.

#### 5.15.4 Rig Trajectory — opcode `0x22`

The measured pose of the capture platform over the scene clock.

```
string  name             -- the platform this describes; "" is the file's capture rig
u8      interpolation    -- see registry
u32     sample_count
        sample_count × { f64 time; f64[4] rotation; f64[3] translation }
```

This is **a measurement**, and it is not the Camera record of §5.10, which is a viewing suggestion a
reader may ignore entirely. Nothing about a Rig Trajectory is advisory to a consumer doing analysis
or simulation: it is where the sensors were.

`time` is on the **scene clock** — `f64` seconds from 0, exactly as §2 defines it and exactly as
`mu_t`, the window table and the chunk intervals use it. When the file carries audio, §7's clock
rule applies here too and the audio track is the timing master, because there is one clock in a
`.4dgs` file and this record is on it. A producer whose capture timestamps are on some other epoch
MUST convert them; carrying the original epoch is what a Metadata record is for.

`rotation` and `translation` mean what they mean in §5.15.3:
`p_scene = R(rotation) * p_rig + translation`, with the quaternion in `xyzw` order.

`time` MUST be **strictly increasing** across the samples. **A reader MUST refuse a trajectory whose
times are not**, naming the sample index: a repeated or reversed timestamp makes the interval
containing it ambiguous, and every rule below is stated in terms of the interval a query lands in.

**Interpolation.** Between consecutive samples `i` and `i + 1`, with `u = (t - time[i]) / (time[i+1]

- time[i])`:

- `linear` — translation is `lerp(t[i], t[i+1], u)`; rotation is the **shortest-arc** slerp, which
  means negating the second quaternion when the dot product of the two is negative. That negation is
  not an optimization: `q` and `−q` are the same rotation, so without it a trajectory takes the long
  way round between two poses that were a degree apart, for one interval, once per sign flip.
- `step` — both are held at sample `i` until `time[i+1]`.

**Outside the sample range the pose is clamped, never extrapolated**: before `time[0]` it is sample
`0`, at or after `time[sample_count - 1]` it is the last sample. Extrapolating a rig pose from two
samples produces a platform that accelerates away from the scene at the ends of the clip, which is
never what the capture did.

A trajectory with `sample_count == 0` carries no pose and MUST be read as though the record were
absent; a producer SHOULD omit the record instead. A trajectory with exactly one sample is a static
rig, and every query returns that sample — which is the clamping rule with nothing to interpolate
between, not a special case.

#### 5.15.5 Geodetic Anchor — opcode `0x23`

```
string  frame_name     -- the Coordinate Frame this anchors; "" is the scene frame
f64     latitude_deg   -- WGS-84 geodetic latitude of the frame's origin, degrees
f64     longitude_deg  -- WGS-84 longitude of the frame's origin, degrees
f64     altitude_m     -- height of the frame's origin above the WGS-84 ellipsoid, metres
f64     heading_deg    -- bearing of the frame's forward axis, degrees clockwise from true north
```

Places a frame's **origin** — the point `(0, 0, 0)` in that frame's coordinates — on the WGS-84
ellipsoid, and states where the frame's `forward_axis` points. Together with the frame's
`metres_per_unit` that is enough to put a scene on a map.

It is deliberately not a full geodetic transform. A producer needing a projected coordinate system,
a geoid model or a datum other than WGS-84 should carry it in a Metadata record or an Attachment;
this record answers "roughly where on Earth is this" and stops, which is the question consumers
actually ask of reconstructed content.

`frame_name` MUST match the `name` of a Coordinate Frame record in the same file, and **a reader
MUST refuse a file where it does not**, naming the frame it could not find. An anchor for a frame
the file does not define is not a georeference — it is a latitude and longitude attached to nothing,
and a reader that quietly applied it to whatever frame happened to be there would put a scene
somewhere no producer ever claimed.

`latitude_deg` MUST be in `[-90, 90]`, `longitude_deg` in `[-180, 180]`, `heading_deg` in
`[0, 360)`, and every field MUST be finite. **A reader MUST refuse a value outside those ranges**:
unlike a unit disagreement there is no second field to fall back on, and an out-of-range latitude
has no reading that is merely approximate.

At most one Geodetic Anchor may name any one frame. **A reader MUST refuse a file with two anchors
for the same frame**, naming it, for the same reason it refuses two frames or two sensors sharing a
name: picking one silently is a coin toss with a scene's location on it.

#### 5.15.6 Object Table — opcode `0x24`

One scene-wide record names and describes objects. Everything in it is advisory: no field in the
table transforms a gaussian. Object membership comes from the `object_id` attribute (§6.6), and
geometry changes only through Object Tracks (§5.15.7).

```
u32     object_count
u16     embedding_dim         -- dimensionality of every embedding; 0 = no embedding space
        object_count × {
  u32     object_id
  string  label
  f32[3]  anchor
  u8      dynamics_present    -- 0 or 1
  [ f32[3] velocity           -- present iff dynamics_present == 1
    f32[3] angular_velocity
    f32[3] acceleration ]
  u8      has_embedding       -- present iff embedding_dim > 0; 0 or 1
  [ embedding_dim × f32 embedding ] -- present iff embedding_dim > 0 and has_embedding == 1
}
```

`object_id` matches the per-gaussian attribute. Entries MUST have distinct ids; a reader MUST refuse
a table with two entries for the same id, naming it. An entry for `0` is legal and may label the
background. `label` is free-form UTF-8 and may be empty.

`anchor` is a representative point for labelling or navigation. It is not a transform pivot.
`velocity`, `angular_velocity` and `acceleration` are an optional coarse motion summary. They never
replace an Object Track and reconstruction reads none of them. `embedding` is one optional
text-aligned vector per object. One file declares one embedding space and dimension; cosine
similarity is the comparison for a query encoded into the same space, while the model that creates
either vector is outside the format.

Every stored `f32` MUST be finite. `dynamics_present` and `has_embedding` MUST be `0` or `1`.
`object_count`, `embedding_dim` and every conditional block MUST be checked against the record's
remaining bytes before allocation. A reader MUST refuse a declared count that cannot fit, naming the
count and record.

A file carries at most one Object Table. A reader MUST refuse a second one. A missing table is valid
even when gaussians carry non-zero object ids or Object Tracks exist: grouping, description and
motion are independent capabilities.

#### 5.15.7 Object Track — opcode `0x25`

One record carries one object's rigid pose sampled over the scene clock:

```
u32     object_id
u8      interpolation      -- trajectory interpolation registry: 0 linear, 1 step
u32     sample_count
        sample_count × { f64 time; f64[4] rotation; f64[3] translation }
```

The pose is relative to the object's stored rest configuration. At time `t`, it transforms the fully
reconstructed base center and orientation by §3. It does not replace the base state and does not
change scale, colour, temporal fields, visibility or opacity.

The record uses Rig Trajectory's pose rules (§5.15.4): times MUST be finite and strictly increasing;
rotations are `xyzw` quaternions, renormalized by readers, with zero or non-finite norms refused;
translations MUST be finite; `linear` lerps translation and shortest-arc slerps rotation; `step`
holds the earlier pose; and queries outside the sample range clamp to the nearest sample rather than
extrapolate. A zero-sample track has no pose and is read as absent; one sample is a static
placement. `sample_count` MUST be checked against the record's remaining bytes before allocation.

`object_id` MUST NOT be `0`, because `0` means no object. A file carries at most one track for any
object; a reader MUST refuse a duplicate and name the id. A track whose id appears in no gaussian or
Object Table entry remains valid.

#### 5.15.8 Still reserved — opcodes `0x26`–`0x2F`

**Reserved, not normative, and not to be emitted by a version-1 writer.** This range remains for
source timing: per-chunk or per-gaussian acquisition timestamps that distinguish scene time from
capture time when a rolling or multi-sensor capture makes them differ.

---

## 6. Gaussian attributes

### 6.1 Attribute streams

A chunk stores one Attribute Stream per attribute, structure-of-arrays, all with the same
`element_count` equal to the chunk's `count`. Registry §"Attribute ids" lists the ids; the required
set for version 1 is position, scale, rotation index, rotation, colour, opacity, motion, `mu_t`,
`sigma_t`, flags and window index. `source_group`, `source_index` and `object_id` are optional.

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

#### What a stored byte means

A coefficient byte `b` is the value

```
coefficient = -4 + b * 8 / 255
```

on the closed interval `[-4, +4]`, and a producer whose coefficients fall outside it MUST clamp
them. This is fixed for version 1 and is not declared anywhere in the file, because there is nothing
to declare: every byte in every conforming file already means this.

The rule exists because "the stored byte is the coefficient" answers a different question than the
one a consumer asks. It says a decoder must not rescale, and it is right about that. But anything
that hands a renderer or another format _floats_ — an exporter, a converter, a shader that evaluates
the basis — needs the affine map, and a specification that does not state it invites each consumer
to invent one. Two that disagree do not fail: they produce a scene whose higher-degree colour shifts
on the way through, silently, with nothing in the file to point at.

#### Bit depth

A band MAY be quantized more coarsely than its byte allows. Each band declares a **bit depth** `n`
in the range 3–8, carried in the Quantization record's appended SH bit-depth fields (§5.3). Its
coefficients are stored on a grid of pitch

```
q     = 2^(8 - n)                 -- code units
b     = floor(original / q) * q + floor(q / 2)
bound = floor(q / 2)              -- code units; bound * 8 / 255 in coefficient units
```

Reconstruction is at the bin centre, which is what makes the bound half the pitch rather than the
whole of it and what makes the operation idempotent — a coefficient already on the grid is left
alone, so re-encoding a file at the depth it already carries changes no byte. **Eight bits is the
identity**: pitch 1, bound 0, the byte stored as it arrived. A file that declares no depths is a
file at eight bits in every band, which is what every file written before the field existed does,
and the general rule and the original one are therefore the same rule.

Nothing sub-byte is packed. A band stream at three bits is still a stream of bytes, taking eight
distinct values; the size it saves is saved by the stream codec, which has that many fewer symbols
to code. **No decoder changes for this**, and none may treat a declared depth as an instruction to
unpack anything.

Depths SHOULD fall with band index. A band's energy falls with its degree, so the coefficients that
tolerate the coarsest grid are the ones there are most of — band 3 carries seven coefficients per
colour component to band 1's three.

When a file declares per-band depths, `step_sh` MUST carry the **coarsest** band's pitch and
`bounds.sh` the coarsest band's bound. Both fields predate per-band depths and a consumer may read
only them; the worst case is the only value that is true of the whole file rather than of some of
it.

### 6.6 Object membership

`object_id` is an optional one-channel `u32` Attribute Stream with attribute id `14`. `0` means
background / unassigned. A chunk that omits the stream is read as though every gaussian in that
chunk carried `0`; mixed scenes may therefore omit it from chunks containing only background.

The id is exact and is never dequantized. Attribute Stream symbols are signed 32-bit values after
zigzag decoding, while the id owns the full unsigned 32-bit domain. The bridge is a same-bits
two's-complement view:

- before stream encoding, a writer views each `u32` id as the `i32` with the same 32 bits;
- after stream decoding, a reader verifies the code fits `i32` and views those same bits as `u32`.

Thus `0x7FFF_FFFF` maps to `2147483647`, `0x8000_0000` maps to `-2147483648`, and `0xFFFF_FFFF` maps
to `-1`. This mapping is bijective and changes no label. A writer MAY delta-code the signed codes
only when every resulting delta fits the stream's 32-bit symbol width; raw mode is always available.

The Object Table (§5.15.6), Object Tracks (§5.15.7) and `object_id` stream are independently
optional. A file with ids and no table still groups gaussians; a table may describe an object no
current chunk carries; and a track may move an object without a table entry. None is a reason to
invent or discard another.

At reconstruction time, a track is selected by the gaussian's `object_id` and composed exactly as §3
defines: first reconstruct the complete base state, including per-gaussian motion, then apply the
one matching rigid track to center and orientation. At most one track may name an id, so the mapping
is unambiguous. Decoding ends at that reconstructed gaussian state.

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
- **A declared SH coefficient interval.** §6.5 fixes the byte-to-coefficient map to `[-4, +4]`, and
  content whose coefficients leave that interval has to clamp. Declaring the interval per file would
  lift the clamp, at the cost of a value every consumer must read and no consumer can default. It is
  named here so that the fixed interval reads as a decision rather than an oversight.
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

| Change                                                                                                                          | Kind                      |
| ------------------------------------------------------------------------------------------------------------------------------- | ------------------------- |
| §5.1 Header `aabb` corrected from `f32[6]` to `f64[6]`, matching every file ever written                                        | correction                |
| §5.3 named the `bounds` map's keys                                                                                              | clarification             |
| §5.4 stated the reading of an absent or empty Window Table, and that an out-of-range index is refused                           | clarification, rule added |
| §5.5 stated that a reader must honour a chunk's `compression`, and what `uncompressed_size` means                               | clarification             |
| §5.7 stated that a band stream's `attribute_id` carries `0x07` and must not be dispatched on                                    | clarification             |
| §5.8 stated that every offset and length in the index frames a whole record                                                     | clarification             |
| §6.3 stated that `K` uses the Header's `cutoff` rather than the default                                                         | clarification             |
| §6.5 added: spherical harmonic layout, whole degrees, and that `step_sh` is not applied at decode                               | clarification             |
| §4.5 added: the summary is exactly Chunk Index, Statistics and Summary Offset, and is contiguous                                | rule added                |
| §5.3 added: every quantization step and origin MUST be finite                                                                   | rule added                |
| §5.5/§5.6 corrected: a chunk's streams are bare structures, not records, and `0x06` is not an opcode                            | correction                |
| §5.13 stated that `0x0E` is reserved with no defined body, rather than sharing the Attachment's                                 | clarification             |
| §5.2 named the terms of the 37-byte tail a seeking reader reads                                                                 | clarification             |
| §5.15 added: Coordinate Frame `0x20`, Sensor Calibration `0x21`, Rig Trajectory `0x22` and Geodetic Anchor `0x23`, all optional | rule added                |
| §5.15.2 added: a Coordinate Frame record supersedes the `coordinate_system` metadata key                                        | rule added                |
| §6.5 added: a stored SH byte is the coefficient `-4 + b * 8 / 255`, on a fixed interval                                         | clarification, rule added |
| §5.3/§6.5 added: per-band SH bit depths, appended to the Quantization record                                                    | rule added                |
| Registry: reserved attribute ids 32–47 and the `relightable` profile for a future relighting extension; named, not defined      | reserved, rule added      |
| §3/§5.15.6–§6.6 added: exact `object_id`, Object Table `0x24`, Object Track `0x25`, and base-then-track composition             | rule added                |

The object-layer row is additive and changes no existing file. Attribute id `14` and opcodes
`0x24`/`0x25` were reserved and unemitted; a file that carries none of them is byte-identical to the
file it was before the layer existed. A reader that does not know the layer skips its streams and
records by their declared lengths and reconstructs the valid base scene. A reader that does know it
additionally returns exact membership, descriptions, and the post-track center and orientation
defined in §3. The conformance corpus contains a tracked-object variant whose streamed and indexed
reconstructions agree on that post-transform state.

The relighting row reserves names and defines nothing. It changes no existing file — it forbids
nothing a version-1 writer does today, adds no field to any record, and touches no byte in any of
the conformance variants, which carry none of these ids and none of this profile. What it adds is a
rule about what a **new** file may say: ids 32–47 and the `relightable` profile are reserved, a
version-1 writer MUST NOT emit them, and a version-1 reader skips an attribute stream it does not
know by its length exactly as it already skips a private-range one. The registry entry states what
the eventual relighting attributes will be called; it deliberately decides nothing about the
material model, the quantization of any attribute, or whether surface normals are stored or derived.
It is the temporal models' and the reserved provenance opcodes' precedent applied once more: reserve
the ground, define nothing speculative.

The two §5.15 rows add records rather than tighten a rule, and they **change no existing file**. The
opcodes they define were reserved and unemitted, so no file in the world carries one; all
thirty-four conformance variants that existed before them still encode to the same bytes and decode
to the same meaning, and not one was regenerated; and because every record in the family is optional
with no Header flag announcing it (§5.15.1), a file that does not want provenance is byte-identical
to the file it would have been. That is not only an argument — three of this repository's five
implementations skip these records by length and pass the whole pre-existing corpus without a line
of change, which is the forward-compatibility mechanism of §4.2 doing exactly what it was written
for.

What changes is what a **new** file may say. The precedence row is the one with teeth: a producer
that has been writing `coordinate_system` as metadata keeps working unchanged, and only a file
carrying both the key and the record has a question to answer — which is why the answer is stated
before anyone can write that file rather than after. The §5.3 row is a tightening of what a
**writer** may emit, and it changes no existing file: every quantization parameter any encoder here
has ever written is finite, all 34 conformance variants already satisfy it, none was regenerated for
it, and no file's bytes or meaning move. What it forbids is a value that only ever arrives by
corruption. It is stated because the failure was silent in the wrong direction — a non-finite step
decodes without complaint into geometry that is entirely infinity or NaN, and the first sign of it
is a renderer drawing nothing rather than a reader saying why. Making it a rule is what lets a
validator name the field instead of leaving the reader to infer it. It adds nothing to what a
decoder must do; §6's arithmetic and every decoder's succeed-or-refuse behaviour are untouched.

The two §6.5 rows are the same kind of change from opposite directions, and neither moves a byte in
any file that exists.

The **mapping** row writes down what every implementation already did. The text said the stored byte
is the coefficient and stopped there, which is a complete answer for a decoder and no answer at all
for an exporter, and an exporter needs one — so the reference codec picked `[-4, +4]`, its PLY
importer and its glTF bridge shared the constant, and the specification said nothing. That is the
shape of defect worth naming: not a disagreement between implementations, but an interval that
existed in code and not in the document, so that a second implementation could pick a different one,
be conforming by the text, and produce scenes whose higher bands drift in colour on every conversion
with nothing to point at. Stating it costs nothing, because it is what the bytes already meant.

The **bit depth** row adds a field, and adds it where a frozen record can take one: appended, after
the bounds map, absent entirely on a file that declares nothing. All 44 conformance variants that
predate it are byte-identical, none was regenerated, and the five variants that use it are new
files. It is also, deliberately, not a second scheme — eight bits is the identity, so a file that
declares no depths is a file at eight bits, and one rule covers both. What it does not do is change
what a decoder must implement: the byte in a band stream is the quantized coefficient either way,
and a decoder that ignores the whole declaration decodes every such file correctly. That is the
property being paid for by not packing sub-byte values.

The §4.5 row is a tightening of what a **writer** may emit, not a migration. It changes no existing
file: all 34 conformance variants already satisfy it, none was regenerated, and no file's bytes or
meaning move. What it forbids is a shape the layout diagram used to permit — an Attachment record
sitting between the Statistics and Summary Offset records — which no encoder ever produced and which
would have made a streamed checksum cost whatever the attachment weighed.

The §5.5/§5.6 row is the `aabb` row's sibling, and it was found the same way: by writing a Kaitai
grammar from the published document and discovering it could not parse a file. §5.5 called a chunk's
payload "concatenated Attribute Stream records" and §5.6 was headed with an opcode, so a reader
built from the text alone looked for §4.2 framing — an opcode byte and a `content_length` — where
the wire has an `attribute_id` and a `symbol_width`. It then desynchronized on the first stream and
every byte after it. The wire is the format and the text was the bug: `0x06` appears **zero** times
as a top-level opcode across all 34 conformance variants, while `0x07`, which really is a record,
appears 158 times. No file changes; what changes is that a parser written from this document now
works.

The `aabb` row is the one worth reading twice. The text said `f32[6]` from the first draft and every
implementation wrote `f64[6]`, so a reader built from the specification alone desynchronized on the
Header and on every record after it. It was found by writing a new implementation from the published
documents and nothing else, which is the only way that class of error is ever found.
