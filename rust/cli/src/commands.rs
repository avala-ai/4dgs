// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! `info`, `inspect` and `decode`: three commands, each a few lines over the library.

use fourdgs::indexed_reader::{open_indexed, IndexedScene};
use fourdgs::readable::{FileReadable, Readable};
use fourdgs::{opcode as op, Result, SceneReader};

use crate::args::Args;
use crate::{commas, json_string, round4, EXIT_FAILED, EXIT_OK};

const MIB: f64 = (1024 * 1024) as f64;

/// Summarize a file and what seeking it costs.
///
/// Opens on the indexed path and decodes nothing: every number here comes from the front
/// matter and the index, so `info` on a gigabyte file transfers a few kilobytes. The lines
/// through `attributes` are the Python tool's, in its order and its wording, because two
/// tools describing one file differently is the confusion neither of them is worth.
/// Registry names, so the output says "right-handed" rather than "1". An id this build
/// does not know prints as its number, which is the honest answer: an unrecognized
/// registry value is not a malformed one.
fn named(table: &[(u8, &'static str)], value: u8) -> String {
    table
        .iter()
        .find(|(k, _)| *k == value)
        .map(|(_, name)| (*name).to_string())
        .unwrap_or_else(|| value.to_string())
}

const HANDEDNESS: &[(u8, &str)] = &[(0, "unspecified"), (1, "right"), (2, "left")];
const AXES: &[(u8, &str)] = &[
    (0, "+x"),
    (1, "+y"),
    (2, "+z"),
    (3, "-x"),
    (4, "-y"),
    (5, "-z"),
];
const LENGTH_UNITS: &[(u8, &str)] = &[
    (0, "unspecified"),
    (1, "metre"),
    (2, "centimetre"),
    (3, "millimetre"),
    (4, "kilometre"),
    (5, "foot"),
    (6, "inch"),
];
const CAMERA_MODELS: &[(u8, &str)] = &[
    (0, "none"),
    (1, "pinhole"),
    (2, "brown-conrady"),
    (3, "kannala-brandt"),
];
const TRAJECTORY_INTERPOLATION: &[(u8, &str)] = &[(0, "linear"), (1, "step")];

/// What the file says about where it came from (spec section 5.15).
///
/// Prints nothing at all when the file carries no provenance, which is the point: absence
/// is not a missing feature to report on, and a scene with no sensors behind it is a
/// complete file rather than an under-specified one.
fn provenance(
    source: &mut FileReadable,
    scene: &fourdgs::indexed_reader::IndexedScene,
) -> Result<()> {
    if scene.provenance_ranges.is_empty() {
        return Ok(());
    }
    let prov = fourdgs::indexed_reader::read_provenance(source, scene)?;
    out!("");
    out!("provenance");
    for frame in &prov.frames {
        let label = if frame.name.is_empty() {
            "(scene frame)"
        } else {
            &frame.name
        };
        out!(
            "  frame        {label}  {}-handed, up {}, forward {}",
            named(HANDEDNESS, frame.handedness),
            named(AXES, frame.up_axis),
            named(AXES, frame.forward_axis)
        );
        let unit = named(LENGTH_UNITS, frame.length_unit);
        match prov.metres_per_unit(&frame.name) {
            Some(m) => out!("  units        {unit}  ({m} m per unit)"),
            None => out!("  units        {unit}"),
        }
    }
    for anchor in &prov.anchors {
        let suffix = if anchor.frame_name.is_empty() {
            String::new()
        } else {
            format!("  [frame {}]", anchor.frame_name)
        };
        out!(
            "  georeference {:.6}, {:.6} at {:.2} m, heading {:.1} deg{suffix}",
            anchor.latitude_deg,
            anchor.longitude_deg,
            anchor.altitude_m,
            anchor.heading_deg
        );
    }
    for sensor in &prov.sensors {
        let posed = if sensor.pose_reference == 0 {
            "scene frame".to_string()
        } else {
            format!("rig {:?}", sensor.rig_name)
        };
        let modality = if sensor.modality.is_empty() {
            "unstated"
        } else {
            &sensor.modality
        };
        let mut detail = format!("{modality}, {}", named(CAMERA_MODELS, sensor.camera_model));
        if sensor.is_camera() {
            detail.push_str(&format!(
                ", {}x{}, f=({}, {})",
                sensor.width_px, sensor.height_px, sensor.fx, sensor.fy
            ));
        }
        out!(
            "  sensor       {}  [{detail}]  posed against {posed}",
            sensor.name
        );
    }
    for t in &prov.trajectories {
        let name = if t.name.is_empty() {
            "(capture rig)"
        } else {
            &t.name
        };
        let span = if t.sample_count() > 0 {
            format!("{:.3}..{:.3} s", t.times[0], t.times[t.sample_count() - 1])
        } else {
            "empty".to_string()
        };
        out!(
            "  rig          {name}  {} samples, {span}, {}",
            t.sample_count(),
            named(TRAJECTORY_INTERPOLATION, t.interpolation)
        );
    }
    Ok(())
}

pub fn info(args: &Args) -> Result<u8> {
    let mut source = FileReadable::open(&args.file)?;
    let size = source.size()?;
    let scene = open_indexed(&mut source)?;
    let h = &scene.header;

    out!(
        "file           {}  ({:.2} MiB)",
        args.file,
        size as f64 / MIB
    );
    out!("gaussians      {}", commas(h.gaussian_count));
    out!("duration       {:.3} s", h.duration_sec);
    let profile = if h.profile.is_empty() {
        "(none)"
    } else {
        &h.profile
    };
    out!(
        "profile        {profile}   temporal model: {}",
        h.temporal_model
    );
    let library = if h.library.is_empty() {
        "(unstated)"
    } else {
        &h.library
    };
    out!("library        {library}");
    out!("spherical harm degree {}", h.sh_degree);
    // On its own line, and only when the file declares them: a file that declares nothing
    // is not a file at eight bits, it is a file that says nothing about the question. The
    // degree line above stays exactly what it was, which is what other tools grep for.
    let sh_bits = &scene.quantization.sh_bit_depths;
    if !sh_bits.is_empty() {
        let bits: Vec<String> = sh_bits.iter().map(|b| b.to_string()).collect();
        out!("sh band bits   {}", bits.join("/"));
    }
    out!("audio sources  {}", scene.audio_sources.len());
    out!("chunks         {}", scene.index.len());
    out!("windows        {}", scene.windows.len());
    let aabb: Vec<String> = h.aabb.iter().map(|v| round4(*v)).collect();
    out!("aabb           [{}]", aabb.join(", "));
    if let Some(ok) = scene.summary_crc_ok {
        out!("summary crc    {}", if ok { "ok" } else { "MISMATCH" });
    }
    if !h.attributes.is_empty() {
        out!("attributes");
        for (k, v) in &h.attributes {
            out!("  {k} = {v}");
        }
    }

    provenance(&mut source, &scene)?;
    layout(&scene);
    if args.names {
        names(&args.file)?;
    }
    seek_cost(&scene);
    Ok(EXIT_OK)
}

/// Where the file's parts are, from the index alone.
fn layout(scene: &IndexedScene) {
    out!("\nlayout:");
    out!(
        "  camera         {}",
        if scene.camera_range.is_some() {
            "present"
        } else {
            "none"
        }
    );
    out!("  metadata       {} records", scene.metadata_ranges.len());
    out!(
        "  attachments    {} records ({} bytes)",
        scene.attachment_ranges.len(),
        commas(scene.attachment_ranges.iter().map(|(_, n)| n).sum::<u64>())
    );
    match &scene.statistics {
        Some(stats) => out!(
            "  statistics     {} gaussians, {} chunks, {:.3} s",
            commas(stats.gaussian_count),
            stats.chunk_count,
            stats.duration_sec
        ),
        None => out!("  statistics     none"),
    }
    if scene.summary_offsets.is_empty() {
        out!("  summary        no summary offsets");
    }
    for offset in &scene.summary_offsets {
        out!(
            "  summary        {:<16} at {:>12}  {:>12} bytes",
            op::name(offset.group_opcode),
            commas(offset.group_start),
            commas(offset.group_length)
        );
    }
}

/// The names behind the metadata and attachment records.
///
/// Behind `--names` rather than in the default output because an attachment's name is the
/// first field of a record whose last field is its payload: asking for the name reads the
/// thumbnail sheet too, and `info` promises not to.
fn names(path: &str) -> Result<()> {
    let mut reader = SceneReader::open(FileReadable::open(path)?)?;
    let metadata = reader.metadata()?;
    let attachments = reader.attachments()?;
    if !metadata.is_empty() {
        out!("\nmetadata:");
        for record in &metadata {
            out!("  {} ({} entries)", record.name, record.entries.len());
        }
    }
    if !attachments.is_empty() {
        out!("\nattachments:");
        for record in &attachments {
            let media = if record.media_type.is_empty() {
                "(no media type)"
            } else {
                &record.media_type
            };
            out!(
                "  {}  {media}  {} bytes",
                record.name,
                commas(record.data.len() as u64)
            );
        }
    }
    Ok(())
}

/// What an instant costs, sampled across the clip. Five points, the Python tool's.
fn seek_cost(scene: &IndexedScene) {
    if scene.index.is_empty() {
        return;
    }
    out!("\nseek cost (bytes to render an instant):");
    for i in 0..5 {
        let t = scene.header.duration_sec * (i as f64) / 5.0;
        let entries = scene.chunks_for_time(t);
        let bytes = scene.bytes_for_time(t, 0);
        let gaussians: u64 = entries.iter().map(|e| e.gaussian_count as u64).sum();
        out!(
            "  t={t:7.3}s  {:3} ranges  {:8.3} MiB  ({} gaussians)",
            entries.len(),
            bytes as f64 / MIB,
            commas(gaussians)
        );
    }
}

/// What the Footer's summary checksum covers, and whether it agrees.
///
/// The only checksum the format defines: `summary_crc` over the bytes from
/// `summary_start` to where the Footer begins. So a record's "CRC status" is a fact about
/// the region it sits in rather than a field of its own — covered and agreeing, covered
/// and not, or covered by nothing at all — and saying so per record is what tells a reader
/// whether the checksum has anything to say about the record they are looking at.
#[derive(Debug)]
struct Coverage {
    start: u64,
    /// One past the last covered byte: where the Footer record's opcode sits.
    end: u64,
    ok: bool,
}

impl Coverage {
    /// The cell for a record, in the vocabulary `info` already prints for the file as a
    /// whole.
    fn cell(this: &Option<Coverage>, at: u64, total: u64) -> &'static str {
        match this {
            Some(c) if at >= c.start && at.saturating_add(total) <= c.end => {
                if c.ok {
                    "ok"
                } else {
                    "MISMATCH"
                }
            }
            _ => "-",
        }
    }
}

/// How much of the summary is read at once while its checksum is computed.
///
/// The region is `[summary_start, footer_start)`, and `summary_start` is eight bytes off an
/// untrusted file: a Footer may name byte 8, which makes the region the whole file. Sizing
/// one allocation from it is how a tool asked to look at a bad file runs out of memory
/// reporting on it, so the checksum is fed in blocks of this size instead (principle 1).
const CRC_BLOCK: u64 = 1024 * 1024;

/// The Footer's three fields: `summary_start`, `summary_offset_start`, `summary_crc`.
///
/// `Footer::parse` reads exactly these twenty bytes and ignores whatever follows — which is
/// what makes a Footer a later revision extends still readable here. So twenty bytes is all
/// this command reads of one, and the record's own declared length, eight bytes off an
/// untrusted file, never sizes an allocation: a Footer that declares the rest of the file as
/// its content is a fact `inspect` prints in the length column, not a buffer it makes.
const FOOTER_FIELDS: u64 = 20;

/// Read the Footer and check the summary it declares.
///
/// `None` when the file declares no summary checksum, which is a property of the file
/// rather than a failure: `write_crc` is an encoder option and a file written without it
/// has nothing here to verify. `None` too when the file was cut inside its own Footer —
/// the walk lists that record because its declared length is the fault, but its content is
/// not in the file, and a read of it would end `inspect` through the error path with the
/// intact-prefix report unprinted. Which is exactly the file this command exists for.
fn coverage(
    source: &mut dyn Readable,
    footer_frame: Option<crate::refusal::Frame>,
) -> Result<Option<Coverage>> {
    let Some(frame) = footer_frame else {
        return Ok(None);
    };
    let content = source.read(
        frame.offset + fourdgs::serialization::RECORD_HEADER_SIZE as u64,
        frame.length.min(FOOTER_FIELDS),
    )?;
    let footer = fourdgs::records::Footer::parse(&content)?;
    if footer.summary_crc == 0 || footer.summary_start == 0 {
        return Ok(None);
    }
    if footer.summary_start > frame.offset {
        return Err(fourdgs::Error::Malformed(format!(
            "the Footer says its checksummed summary starts at {}, after the Footer itself at {}",
            footer.summary_start, frame.offset
        )));
    }
    // The summary ends where the Footer begins — taken from the walk rather than computed
    // from a footer's expected size, so a Footer that a later revision extends does not
    // move the region out from under the check.
    let mut crc = fourdgs::serialization::Crc32::new();
    let mut at = footer.summary_start;
    while at < frame.offset {
        let take = (frame.offset - at).min(CRC_BLOCK);
        crc.update(&source.read(at, take)?);
        at += take;
    }
    Ok(Some(Coverage {
        start: footer.summary_start,
        end: frame.offset,
        ok: crc.finish() == footer.summary_crc,
    }))
}

/// Walk the records: offset, opcode, length, CRC status.
///
/// Framing only, plus the summary region the Footer names. A record's content is never
/// read, so this is as cheap on a file with an embedded audio payload as on one without,
/// and an opcode nobody here has heard of is stepped over by its own declared length —
/// which is the whole forward-compatibility story, exercised rather than described.
///
/// A file that was cut is walked as far as it goes and then says so. That is what the
/// library does with one — records are length-prefixed, so everything complete before the
/// cut is intact and a streamed reader keeps it — and a tool whose job is to say where a
/// file stops being a 4dgs file should not answer that question by printing one line and
/// throwing the rest away.
pub fn inspect(args: &Args) -> Result<u8> {
    let mut source = FileReadable::open(&args.file)?;
    let mut footer = None;
    let summary = crate::refusal::walk_each(&mut source, |frame, intact| {
        if intact && frame.opcode == op::FOOTER && footer.is_none() {
            footer = Some(frame);
        }
    })?;
    let coverage = coverage(&mut source, footer)?;

    if args.json {
        print_inspect_json(&mut source, &summary, &coverage)?;
    } else {
        print_inspect_text(&mut source, &summary, &coverage)?;
    }
    // The prefix was recovered and reported; the file is still not a whole one, and a
    // pipeline that goes on to read it should not be told otherwise.
    Ok(if summary.cut.is_some() {
        EXIT_FAILED
    } else {
        EXIT_OK
    })
}

fn print_inspect_text(
    source: &mut dyn Readable,
    walk: &crate::refusal::WalkSummary,
    coverage: &Option<Coverage>,
) -> Result<()> {
    out!(
        "{:>12}  {:<18} {:>14}  {:>14}  {}",
        "offset",
        "record",
        "content",
        "total",
        "crc"
    );
    out!(
        "{:>12}  {:<18} {:>14}  {:>14}  {}",
        0,
        "(magic)",
        "",
        8,
        "-"
    );
    crate::refusal::walk_each(source, |frame, _| {
        out!(
            "{:>12}  {:<18} {:>14}  {:>14}  {}",
            commas(frame.offset),
            op::name(frame.opcode),
            commas(frame.length),
            commas(frame.total()),
            Coverage::cell(coverage, frame.offset, frame.total())
        );
    })?;
    if walk.trailing_magic {
        out!(
            "{:>12}  {:<18} {:>14}  {:>14}  {}",
            commas(walk.size - 8),
            "(magic)",
            "",
            8,
            "-"
        );
    }
    out!(
        "\n{} records, {} bytes",
        walk.record_count,
        commas(walk.size)
    );
    match &walk.cut {
        Some(cut) => {
            out!("truncated at byte {}: {}", commas(cut.at), cut.reason);
            out!(
                "the {} complete records above are the intact prefix, which is what a streamed \
                 reader keeps{}",
                walk.intact,
                if cut.inside_a_record {
                    "; the last row is the record the file was cut inside"
                } else {
                    ""
                }
            );
        }
        None if !walk.trailing_magic => out!("note: the file does not end with the magic"),
        None => {}
    }
    match coverage {
        Some(c) => out!(
            "crc: the Footer's summary checksum covers bytes {}..{}; `-` is a record it does not cover",
            commas(c.start),
            commas(c.end)
        ),
        None => out!("crc: this file declares no summary checksum, so nothing here is covered"),
    }
    Ok(())
}

fn print_inspect_json(
    source: &mut dyn Readable,
    walk: &crate::refusal::WalkSummary,
    coverage: &Option<Coverage>,
) -> Result<()> {
    out!("{{");
    out!("  \"size\": {},", walk.size);
    out!("  \"trailing_magic\": {},", walk.trailing_magic);
    match &walk.cut {
        Some(cut) => {
            out!("  \"stopped\": {},", json_string(&cut.reason));
            out!("  \"truncated_at\": {},", cut.at);
        }
        None => {
            out!("  \"stopped\": null,");
            out!("  \"truncated_at\": null,");
        }
    }
    match coverage {
        Some(c) => out!(
            "  \"summary_crc\": {{\"start\": {}, \"end\": {}, \"ok\": {}}},",
            c.start,
            c.end,
            c.ok
        ),
        None => out!("  \"summary_crc\": null,"),
    }
    out!("  \"records\": [");
    let mut i = 0usize;
    crate::refusal::walk_each(source, |frame, _| {
        i += 1;
        let comma = if i == walk.record_count { "" } else { "," };
        let crc = Coverage::cell(coverage, frame.offset, frame.total());
        let crc = if crc == "-" {
            "null".to_string()
        } else {
            json_string(&crc.to_lowercase())
        };
        out!(
            "    {{\"offset\": {}, \"opcode\": {}, \"name\": {}, \"content_length\": {}, \"total_length\": {}, \"crc\": {crc}}}{comma}",
            frame.offset,
            frame.opcode,
            json_string(&op::name(frame.opcode)),
            frame.length,
            frame.total()
        );
    })?;
    out!("  ]");
    out!("}}");
    Ok(())
}

/// Report the gaussians visible at an instant.
///
/// Decoding ends at reconstructed state, and so does this: which gaussians exist at `t`,
/// where they are and how opaque they are. Nothing here says how any of it should be
/// drawn.
pub fn decode(args: &Args) -> Result<u8> {
    let mut reader = SceneReader::open(FileReadable::open(&args.file)?)?;
    // Spherical harmonics do not enter reconstructed state, so band 0 is not a reduced
    // answer — it is the same answer without fetching coefficients nobody asked for.
    let state = reader.state_at(args.time, 0)?;
    // The file's own declared count, not what the seek happened to load: on the indexed
    // path a seek loads only the chunks covering `t`, and "of the whole scene" is what
    // the fraction means.
    let total = reader.header().gaussian_count;
    let visible = state.count() as u64;

    if args.json {
        out!("{{");
        out!("  \"time\": {},", json_f64(args.time));
        out!("  \"visible\": {visible},");
        out!("  \"total\": {total}");
        out!("}}");
        return Ok(EXIT_OK);
    }

    let entries: Vec<_> = reader
        .chunk_index()
        .iter()
        .filter(|e| e.covers(args.time))
        .collect();
    let ranges = entries.len();
    let bytes: u64 = (0..reader.chunk_index().len())
        .filter(|i| reader.chunk_index()[*i].covers(args.time))
        .filter_map(|i| reader.bytes_for_chunk(i as u32, 0))
        .fold(0, u64::saturating_add);

    out!("file           {}", args.file);
    out!("mode           {:?}", reader.mode());
    out!(
        "time           {:.3} s of {:.3} s",
        args.time,
        reader.header().duration_sec
    );
    out!("cutoff         {}", round4(reader.header().cutoff));
    let percent = if total == 0 {
        0.0
    } else {
        100.0 * visible as f64 / total as f64
    };
    out!(
        "visible        {} of {} gaussians  ({percent:.1}%)",
        commas(visible),
        commas(total)
    );
    out!(
        "chunks read    {ranges} ranges, {:.3} MiB",
        bytes as f64 / MIB
    );
    if visible == 0 {
        out!("nothing exists at this instant");
        return Ok(EXIT_OK);
    }
    let bounds = extent(&state.centers);
    out!(
        "centre         [{}, {}, {}]",
        round4(mean(&state.centers, 3, 0)),
        round4(mean(&state.centers, 3, 1)),
        round4(mean(&state.centers, 3, 2))
    );
    out!(
        "bounds         [{}]",
        bounds
            .iter()
            .map(|v| round4(*v))
            .collect::<Vec<_>>()
            .join(", ")
    );
    let (lo, hi) = (
        state.opacity.iter().copied().fold(f32::INFINITY, f32::min),
        state
            .opacity
            .iter()
            .copied()
            .fold(f32::NEG_INFINITY, f32::max),
    );
    out!(
        "opacity        min {}  mean {}  max {}",
        round4(lo as f64),
        round4(mean(&state.opacity, 1, 0)),
        round4(hi as f64)
    );
    Ok(EXIT_OK)
}

/// A float the way `json.dumps` spells it, so that the two tools' `--json` output is
/// comparable by a diff rather than by eye.
fn json_f64(v: f64) -> String {
    if v == v.trunc() && v.is_finite() {
        format!("{v:.1}")
    } else {
        format!("{v}")
    }
}

fn mean(values: &[f32], stride: usize, offset: usize) -> f64 {
    let mut sum = 0.0;
    let mut n = 0u64;
    let mut i = offset;
    while i < values.len() {
        sum += values[i] as f64;
        n += 1;
        i += stride;
    }
    if n == 0 {
        0.0
    } else {
        sum / n as f64
    }
}

fn extent(centers: &[f32]) -> [f64; 6] {
    let mut out = [
        f64::INFINITY,
        f64::INFINITY,
        f64::INFINITY,
        f64::NEG_INFINITY,
        f64::NEG_INFINITY,
        f64::NEG_INFINITY,
    ];
    for point in centers.chunks_exact(3) {
        for k in 0..3 {
            out[k] = out[k].min(point[k] as f64);
            out[k + 3] = out[k + 3].max(point[k] as f64);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use fourdgs::serialization::{crc32, MAGIC, RECORD_HEADER_SIZE};
    use fourdgs::BytesReadable;

    /// A reader that remembers the largest single read asked of it.
    ///
    /// The claim under test is about an allocation, and an allocation here is exactly one
    /// `read` with a length taken from the file. So the way to test it is to watch the
    /// lengths: no assertion about peak memory tells a bounded loop from an unbounded one,
    /// and this does.
    struct Watched<'a> {
        inner: BytesReadable<'a>,
        largest: std::cell::Cell<u64>,
    }

    impl<'a> Watched<'a> {
        fn new(data: &'a [u8]) -> Watched<'a> {
            Watched {
                inner: BytesReadable::new(data),
                largest: std::cell::Cell::new(0),
            }
        }
    }

    impl Readable for Watched<'_> {
        fn size(&mut self) -> fourdgs::Result<u64> {
            self.inner.size()
        }

        fn read(&mut self, offset: u64, length: u64) -> fourdgs::Result<Vec<u8>> {
            self.largest.set(self.largest.get().max(length));
            self.inner.read(offset, length)
        }
    }

    /// A file whose Footer declares far more content than its three fields occupy.
    ///
    /// Legal framing, and forward-compatible by design: `Footer::parse` reads twenty bytes
    /// and ignores the rest, so a Footer a later revision extends still reads here. That
    /// declared length is eight bytes off an untrusted file, though, and a file can name
    /// nearly the whole of itself in it.
    fn footer_declaring(padding: usize) -> Vec<u8> {
        let summary = fourdgs::records::Statistics {
            gaussian_count: 0,
            chunk_count: 0,
            duration_sec: 1.0,
            aabb: vec![0.0; 6],
        }
        .encode();
        let mut out = MAGIC.to_vec();
        out.extend_from_slice(
            &fourdgs::records::Header {
                duration_sec: 1.0,
                aabb: vec![0.0; 6],
                temporal_model: "gaussian-birth".into(),
                ..Default::default()
            }
            .encode(&[]),
        );
        let summary_start = out.len() as u64;
        out.extend_from_slice(&summary);

        // The Footer's three fields, then the padding its declared length covers.
        let mut body = Vec::new();
        body.extend_from_slice(&summary_start.to_le_bytes());
        body.extend_from_slice(&0u64.to_le_bytes());
        body.extend_from_slice(&crc32(&summary).to_le_bytes());
        body.resize(20 + padding, 0);
        out.push(op::FOOTER);
        out.extend_from_slice(&(body.len() as u64).to_le_bytes());
        out.extend_from_slice(&body);
        out.extend_from_slice(&MAGIC);
        out
    }

    #[test]
    fn the_footer_is_read_twenty_bytes_at_a_time_whatever_it_declares() {
        // A Footer declaring the rest of the file as its content used to size one
        // allocation from that declaration: `inspect` on a hostile file buffered nearly
        // the whole of it to read three fields out of the front.
        let padding = 4096;
        let data = footer_declaring(padding);
        let mut source = Watched::new(&data);
        let walk = crate::refusal::walk(&mut source).expect("a walk");
        let frame = walk
            .first_intact(op::FOOTER)
            .expect("the file ends with a Footer");
        assert_eq!(
            frame.length,
            (20 + padding) as u64,
            "the fixture's Footer declares more than its fields occupy"
        );

        source.largest.set(0);
        let coverage =
            coverage(&mut source, walk.first_intact(op::FOOTER)).expect("a coverage verdict");
        assert!(
            coverage.is_some_and(|c| c.ok),
            "the fixture's summary checksum agrees"
        );
        assert!(
            source.largest.get() <= FOOTER_FIELDS.max(CRC_BLOCK),
            "one read asked for {} bytes; the Footer is read {FOOTER_FIELDS} bytes at a \
             time and the summary {CRC_BLOCK} at a time",
            source.largest.get()
        );
        assert!(
            source.largest.get() < frame.length,
            "a read was sized from the Footer's own declared length"
        );
    }

    #[test]
    fn a_footer_shorter_than_its_fields_is_still_refused() {
        // The bound is a `min`, so a Footer declaring less than twenty bytes is read as far
        // as it goes and then fails to parse — the same answer as before, and not a read
        // that runs past the record.
        let mut data = footer_declaring(0);
        let footer_at = data.len() - (RECORD_HEADER_SIZE + 20 + MAGIC.len());
        data[footer_at + 1] = 12;
        data.truncate(footer_at + RECORD_HEADER_SIZE + 12);
        data.extend_from_slice(&MAGIC);
        let mut source = BytesReadable::new(&data);
        let walk = crate::refusal::walk(&mut source).expect("a walk");
        assert!(coverage(&mut source, walk.first_intact(op::FOOTER)).is_err());
    }

    #[test]
    fn a_checksummed_summary_cannot_start_after_its_footer() {
        let mut data = footer_declaring(0);
        let footer_at = data.len() - (RECORD_HEADER_SIZE + 20 + MAGIC.len());
        let impossible = (footer_at as u64 + 1).to_le_bytes();
        let start = footer_at + RECORD_HEADER_SIZE;
        data[start..start + 8].copy_from_slice(&impossible);

        let mut source = BytesReadable::new(&data);
        let walk = crate::refusal::walk(&mut source).expect("a framing walk");
        let error = coverage(&mut source, walk.first_intact(op::FOOTER))
            .expect_err("the checksum range is impossible");
        assert!(
            error.to_string().contains("after the Footer itself"),
            "{error}"
        );
    }
}
