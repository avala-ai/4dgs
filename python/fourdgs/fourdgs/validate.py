# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Structural validation.

This is what makes a third-party encoder possible: a way to find out *why* a file is
wrong that does not involve reading someone else's decoder. Every finding names the
record, the field and what was expected.

Two things beyond the framing walk, because a validator that only walks the framing
answers a narrower question than the one its holder asked:

* **It decodes the chunks.** Walking the framing steps *over* a chunk by its declared
  length, which is exactly not looking inside it — so an unimplemented stream codec and an
  out-of-range window index were both invisible here, and both are in the invalid corpus.
  One chunk is resident at a time (AGENTS.md §1), so validating a file larger than memory
  still works.
* **It knows `keyframe-delta`.** Every structural check below assumed the gaussian-birth
  chunk shape, so a conforming keyframe-delta file came back with seven errors. The
  Header's declared model now selects the reader, because refusing a file for declaring a
  model this library implements was never a statement about the file.

Findings that came from a refusal carry the refusal's identifier and the byte it fired at;
see `refusal`. The finding line itself is unchanged, so it still reads word for word as
the Rust validator's, which is what lets the two tools be diffed.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

from . import opcode as op
from . import records as rec
from . import refusal
from .exceptions import FourdgsError
from .object_layer import ObjectLayer
from .provenance import LENGTH_UNIT_METRES, Provenance
from .quantization import sh_bound, sh_step
from .readable import BytesReadable
from .refusal import Named, Site, Walk
from .serialization import MAGIC, crc32, iter_records


@dataclass
class Finding:
    severity: str  # "error" | "warning" | "note"
    message: str
    #: The refusal identifier and the byte it fired at, for the findings that have one.
    #: Most do not: "Header declares 640 gaussians; chunks contain 256" is a rule this
    #: validator checks itself, not a refusal a reader raised, and the refusal table does
    #: not name it.
    refusal: Named | None = None

    def __str__(self) -> str:
        return f"{self.severity}: {self.message}"


@dataclass
class Report:
    findings: list[Finding] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not any(f.severity == "error" for f in self.findings)

    def error(self, msg: str) -> None:
        self.findings.append(Finding("error", msg))

    def warn(self, msg: str) -> None:
        self.findings.append(Finding("warning", msg))

    def note(self, msg: str) -> None:
        self.findings.append(Finding("note", msg))

    def refused(
        self,
        prefix: str,
        exc: FourdgsError,
        where: Walk | None = None,
        site: Site | None = None,
    ) -> None:
        """An error a reader raised, carrying its identifier and the byte if it has one.

        `prefix` is what the message is introduced with, so the sentence stays the one the
        other validators print; the identifier arrives separately and changes nothing
        about it.
        """
        self.findings.append(Finding("error", f"{prefix}{exc}", refusal.describe(exc, where, site)))


def _check_quantization_finite(quant: rec.Quantization, report: Report, ordinal: int = 0) -> None:
    """Every step and origin must be finite (spec §5.3).

    A non-finite step is the one corrupt field that ruins every gaussian rather than one:
    each bin multiplied by it decodes to infinity or NaN, so the whole scene comes out with
    no position to occupy. Nothing downstream complains — dequantization is arithmetic and
    arithmetic on infinity is defined — so without this check the first symptom is a
    renderer drawing an empty frame, which points at the renderer.

    Reported per field, because "the file is broken" is what the caller already knows.

    Called once per Quantization record as it is walked, not once on whichever record
    happened to survive. A file may carry more than one — nothing in the framing prevents
    it — and a validator that only inspected the last would pass a file whose first grid is
    non-finite while a streamed decoder, which takes the first it meets, decodes the whole
    scene through it. `ordinal` names the record when there is more than one, so the report
    points at the offending copy rather than at "the" Quantization record.
    """
    where = "Quantization" if ordinal == 0 else f"Quantization record {ordinal + 1}"
    for name, value in (
        ("pos_origin[0]", quant.pos_origin[0]),
        ("pos_origin[1]", quant.pos_origin[1]),
        ("pos_origin[2]", quant.pos_origin[2]),
        ("step_pos", quant.step_pos),
        ("step_scale_log", quant.step_scale_log),
        ("step_rot", quant.step_rot),
        ("step_rgb", quant.step_rgb),
        ("step_alpha", quant.step_alpha),
        ("step_motion", quant.step_motion),
        ("step_time", quant.step_time),
        ("step_sigma_log", quant.step_sigma_log),
    ):
        if not math.isfinite(value):
            report.error(f"{where} {name} is {value}; every step and origin must be finite (§5.3)")


def _check_provenance(prov: Provenance, report: Report) -> None:
    """Findings a parse deliberately does not raise on.

    The reader refuses what is structurally impossible and surfaces everything else
    raw, because "from a newer registry" and "malformed" call for different reactions
    from a caller. A validator is the tool whose job is to name the difference, so the
    unrecognized values and the writer-side inconsistencies are reported here — as
    warnings and notes, not errors, since a file carrying them still decodes.
    """
    for frame in prov.frames:
        where = f"CoordinateFrame {frame.name!r}"
        if frame.handedness not in (0, 1, 2):
            report.warn(f"{where} handedness {frame.handedness} is not in the registry")
        if frame.length_unit not in LENGTH_UNIT_METRES and frame.length_unit != 0:
            report.warn(f"{where} length_unit {frame.length_unit} is not in the registry")
        declared = LENGTH_UNIT_METRES.get(frame.length_unit)
        if declared is not None and frame.metres_per_unit > 0.0:
            # An error, not a warning. A writer MUST make the two agree, so a file where
            # they differ is non-conforming — and reporting it as a warning would bless
            # the shape. That a consumer still has a defined answer (the number wins) is a
            # rule about the file it was handed, not a licence to write one.
            if abs(frame.metres_per_unit - declared) > 1e-12 * max(declared, 1.0):
                report.error(
                    f"{where} declares length_unit {frame.length_unit} ({declared} m per unit) and "
                    f"metres_per_unit {frame.metres_per_unit}; a writer must make them agree. A "
                    f"consumer handed this file takes metres_per_unit (section 5.15.2)"
                )
        if frame.handedness == 0:
            report.note(f"{where} does not state a handedness, so a consumer cannot mirror-correct it")

    for anchor in prov.anchors:
        # The ranges themselves are refused at parse; what is left for a validator is the
        # anchor that is legal and useless.
        if anchor.latitude_deg == 0.0 and anchor.longitude_deg == 0.0:
            report.warn(
                f"a GeodeticAnchor for frame {anchor.frame_name!r} sits at exactly (0, 0), which is "
                f"far more often an unset field than a location in the Gulf of Guinea"
            )
        frame = prov.frame_named(anchor.frame_name)
        if frame is not None and frame.forward_axis == frame.up_axis:
            report.error(
                f"a GeodeticAnchor anchors frame {anchor.frame_name!r}, whose forward axis its "
                f"heading is measured against is degenerate"
            )

    for sensor in prov.sensors:
        if sensor.camera_model not in rec.CAMERA_MODEL_COEFFICIENTS:
            report.warn(
                f"sensor {sensor.name!r} names camera model {sensor.camera_model}, which is not in "
                f"the registry; a reader that cannot project with it must decline rather than "
                f"apply part of it (section 5.15.3)"
            )
        if sensor.is_camera and not (0.0 <= sensor.cx <= sensor.width_px and 0.0 <= sensor.cy <= sensor.height_px):
            report.warn(
                f"sensor {sensor.name!r} has a principal point ({sensor.cx}, {sensor.cy}) outside its "
                f"{sensor.width_px}x{sensor.height_px} image"
            )

    for trajectory in prov.trajectories:
        if trajectory.sample_count == 0:
            report.warn(
                f"trajectory {trajectory.name!r} carries no samples; it is read as though absent "
                f"and should have been omitted (section 5.15.4)"
            )
        if trajectory.interpolation not in (0, 1):
            report.warn(
                f"trajectory {trajectory.name!r} names interpolation {trajectory.interpolation}, "
                f"which is not in the registry"
            )

    if not prov.frames and (prov.sensors or prov.trajectories):
        report.note(
            "the file carries sensor or rig provenance but no CoordinateFrame record, so the frame "
            "those poses are expressed in is whatever the consumer assumes"
        )


def _check_sh_bit_depths(quant: rec.Quantization, sh_degree: int, report: Report) -> None:
    """The per-band SH bit depths, against the degree the Header declares (spec §6.5).

    Only checked when the file actually carries bands. Appended fields are positional, so
    a record that ends in bytes some other writer appended can parse as a depth list by
    coincidence; on a file with no coefficients that is a false alarm waiting to happen,
    and there is nothing for the declaration to be wrong about.
    """
    if not quant.sh_bit_depths or sh_degree <= 0:
        return
    if len(quant.sh_bit_depths) != sh_degree:
        report.error(
            f"Quantization declares {len(quant.sh_bit_depths)} SH bit depths; "
            f"the Header declares degree {sh_degree}, and there is one band per degree (§6.5)"
        )
    for i, bits in enumerate(quant.sh_bit_depths[:sh_degree], start=1):
        key = f"sh_band{i}"
        declared = quant.bounds.get(key)
        expected = str(sh_bound(bits))
        if declared is None:
            report.warn(f"Quantization declares {bits} bits for SH band {i} but no `{key}` bound (§5.3)")
        elif declared != expected:
            report.warn(f"Quantization declares `{key}` as {declared}; {bits} bits gives a bound of {expected} (§6.5)")
    coarsest = max(sh_step(b) for b in quant.sh_bit_depths[:sh_degree])
    if quant.step_sh != coarsest:
        report.warn(
            f"Quantization step_sh is {quant.step_sh}; the coarsest declared band has a pitch of {coarsest}, "
            "which is what a consumer that reads only step_sh has to be given (§6.5)"
        )


def validate(data: bytes) -> Report:
    report = Report()
    # Framing first, and for two reasons: it refuses a file that is not ours before
    # anything reads a byte as an opcode, and it is what gives every later refusal a byte
    # to point at.
    try:
        walk = refusal.walk(data, retain_records=False)
    except FourdgsError as exc:
        report.refused("", exc)
        return report

    if not data.endswith(MAGIC):
        report.error("file does not end with the magic; it is truncated or was written by a broken encoder")

    seen: set[int] = set()
    first_opcode: int | None = None
    header = None
    quant = None
    quant_count = 0
    chunk_count = 0
    counted = 0
    index: list[rec.ChunkIndexEntry] = []
    index_record_offsets: list[int] = []
    #: Where every Chunk and Delta Chunk record sits, in file order — what the index is
    #: checked against, and what says a Delta Chunk turned up in a file that declares a
    #: model with no such record.
    first_delta_offset: int | None = None
    footer = None
    footer_offset: int | None = None
    provenance = Provenance()
    objects = ObjectLayer()
    audio_sources: dict[int, rec.AudioSource] = {}
    audio_data: dict[int, int] = {}
    first_chunk_seen = False

    try:
        for record in iter_records(data, len(MAGIC)):
            if first_opcode is None:
                first_opcode = record.opcode
            seen.add(record.opcode)
            if record.opcode == op.HEADER:
                header = rec.Header.parse(record.content)
            elif record.opcode == op.QUANTIZATION:
                quant = rec.Quantization.parse(record.content)
                # Checked here, as the record is met, rather than once at the end on
                # whichever copy survived the loop. See `_check_quantization_finite`.
                _check_quantization_finite(quant, report, quant_count)
                _check_sh_bit_depths(quant, header.sh_degree if header is not None else 0, report)
                quant_count += 1
            elif record.opcode == op.CHUNK:
                first_chunk_seen = True
                head, _ = rec.parse_chunk(record.content)
                chunk_count += 1
                counted += head.count
                if head.t1 < head.t0:
                    report.error(f"chunk {chunk_count} has t1 ({head.t1}) before t0 ({head.t0})")
            elif record.opcode == op.DELTA_CHUNK:
                first_chunk_seen = True
                if first_delta_offset is None:
                    first_delta_offset = record.offset
            elif record.opcode == op.CHUNK_INDEX:
                index.append(rec.ChunkIndexEntry.parse(record.content))
                index_record_offsets.append(record.offset)
            elif record.opcode == op.AUDIO_SOURCE:
                source = rec.AudioSource.parse(record.content)
                if first_chunk_seen:
                    report.error(f"Audio Source id {source.source_id} appears after the first Chunk")
                if source.source_id in audio_sources:
                    report.error(f"Audio Source id {source.source_id} appears more than once")
                audio_sources[source.source_id] = source
                if not source.codec:
                    report.error(f"Audio Source id {source.source_id} has an empty codec")
                if not all(
                    math.isfinite(v)
                    for v in (
                        source.start_sec,
                        source.duration_sec,
                        source.gain,
                        *source.position,
                        *source.rotation,
                    )
                ):
                    report.error(f"Audio Source id {source.source_id} has a non-finite numeric field")
                if not any(source.rotation):
                    report.error(f"Audio Source id {source.source_id} has a zero rotation quaternion")
                if source.duration_sec <= 0:
                    report.error(f"Audio Source id {source.source_id} duration_sec must be positive")
                if source.gain < 0:
                    report.error(f"Audio Source id {source.source_id} gain must be non-negative")
                if source.spatial and source.channel_layout != "mono":
                    report.error(f"spatial Audio Source id {source.source_id} must use channel_layout 'mono'")
                if source.flags & ~(rec.AUDIO_SOURCE_SPATIAL | rec.AUDIO_SOURCE_LOOP):
                    report.error(f"Audio Source id {source.source_id} has reserved flag bits set")
                if source.interpolation not in {"linear", "step"}:
                    report.error(
                        f"Audio Source id {source.source_id} uses unknown interpolation {source.interpolation!r}"
                    )
                last = -math.inf
                for i, keyframe in enumerate(source.keyframes):
                    finite_pose = all(math.isfinite(v) for v in (*keyframe.position, *keyframe.rotation))
                    if not math.isfinite(keyframe.time) or keyframe.time <= last or not finite_pose:
                        report.error(
                            f"Audio Source id {source.source_id} keyframe {i} must have a finite, "
                            "strictly increasing time and finite pose"
                        )
                    if not any(keyframe.rotation):
                        report.error(f"Audio Source id {source.source_id} keyframe {i} has a zero rotation quaternion")
                    last = keyframe.time
            elif record.opcode == op.AUDIO_DATA:
                payload = rec.AudioData.parse(record.content)
                if first_chunk_seen:
                    report.error(f"Audio Data id {payload.source_id} appears after the first Chunk")
                if payload.source_id in audio_data:
                    report.error(f"Audio Data id {payload.source_id} appears more than once")
                audio_data[payload.source_id] = len(payload.data)
            elif record.opcode == op.FOOTER:
                footer = rec.Footer.parse(record.content)
                footer_offset = record.offset
            elif record.opcode == op.COORDINATE_FRAME:
                provenance.frames.append(rec.CoordinateFrame.parse(record.content))
            elif record.opcode == op.SENSOR_CALIBRATION:
                provenance.sensors.append(rec.SensorCalibration.parse(record.content))
            elif record.opcode == op.RIG_TRAJECTORY:
                provenance.trajectories.append(rec.RigTrajectory.parse(record.content))
            elif record.opcode == op.GEODETIC_ANCHOR:
                provenance.anchors.append(rec.GeodeticAnchor.parse(record.content))
            elif record.opcode == op.OBJECT_TABLE:
                if objects.table is not None:
                    report.error(
                        f"a second ObjectTable record appears at byte {record.offset}; "
                        "a file may carry exactly one scene-wide object table"
                    )
                else:
                    objects.table = rec.ObjectTable.parse(record.content)
            elif record.opcode == op.OBJECT_TRACK:
                objects.tracks.append(rec.ObjectTrack.parse(record.content))
            elif op.is_provenance(record.opcode):
                # The reserved tail of the family, and only the tail: every branch above
                # parses one of `0x20`-`0x25`, so a capture carrying frames, sensors, a rig
                # and a georeference collects no notes here. The range named is the one
                # that is actually still reserved — `0x24` and `0x25` were assigned to the
                # object layer, and a note calling them reserved tells its reader that two
                # records this library parses were skipped.
                report.note(
                    f"reserved provenance record 0x{record.opcode:02X} — skipped, as required "
                    f"(0x26-0x2F, section 5.15.6)"
                )
            elif op.is_private(record.opcode):
                report.note(
                    f"private record 0x{record.opcode:02X} ({len(record.content)} bytes) — skipped, as required"
                )
            elif record.opcode not in op.NAMES:
                report.note(f"unknown record 0x{record.opcode:02X} — skipped, as required")
    except FourdgsError as exc:
        report.error(f"stopped reading: {exc}")

    if not seen:
        report.error("no records at all")
        return report
    if first_opcode != op.HEADER:
        report.error(f"first record is {op.name(first_opcode)}; the Header must come first")
    if header is None:
        report.error("no Header record")
    if quant is None:
        report.error("no Quantization record")
    if footer is None:
        report.error("no Footer record")

    # Select exactly the index records in the Footer-selected summary. Summary records
    # are contiguous but not grouped by opcode: Statistics and Summary Offset records may
    # sit between Chunk Index records, and the indexed reader walks the whole selected
    # range. Keep this pass lazy just like the framing walk; retaining a Frame per record
    # would let a hostile run of tiny records turn bounded framing into unbounded memory.
    # Only meaningful when the Footer actually named a summary. A file with no Footer, or
    # one whose `summary_start` is 0 -- the indexless file of §5.2 -- selects nothing, and
    # reading that as "nothing is selected" is wrong twice over: it buries the real fault
    # under one line per Chunk Index record, thousands of them on a real capture, and it
    # empties `index` so every per-entry check below silently stops running on records that
    # are still sitting there to be checked. The absent Footer is already reported above.
    footer_selects_summary = False
    selected_index_offsets: set[int] = set()
    if footer is not None and footer_offset is not None and footer.summary_start:
        footer_selects_summary = True
        selected_start_seen = False
        for frame in walk.intact_records():
            if frame.offset < footer.summary_start:
                continue
            if frame.offset >= footer_offset:
                break
            if not selected_start_seen:
                if frame.offset != footer.summary_start:
                    break
                selected_start_seen = True
            if frame.opcode == op.CHUNK_INDEX:
                selected_index_offsets.add(frame.offset)
        if not selected_start_seen:
            report.error(
                f"the Footer's summary_start {footer.summary_start} does not name a complete summary record "
                f"before the Footer at byte {footer_offset}"
            )
    # A Chunk Index record outside the range the Footer named — or present at all in a file
    # whose Footer names no summary — is orphaned: nothing reaches it by seeking, and saying
    # so is the point. A file with no Footer at all is the different case: there is no
    # declaration for anything to be outside of, the real fault is the missing Footer and it
    # is reported above, and adding a line per index record buries it.
    if footer is not None:
        for offset in index_record_offsets:
            if offset not in selected_index_offsets:
                report.error(f"the Chunk Index record at byte {offset} lies outside the Footer-selected summary index")
    # Narrowed only when a summary was actually named. Otherwise the entries stay, because
    # they are still there to be read: emptying the list silently stopped every per-entry
    # check below from running on records whose own contents may be the fault.
    if footer_selects_summary:
        index = [
            entry for offset, entry in zip(index_record_offsets, index, strict=True) if offset in selected_index_offsets
        ]

    try:
        provenance.check()
    except FourdgsError as exc:
        report.error(str(exc))
    _check_provenance(provenance, report)
    try:
        objects.check()
    except FourdgsError as exc:
        report.error(str(exc))

    # Which chunk shape the rest of this validator is entitled to assume. A
    # `keyframe-delta` file's Chunks are keyframes and its Delta Chunks are differences
    # against them, so several checks below are about the gaussian-birth shape and about
    # nothing else. Read from the Header rather than guessed from the records, because a
    # file that carries Delta Chunks and does not say so is itself a fault.
    keyframe_delta = header is not None and header.temporal_model == "keyframe-delta"

    # `gaussian_count` counts distinct gaussians over the whole sequence under
    # `keyframe-delta`, and every keyframe carries a full population — so the sum across
    # chunks is a larger number by design, not a disagreement. Summing it anyway is what
    # made this validator call a conforming keyframe-delta file invalid.
    if header is not None and not keyframe_delta and counted != header.gaussian_count:
        report.error(f"Header declares {header.gaussian_count} gaussians; chunks contain {counted}")
    if header is not None:
        for source in audio_sources.values():
            for i, keyframe in enumerate(source.keyframes):
                if keyframe.time < 0 or keyframe.time > header.duration_sec:
                    report.error(
                        f"Audio Source id {source.source_id} keyframe {i} time {keyframe.time} "
                        f"is outside [0, {header.duration_sec}]"
                    )

    has_audio_records = op.AUDIO in seen or bool(audio_sources) or bool(audio_data)
    if header is not None and header.has_audio and not has_audio_records:
        report.error("Header says the file has audio, but there is no Audio Source or legacy Audio record")
    if header is not None and not header.has_audio and has_audio_records:
        report.error("there is an Audio Source or legacy Audio record, but the Header's audio flag is clear")
    if op.AUDIO in seen and audio_sources:
        report.error("legacy Audio and Audio Source records must not be mixed")
    for source_id, source in audio_sources.items():
        if source_id not in audio_data:
            report.error(f"Audio Source id {source_id} has no matching Audio Data record")
        elif source.data_length != audio_data[source_id]:
            report.error(
                f"Audio Source id {source_id} declares {source.data_length} bytes; "
                f"Audio Data contains {audio_data[source_id]}"
            )
    for source_id in audio_data.keys() - audio_sources.keys():
        report.error(f"Audio Data id {source_id} has no matching Audio Source record")

    # A Delta Chunk "exists only under `temporal_model = "keyframe-delta"`; a
    # `gaussian-birth` file never contains one" (§5.18). Neither reader says so: the
    # streamed one skips the opcode as though it were unknown, and the indexed one stops
    # at the first Chunk — so a Delta Chunk in a gaussian-birth file was read by nobody
    # and reported by nobody, and the state it carries silently was not in the scene.
    if first_delta_offset is not None and not keyframe_delta:
        model = "gaussian-birth" if header is None else header.temporal_model
        report.error(
            f"a Delta Chunk record appears at byte {first_delta_offset}, but the Header declares "
            f"temporal model {model!r}; Delta Chunks exist only under 'keyframe-delta' (§5.18)"
        )

    named_by_index: dict[int, int] = {}
    for i, entry in enumerate(index):
        if (
            entry.chunk_offset >= len(data)
            or entry.chunk_length < 9
            or entry.chunk_offset + entry.chunk_length > len(data)
        ):
            report.error(
                f"chunk index entry {i} range [{entry.chunk_offset}, "
                f"{entry.chunk_offset + entry.chunk_length}) does not contain a complete "
                f"record header inside the {len(data)}-byte file"
            )
            continue
        # A `keyframe-delta` file indexes both kinds: a Chunk is a keyframe and a Delta
        # Chunk is a difference against one, and an index that could only name the former
        # could not seek the model at all.
        at = data[entry.chunk_offset]
        if at != op.CHUNK and not (keyframe_delta and at == op.DELTA_CHUNK):
            report.error(f"chunk index entry {i} does not point at a Chunk record")
            continue
        if entry.chunk_offset in named_by_index:
            report.error(
                f"chunk index entries {named_by_index[entry.chunk_offset]} and {i} both name the "
                f"chunk at byte {entry.chunk_offset}; the index carries one entry per chunk (§4)"
            )
        named_by_index[entry.chunk_offset] = i

    # The index is data, and data in an untrusted file can say anything — including
    # nothing at all about a chunk that is in the file. Every check that decodes a chunk
    # below is driven by the index, so a chunk no entry names is a chunk nothing decodes:
    # a file whose index omits the one chunk carrying an unimplemented codec was reported
    # valid. The file layout is "one per chunk" (§4), so the omission is itself the fault
    # and naming it is better than quietly decoding around it.
    if index:
        for frame in walk.intact_records():
            if frame.opcode not in (op.CHUNK, op.DELTA_CHUNK):
                continue
            at = frame.offset
            if at not in named_by_index:
                report.error(
                    f"the {op.name(frame.opcode)} record at byte {at} is not named by any chunk index entry; "
                    f"a seeking reader never reads it (§4)"
                )

    if footer is not None and footer.summary_crc and footer.summary_start:
        tail = len(data) - (9 + 20 + len(MAGIC))
        actual = crc32(data[footer.summary_start : tail])
        if actual != footer.summary_crc:
            report.error("summary CRC mismatch: the index is untrustworthy (a streamed read still works)")

    if header is not None and not index:
        report.warn("no chunk index: this file can only be read front to back, not seeked")

    # What survived the cut, which is the question the errors above do not answer.
    #
    # A cut file is invalid and every finding about it stands — but records are
    # length-prefixed, so everything complete before the cut is intact and the streamed
    # reader keeps it. Saying only that the file stopped reading leaves its holder to
    # guess whether anything is salvageable; this says how much.
    if walk.cut is not None:
        record_start = (
            f"The incomplete record starts at byte {walk.cut.record_at:,}. " if walk.cut.record_at is not None else ""
        )
        report.note(
            f"the file is cut at byte {walk.cut.at:,}: {walk.cut.reason}. "
            f"{record_start}"
            f"The {walk.intact()} complete records before it are intact, "
            f"and a streamed reader recovers them"
        )

    if keyframe_delta:
        assert header is not None  # `keyframe_delta` is read off it
        # A *usable* index, not merely the presence of parsed Chunk Index records. The
        # indexed branch opens the file with `open_indexed`, which needs the Footer to
        # name a summary; a file whose `summary_start` is 0 carries index records that
        # no seeking reader can reach, and sending it down that branch refuses it with
        # "a seeking reader cannot open this file" and decodes nothing. §5.2 calls that
        # file indexless, and the streamed branch is the one that reads it.
        _check_keyframe_delta(data, walk, report, header, footer_selects_summary and bool(index))
    else:
        _check_gaussian_birth(data, walk, report)

    return report


def _check_gaussian_birth(data: bytes, walk: Walk, report: Report) -> None:
    """The two checks that only a reader can perform: open the file, then decode it.

    Opening it the way a seeking client would is where the front-matter refusals fire — an
    unimplemented temporal model, an unimplemented quantization scheme. Decoding the chunks
    is where the rest do, and there is no substitute for it: the framing walk steps over a
    chunk by its declared length, so an unimplemented stream codec and an out-of-range
    window index are both invisible to everything above. Both are in the invalid corpus,
    and both used to validate clean.
    """
    if not _check_compatibility_records(walk, data, report, "gaussian-birth"):
        return

    try:
        from .indexed_reader import open_indexed

        scene = open_indexed(BytesReadable(data))
        if scene.index:
            from .keyframe_delta_file import check_index_bands

            check_index_bands(data, scene.index, scene.header.sh_degree)
    except FourdgsError as exc:
        report.refused("a seeking reader cannot open this file: ", exc, walk)
        # A file that will not open will not decode either, and the second error would say
        # the same thing about the same byte.
        return
    refused = refusal.scan_chunks(data, walk)
    if refused is not None:
        report.refused("a chunk does not decode: ", refused.error, walk, refused.site)


def _check_keyframe_delta(data: bytes, walk: Walk, report: Report, header: rec.Header, indexed: bool) -> None:
    """The same, for the temporal model whose chunks are keyframes and differences.

    The same statement as the branch above — open the file the way a client would, then
    decode what it carries — expressed in the reader the file's declared model actually
    needs. The alternative, which is what this validator did until now, is to run the
    gaussian-birth reader over it and report its refusal as a fault in the file.

    Entry by entry, and never `decode_indexed`, for the two reasons the branch above is
    per chunk: a composed state is a whole population and holding one per index entry
    costs many times the file, and an entry that refuses is an entry whose **offset** the
    report can name.
    """
    from . import keyframe_delta_file as kdf

    if not _check_compatibility_records(walk, data, report, "keyframe-delta"):
        return

    current_site: Site | None = None

    def visiting_record(offset: int, opcode: int) -> None:
        nonlocal current_site
        current_site = Site(offset, f"the {op.name(opcode)} record")

    identity_audit = kdf.BoundedIdentityAudit()

    if not indexed:
        # No index is a legal file, not a broken one: §4 makes the summary optional and
        # AGENTS.md §2 makes streaming first-class. The indexed reader was being run over
        # it anyway, which read the Footer's `summary_start` of 0 as an offset and parsed
        # the magic as record framing — so every conforming indexless keyframe-delta file
        # was reported invalid, with a diagnosis about a record that does not exist.
        windows = _window_table(walk, data)
        first_t0: float | None = None
        previous_t1: float | None = None
        last_t1: float | None = None

        def interval(offset: int, t0: float, t1: float) -> None:
            nonlocal first_t0, previous_t1, last_t1
            if t1 < t0:
                raise FourdgsError(
                    f"state chunk at {offset} has an inverted interval [{t0}, {t1})",
                    code="non-tiling-chunks",
                )
            if first_t0 is None:
                first_t0 = t0
                if t0 != 0.0:
                    raise FourdgsError(
                        f"the first keyframe-delta state starts at {t0}, not 0",
                        code="timeline-gap",
                    )
            elif previous_t1 != t0:
                raise FourdgsError(
                    f"state chunk at {offset} starts at {t0}; the preceding interval ends at {previous_t1}",
                    code="timeline-gap",
                )
            previous_t1 = last_t1 = t1

        try:
            for _offset, _kind, state in kdf.scan_streamed(
                data,
                on_record=visiting_record,
                on_state=interval,
                sh_degree=header.sh_degree,
            ):
                kdf.check_window_indices_of(state, windows)
                identity_audit.observe(_offset, state)
                del state
            if last_t1 != header.duration_sec:
                raise FourdgsError(
                    f"the last keyframe-delta state ends at {last_t1}; the Header duration is {header.duration_sec}",
                    code="timeline-gap",
                )
        except FourdgsError as exc:
            report.refused("a chunk does not decode: ", exc, walk, current_site)
            return
    else:
        try:
            opened = kdf.open_indexed(data)
            kdf.check_index_bands(data, opened.index, opened.header.sh_degree)
        except FourdgsError as exc:
            report.refused("a seeking reader cannot open this file: ", exc, walk)
            return
        i = 0
        entry = opened.index[0] if opened.index else None
        band_site: Site | None = None

        def visiting(ordinal: int, candidate: rec.ChunkIndexEntry) -> None:
            nonlocal i, entry, band_site
            i, entry = ordinal, candidate
            band_site = None

        def visiting_band(band: int, offset: int) -> None:
            nonlocal band_site
            band_site = Site(offset, f"the SH Band Stream for band {band} at index entry {i}")

        def state_ready() -> None:
            nonlocal band_site
            # Band callbacks have completed successfully once scan_indexed yields. Any
            # refusal raised by the identity audit belongs to the owning state record.
            band_site = None

        try:
            for _entry, state in kdf.scan_indexed(
                data,
                opened.index,
                opened.windows,
                visiting,
                visiting_band,
                opened.grids,
            ):
                state_ready()
                identity_audit.observe(_entry.chunk_offset, state)
                # Dropped before the next entry is composed, not merely rebound after it:
                # the generator retains only current and GOP-keyframe state.
                del state
        except FourdgsError as exc:
            site = band_site
            if site is None and entry is not None:
                what = "Chunk" if entry.kind == 0 else "DeltaChunk"
                site = Site(entry.chunk_offset, f"the {what} record at index entry {i}")
            report.refused("a chunk does not decode: ", exc, walk, site)
            return

    if identity_audit.overflowed:
        try:
            if indexed:
                distinct = kdf.count_distinct_ids_bounded(
                    data,
                    index=opened.index,
                    windows=opened.windows,
                    on_entry=visiting,
                    on_band=visiting_band,
                    on_state=state_ready,
                )
            else:
                distinct = kdf.count_distinct_ids_bounded(data, on_record=visiting_record)
        except FourdgsError as exc:
            site = current_site
            if indexed:
                site = band_site
                if site is None and entry is not None:
                    what = "Chunk" if entry.kind == 0 else "DeltaChunk"
                    site = Site(entry.chunk_offset, f"the {what} record at index entry {i}")
            report.refused("a chunk does not decode: ", exc, walk, site)
            return
    else:
        distinct = identity_audit.distinct
    if distinct != header.gaussian_count:
        report.error(
            f"Header declares {header.gaussian_count} gaussians; the sequence carries {distinct} distinct gaussian ids"
        )


def _check_compatibility_records(
    walk: Walk,
    data: bytes,
    report: Report,
    expected_model: str,
) -> bool:
    """Gate every Header and Quantization record, including copies after the first Chunk.

    Indexed openers stop reading front matter at the first state record. Validation walks
    the whole file, so a later record must not be allowed to smuggle in a model or scheme
    that a front-to-back reader would refuse. The selected model is checked too: a known
    value for the other decoder is malformed here, while an unknown value keeps its named
    registry refusal.
    """
    from .registry import check_quantization_scheme, check_temporal_model

    gate_site: Site | None = None
    try:
        for frame in walk.intact_records():
            if frame.opcode not in (op.HEADER, op.QUANTIZATION):
                continue
            content = frame.content(data)
            if content is None:
                continue
            gate_site = Site(frame.offset, f"the {op.name(frame.opcode)} record")
            if frame.opcode == op.HEADER:
                model = rec.Header.parse(content).temporal_model
                if model != expected_model:
                    check_temporal_model(model)
                    raise FourdgsError(
                        f"a {expected_model} sequence contains a Header declaring {model!r}",
                        code="wrong-temporal-model",
                    )
            else:
                check_quantization_scheme(rec.Quantization.parse(content).scheme)
    except FourdgsError as exc:
        report.refused("a seeking reader cannot open this file: ", exc, walk, gate_site)
        return False
    return True


def _window_table(walk: Walk, data: bytes) -> list[tuple[float, float]]:
    """The effective Window Table, matching the streamed decoder's last-one-wins rule."""
    frame = None
    for record in walk.intact_records():
        if record.opcode == op.WINDOW_TABLE:
            frame = record
    if frame is None:
        return []
    content = frame.content(data)
    if content is None:
        return []
    try:
        return rec.WindowTable.parse(content).windows
    except FourdgsError:
        return []
