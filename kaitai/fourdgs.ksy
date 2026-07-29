# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0
#
# A machine-readable restatement of the 4dgs container's structure. See kaitai/README.md
# for what this grammar is and, more importantly, what it deliberately is not.
meta:
  id: fourdgs
  title: 4dgs — 4D gaussian splat scene container, version 1
  file-extension: 4dgs
  license: Apache-2.0
  endian: le
  encoding: UTF-8

doc: |
  A `.4dgs` file is a magic, a sequence of length-prefixed records, and the magic again.
  Everything structural follows from that: a reader that cannot interpret a record still
  knows exactly how long it is, so this grammar interprets the records it knows and leaves
  the rest as bytes — which is the same contract §4.2 puts on readers.

  Normative source: website/docs/spec/index.md, with the registry at
  website/docs/spec/registry.md. Where this file and the specification disagree, the
  specification wins and this file is the bug.

seq:
  - id: magic
    contents: [0x89, 0x34, 0x44, 0x47, 0x53, 0x31, 0x0d, 0x0a]
    doc: |
      Spec §4.1. `0x89` keeps byte-oriented tooling from treating the file as text, `4DGS`
      identifies it, `1` is the major version, CR LF catches transports that mangle line
      endings. A reader that does not implement the version byte must refuse the file.
  - id: records
    type: record
    repeat: until
    repeat-until: _.opcode == opcode::footer
    doc: |
      The Footer is the last record (§4), so it terminates the run and what follows is the
      trailing magic rather than another record. Reading to end-of-stream instead would
      consume those eight bytes as a malformed record.
  - id: trailing_magic
    contents: [0x89, 0x34, 0x44, 0x47, 0x53, 0x31, 0x0d, 0x0a]
    doc: |
      The magic appears at both ends so a reader holding only the tail of a file can still
      identify it and locate the Footer (§4).

enums:
  # §4.3. 0x01–0x7F is specification territory; 0x80–0xFF belongs to applications and is
  # never defined here. Values absent from this enum are not errors — they are the point.
  opcode:
    0x01: header
    0x02: footer
    0x03: quantization
    0x04: window_table
    0x05: chunk
    0x06: attribute_stream
    0x07: sh_band_stream
    0x08: chunk_index
    0x09: audio
    0x0a: camera
    0x0b: metadata
    0x0c: statistics
    0x0d: attachment
    0x0e: attachment_index
    0x0f: summary_offset
    # §5.15, the provenance family. 0x24–0x2F stay reserved and unemitted, so they are
    # absent here for the same reason every other unassigned opcode is.
    0x20: coordinate_frame
    0x21: sensor_calibration
    0x22: rig_trajectory
    0x23: geodetic_anchor

  # §5.6 `mode`.
  stream_mode:
    0: raw
    1: delta
    2: constant

  # Registry, "Stream codecs". Values 2–127 are reserved and 128–255 private, so an
  # unlisted value here is a legal file this grammar has no name for.
  stream_codec:
    0: deflate
    1: zstd

types:
  # ---------------------------------------------------------------- primitives (§2)

  str_field:
    doc: |
      `string`: a u4 byte length followed by that many UTF-8 bytes, not NUL-terminated.
    seq:
      - id: len_value
        type: u4
      - id: value
        type: str
        size: len_value

  blob:
    doc: '`bytes`: a u8 byte length followed by that many bytes.'
    seq:
      - id: len_data
        type: u8
      - id: data
        size: len_data

  str_map:
    doc: |
      `map<string, string>`: a u4 byte length of the whole block, then repeated
      string-key / string-value pairs filling exactly that block. The count is implied by
      the block length, not stored, so the pairs are read to the end of the substream.
    seq:
      - id: len_entries
        type: u4
      - id: entries
        type: str_map_block
        size: len_entries

  str_map_block:
    seq:
      - id: entries
        type: str_map_entry
        repeat: eos

  str_map_entry:
    seq:
      - id: key
        type: str_field
      - id: value
        type: str_field

  # ---------------------------------------------------------------- framing (§4.2)

  record:
    doc: |
      Every top-level structure is `u1 opcode`, `u8 content_length`, then that many bytes.

      Two consequences are load-bearing and both are expressed by giving `content` a fixed
      `size` and switching on the opcode only to choose how to read within it:

      * An opcode this grammar does not know — a private-range record, or a spec-range one
        added by a later minor revision — falls through the switch and is left as bytes.
        It is skipped by length, exactly as §4.2 requires of a reader, so a valid future
        file parses rather than failing.
      * A record that has grown appended fields (§4.2) parses too: the known fields are
        read from the front of the substream and the appended remainder is simply not
        consumed. Nothing here asserts that a record ends where its known fields end.
    seq:
      - id: opcode
        type: u1
        enum: opcode
      - id: len_content
        type: u8
      - id: content
        size: len_content
        type:
          switch-on: opcode
          cases:
            'opcode::header': header
            'opcode::footer': footer
            'opcode::quantization': quantization
            'opcode::window_table': window_table
            'opcode::chunk': chunk
            'opcode::sh_band_stream': sh_band_stream
            'opcode::chunk_index': chunk_index
            'opcode::audio': audio
            'opcode::camera': camera
            'opcode::metadata': metadata
            'opcode::statistics': statistics
            'opcode::attachment': attachment
            'opcode::summary_offset': summary_offset
            'opcode::coordinate_frame': coordinate_frame
            'opcode::sensor_calibration': sensor_calibration
            'opcode::rig_trajectory': rig_trajectory
            'opcode::geodetic_anchor': geodetic_anchor
            # Deliberately absent:
            #   opcode::attribute_stream (0x06) — never framed as a top-level record; see
            #     the `chunk` type.
            #   opcode::attachment_index (0x0E) — §5.13 gives 0x0D and 0x0E a single body,
            #     which cannot be right for an index, and no writer emits it. Left as
            #     bytes rather than guessed at.

  # ---------------------------------------------------------------- records (§5)

  header:
    doc: Spec §5.1. Opcode 0x01, frozen (§4.4). Must be the file's first record.
    seq:
      - id: profile
        type: str_field
        doc: Well-known profile name, or "". See the registry.
      - id: library
        type: str_field
        doc: Free-form producer identification.
      - id: duration_sec
        type: f8
        doc: Scene length; playback covers [0, duration_sec).
      - id: gaussian_count
        type: u8
      - id: cutoff
        type: f8
        doc: |
          Marginal visibility threshold, default 0.05. Also feeds the per-gaussian velocity
          step of §6.3 — this file's value, never the default.
      - id: temporal_model
        type: str_field
      - id: aabb
        type: f8
        repeat: expr
        repeat-expr: 6
        doc: |
          min xyz then max xyz over all rest positions. f8, not f4: the specification said
          `f32[6]` until the §12 changelog corrected it to match every file ever written.
      - id: sh_degree
        type: u1
      - id: flags
        type: u1
      - id: attributes
        type: str_map
        doc: Free-form; see the registry for well-known keys.
    instances:
      has_audio:
        value: (flags & 0x01) != 0
        doc: |
          Bit 0, the audio discovery rule (§7): a reader answers "does this scene have
          audio?" from the Header alone, with no further reads.
      chunks_compressed:
        value: (flags & 0x02) != 0

  footer:
    doc: |
      Spec §5.2. Opcode 0x02, frozen. Must be the file's last record; a reader seeking a
      random instant reads the last 8 + 1 + 8 + 20 bytes and starts from `summary_start`.
    seq:
      - id: summary_start
        type: u8
        doc: |
          Byte offset of the first Chunk Index record, or 0 — which means the file has no
          index and must be read sequentially.
      - id: summary_offset_start
        type: u8
      - id: summary_crc
        type: u4
        doc: CRC-32 (IEEE) over [summary_start, footer_start), or 0.

  quantization:
    doc: Spec §5.3. Opcode 0x03, frozen.
    seq:
      - id: scheme
        type: str_field
      - id: pos_origin
        type: f8
        repeat: expr
        repeat-expr: 3
      - id: step_pos
        type: f8
      - id: step_scale_log
        type: f8
      - id: step_rot
        type: f8
      - id: step_rgb
        type: f8
      - id: step_alpha
        type: f8
      - id: step_motion
        type: f8
      - id: step_time
        type: f8
      - id: step_sigma_log
        type: f8
      - id: step_sh
        type: u1
        doc: |
          An encode-side value (§6.5): it records the pitch an encoder used before storing
          the coefficients and is *not* applied at decode.
      - id: bounds
        type: str_map
        doc: |
          Declared max deviation per attribute, as decimal strings. Keys are `pos`,
          `scale_rel`, `rot`, `rgb`, `alpha`, `motion`, `time`, `sigma_rel`, `sh`.

  window_table:
    doc: |
      Spec §5.4. Opcode 0x04, frozen. Gaussians reference windows by index, so the
      per-gaussian cost is an index rather than a pair of floats. An absent record or a
      zero count reads as exactly one window (0, 0).
    seq:
      - id: num_windows
        type: u4
      - id: windows
        type: window
        repeat: expr
        repeat-expr: num_windows

  window:
    seq:
      - id: lo
        type: f8
      - id: hi
        type: f8

  chunk:
    doc: |
      Spec §5.5. Opcode 0x05, frozen. One temporal interval's gaussians, independently
      decodable: nothing in a chunk references another chunk.
    seq:
      - id: t0
        type: f8
      - id: t1
        type: f8
      - id: level
        type: u4
        doc: Producer's hierarchy level; informational only.
      - id: count
        type: u4
      - id: compression
        type: str_field
        doc: |
          Codec applied to the whole `records` block, or "" for stored-as-is. A reader
          must honour it: ignoring it decodes compressed bytes as attribute streams, which
          produces wrong gaussians rather than an error.
      - id: uncompressed_size
        type: u8
      - id: len_records
        type: u8
      - id: records
        size: len_records
        type:
          switch-on: compression.value
          cases:
            '""': attribute_stream_block
        doc: |
          Attribute streams, structure-of-arrays, one per attribute. When `compression`
          names a codec the block is compressed and this grammar leaves it as bytes —
          decompression is out of scope here, and guessing at the plaintext would be worse
          than declining.

  attribute_stream_block:
    doc: |
      The streams inside a chunk are **not** framed as records. §5.5 calls the block
      "concatenated Attribute Stream records" and §5.6 gives Attribute Stream an opcode of
      0x06, but what is on the wire is a bare run of the §5.6 field layout with no opcode
      byte and no u8 content length in front of it — the first byte of each stream is its
      `attribute_id`. Opcode 0x06 is never seen at the top level of a file.
    seq:
      - id: streams
        type: attribute_stream
        repeat: eos

  attribute_stream:
    doc: |
      Spec §5.6. Frozen. Payload decoding, in order: decompress with `codec`; if
      `symbol_width > 1`, reverse the byte-plane shuffle; zigzag-decode each symbol; then
      apply `mode`. All of that is semantics, so this grammar stops at `payload`.
    seq:
      - id: attribute_id
        type: u1
        doc: |
          See the registry's attribute ids. Deliberately not typed as an enum: inside an
          SH Band Stream record this field carries 0x07, the record's own opcode, which
          collides with `mu_t`'s id of 7 (§5.7). Naming the value here would assert the
          dispatch the specification forbids.
      - id: symbol_width
        type: u1
        doc: 1, 2 or 4 bytes.
      - id: mode
        type: u1
        enum: stream_mode
      - id: codec
        type: u1
        enum: stream_codec
      - id: channels
        type: u1
        doc: Interleaving width.
      - id: element_count
        type: u4
      - id: len_payload
        type: u8
      - id: payload
        size: len_payload

  sh_band_stream:
    doc: |
      Spec §5.7. Opcode 0x07: an attribute stream prefixed with its band number. Each band
      is its own record with its own byte range in the Chunk Index, so a reader that has
      capped its SH degree never transfers the bands it will not use.
    seq:
      - id: band
        type: u1
        doc: 1–3. Bands are taken whole; a reader must not assemble a partial degree.
      - id: stream
        type: attribute_stream

  chunk_index:
    doc: |
      Spec §5.8. Opcode 0x08, frozen. Every offset/length pair here frames a **whole
      record**, opcode byte and content length included — there is no range in this record
      that points at a record's content rather than at the record.
    seq:
      - id: t0
        type: f8
      - id: t1
        type: f8
      - id: chunk_offset
        type: u8
      - id: chunk_length
        type: u8
      - id: gaussian_count
        type: u4
      - id: num_bands
        type: u4
      - id: bands
        type: band_range
        repeat: expr
        repeat-expr: num_bands

  band_range:
    seq:
      - id: band
        type: u1
      - id: offset
        type: u8
      - id: length
        type: u8

  audio:
    doc: |
      Spec §5.9 and §7. Opcode 0x09, present only when the scene has audio — a scene
      without it carries no record, no placeholder and no reserved bytes.
    seq:
      - id: codec
        type: str_field
        doc: Well-known audio codec name; see the registry.
      - id: start_sec
        type: f8
        doc: |
          Scene time at which the track's first sample plays. When audio is present the
          scene clock is the audio clock: scene time t is audio time t - start_sec.
      - id: data
        type: blob
        doc: The encoded track, verbatim. Opaque here by construction.

  camera:
    doc: |
      Spec §5.10. Opcode 0x0A. A default viewpoint and optional suggested path, purely
      advisory: a reader may ignore it entirely.
    seq:
      - id: fov_y_deg
        type: f8
      - id: position
        type: f8
        repeat: expr
        repeat-expr: 3
      - id: target
        type: f8
        repeat: expr
        repeat-expr: 3
      - id: num_keyframes
        type: u4
      - id: keyframes
        type: camera_keyframe
        repeat: expr
        repeat-expr: num_keyframes
      - id: interpolation
        type: str_field
      - id: loop_playback
        type: u1
        doc: 0 or 1. Named around `loop`, which is a reserved word in several targets.

  camera_keyframe:
    seq:
      - id: time
        type: f8
      - id: position
        type: f8
        repeat: expr
        repeat-expr: 3
      - id: target
        type: f8
        repeat: expr
        repeat-expr: 3

  coordinate_frame:
    doc: |
      Spec §5.15.2. Opcode 0x20. The frame the file's own coordinates are expressed in.

      A fixed shape: every field is always present, so a reader that knows these six knows
      exactly where an appended seventh would begin. The georeference is `geodetic_anchor`
      (0x23) rather than an optional tail here, because a conditional block inside a record
      makes the offset of everything after it depend on a value.
    seq:
      - id: name
        type: str_field
        doc: Frame identifier. Empty is the file's own scene frame.
      - id: handedness
        type: u1
      - id: up_axis
        type: u1
      - id: forward_axis
        type: u1
        doc: |
          Signed axis, 0..5 for +x +y +z -x -y -z. Must name a different axis from
          `up_axis` ignoring sign; a reader refuses a file where it does not.
      - id: length_unit
        type: u1
      - id: metres_per_unit
        type: f8
        doc: |
          Length of one file unit in metres; 0.0 means unknown. Must agree with
          `length_unit`, and is the authority for a consumer handed a file where it does
          not.

  geodetic_anchor:
    doc: |
      Spec §5.15.5. Opcode 0x23. Where a frame's origin sits on the WGS-84 ellipsoid.

      Its own record rather than a tail on `coordinate_frame`, so a scene with no
      georeference carries no anchor at all.
    seq:
      - id: frame_name
        type: str_field
        doc: The `coordinate_frame` this anchors. Empty is the scene frame.
      - id: latitude_deg
        type: f8
      - id: longitude_deg
        type: f8
      - id: altitude_m
        type: f8
      - id: heading_deg
        type: f8
        doc: Bearing of the frame's forward axis, degrees clockwise from true north.

  sensor_calibration:
    doc: |
      Spec §5.15.3. Opcode 0x21, one record per sensor.

      The extrinsic maps sensor coordinates into the frame `pose_reference` names, in that
      direction: `p_target = R(rotation) * p_sensor + translation`.
    seq:
      - id: name
        type: str_field
        doc: Unique within the file; a reader refuses two records sharing a name.
      - id: modality
        type: str_field
      - id: camera_model
        type: u1
        doc: 0 when the sensor is not a camera, in which case every intrinsic below is 0.
      - id: width_px
        type: u4
      - id: height_px
        type: u4
      - id: fx
        type: f8
      - id: fy
        type: f8
      - id: cx
        type: f8
      - id: cy
        type: f8
      - id: num_distortion
        type: u1
      - id: distortion
        type: f8
        repeat: expr
        repeat-expr: num_distortion
        doc: In the order the named `camera_model` defines. See the registry.
      - id: rotation
        type: f8
        repeat: expr
        repeat-expr: 4
        doc: Unit quaternion, xyzw — the same order and convention as §3 and §6.4.
      - id: translation
        type: f8
        repeat: expr
        repeat-expr: 3
      - id: pose_reference
        type: u1
        doc: |
          0: the pose maps sensor to the scene frame. 1: it maps sensor to a rig frame and
          composes with the `rig_trajectory` named below.
      - id: rig_name
        type: str_field

  rig_trajectory:
    doc: |
      Spec §5.15.4. Opcode 0x22. The measured pose of the capture platform over the scene
      clock — a measurement, not the advisory viewing path of §5.10.
    seq:
      - id: name
        type: str_field
        doc: Empty is the file's capture rig.
      - id: interpolation
        type: u1
        doc: 0 linear (lerp plus shortest-arc slerp), 1 step.
      - id: num_samples
        type: u4
      - id: samples
        type: rig_sample
        repeat: expr
        repeat-expr: num_samples

  rig_sample:
    seq:
      - id: time
        type: f8
        doc: |
          Seconds on the scene clock. Strictly increasing across a trajectory; a reader
          refuses one where it is not, because every interpolation rule is stated in terms
          of the interval a query lands in.
      - id: rotation
        type: f8
        repeat: expr
        repeat-expr: 4
      - id: translation
        type: f8
        repeat: expr
        repeat-expr: 3

  metadata:
    doc: Spec §5.11. Opcode 0x0B.
    seq:
      - id: name
        type: str_field
      - id: entries
        type: str_map

  statistics:
    doc: |
      Spec §5.12. Opcode 0x0C. A summary a reader can trust without scanning chunks, but
      advisory: a reader that needs certainty computes from the chunks.
    seq:
      - id: gaussian_count
        type: u8
      - id: chunk_count
        type: u4
      - id: duration_sec
        type: f8
      - id: aabb
        type: f8
        repeat: expr
        repeat-expr: 6

  attachment:
    doc: |
      Spec §5.13. Opcode 0x0D. Arbitrary payloads — thumbnails, provenance, licences.
      Not the mechanism for audio, and not a summary record (§4.5).
    seq:
      - id: name
        type: str_field
      - id: media_type
        type: str_field
      - id: data
        type: blob

  summary_offset:
    doc: |
      Spec §5.14. Opcode 0x0F. Lets a reader range-read one class of index record without
      reading the others.
    seq:
      - id: group_opcode
        type: u1
        enum: opcode
      - id: group_start
        type: u8
      - id: group_length
        type: u8
