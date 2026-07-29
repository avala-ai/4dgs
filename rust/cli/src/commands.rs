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
pub fn info(args: &Args) -> Result<u8> {
    let mut source = FileReadable::open(&args.file)?;
    let size = source.size()?;
    let scene = open_indexed(&mut source)?;
    let h = &scene.header;

    println!(
        "file           {}  ({:.2} MiB)",
        args.file,
        size as f64 / MIB
    );
    println!("gaussians      {}", commas(h.gaussian_count));
    println!("duration       {:.3} s", h.duration_sec);
    let profile = if h.profile.is_empty() {
        "(none)"
    } else {
        &h.profile
    };
    println!(
        "profile        {profile}   temporal model: {}",
        h.temporal_model
    );
    let library = if h.library.is_empty() {
        "(unstated)"
    } else {
        &h.library
    };
    println!("library        {library}");
    println!("spherical harm degree {}", h.sh_degree);
    println!(
        "audio          {}",
        match (scene.has_audio(), scene.audio_codec.as_deref()) {
            (true, Some(codec)) => codec,
            (true, None) => "(unstated)",
            (false, _) => "none",
        }
    );
    println!("chunks         {}", scene.index.len());
    println!("windows        {}", scene.windows.len());
    let aabb: Vec<String> = h.aabb.iter().map(|v| round4(*v)).collect();
    println!("aabb           [{}]", aabb.join(", "));
    if let Some(ok) = scene.summary_crc_ok {
        println!("summary crc    {}", if ok { "ok" } else { "MISMATCH" });
    }
    if !h.attributes.is_empty() {
        println!("attributes");
        for (k, v) in &h.attributes {
            println!("  {k} = {v}");
        }
    }

    layout(&scene);
    if args.names {
        names(&args.file)?;
    }
    seek_cost(&scene);
    Ok(EXIT_OK)
}

/// Where the file's parts are, from the index alone.
fn layout(scene: &IndexedScene) {
    println!("\nlayout:");
    println!(
        "  camera         {}",
        if scene.camera_range.is_some() {
            "present"
        } else {
            "none"
        }
    );
    println!("  metadata       {} records", scene.metadata_ranges.len());
    println!(
        "  attachments    {} records ({} bytes)",
        scene.attachment_ranges.len(),
        commas(scene.attachment_ranges.iter().map(|(_, n)| n).sum::<u64>())
    );
    match &scene.statistics {
        Some(stats) => println!(
            "  statistics     {} gaussians, {} chunks, {:.3} s",
            commas(stats.gaussian_count),
            stats.chunk_count,
            stats.duration_sec
        ),
        None => println!("  statistics     none"),
    }
    if scene.summary_offsets.is_empty() {
        println!("  summary        no summary offsets");
    }
    for offset in &scene.summary_offsets {
        println!(
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
        println!("\nmetadata:");
        for record in &metadata {
            println!("  {} ({} entries)", record.name, record.entries.len());
        }
    }
    if !attachments.is_empty() {
        println!("\nattachments:");
        for record in &attachments {
            let media = if record.media_type.is_empty() {
                "(no media type)"
            } else {
                &record.media_type
            };
            println!(
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
    println!("\nseek cost (bytes to render an instant):");
    for i in 0..5 {
        let t = scene.header.duration_sec * (i as f64) / 5.0;
        let entries = scene.chunks_for_time(t);
        let bytes = scene.bytes_for_time(t, 0);
        let gaussians: u64 = entries.iter().map(|e| e.gaussian_count as u64).sum();
        println!(
            "  t={t:7.3}s  {:3} ranges  {:8.3} MiB  ({} gaussians)",
            entries.len(),
            bytes as f64 / MIB,
            commas(gaussians)
        );
    }
}

/// Walk the records: offset, opcode, length.
///
/// Framing only. A record's content is never read, so this is as cheap on a file with an
/// embedded film soundtrack as on one without, and an opcode nobody here has heard of is
/// stepped over by its own declared length — which is the whole forward-compatibility
/// story, exercised rather than described.
pub fn inspect(args: &Args) -> Result<u8> {
    let mut source = FileReadable::open(&args.file)?;
    let size = source.size()?;
    let head = source.read(0, fourdgs::MAGIC.len().min(size as usize) as u64)?;
    fourdgs::serialization::check_magic(&head)?;

    let mut rows: Vec<(u64, u8, u64)> = Vec::new();
    let mut at = fourdgs::MAGIC.len() as u64;
    let mut trailing_magic = false;
    let mut stopped: Option<String> = None;
    loop {
        let remaining = size.saturating_sub(at);
        if remaining == 0 {
            break;
        }
        // The file ends with the magic, so the last eight bytes are not a record.
        if remaining <= fourdgs::MAGIC.len() as u64 {
            trailing_magic = source.read(at, remaining)? == fourdgs::MAGIC;
            break;
        }
        if remaining < fourdgs::serialization::RECORD_HEADER_SIZE as u64 {
            stopped = Some(format!("{remaining} bytes at {at} are not a record header"));
            break;
        }
        let framing = source.read(at, fourdgs::serialization::RECORD_HEADER_SIZE as u64)?;
        let opcode = framing[0];
        let length = u64::from_le_bytes([
            framing[1], framing[2], framing[3], framing[4], framing[5], framing[6], framing[7],
            framing[8],
        ]);
        let total = match length.checked_add(fourdgs::serialization::RECORD_HEADER_SIZE as u64) {
            Some(total) if at.checked_add(total).is_some_and(|end| end <= size) => total,
            _ => {
                stopped = Some(format!(
                    "the {} record at {at} declares {length} bytes, past the end of a {size}-byte file",
                    op::name(opcode)
                ));
                rows.push((at, opcode, length));
                break;
            }
        };
        rows.push((at, opcode, length));
        at += total;
    }

    if args.json {
        print_inspect_json(&rows, size, trailing_magic, stopped.as_deref());
    } else {
        print_inspect_text(&rows, size, trailing_magic, stopped.as_deref());
    }
    Ok(if stopped.is_some() {
        EXIT_FAILED
    } else {
        EXIT_OK
    })
}

fn print_inspect_text(
    rows: &[(u64, u8, u64)],
    size: u64,
    trailing_magic: bool,
    stopped: Option<&str>,
) {
    println!(
        "{:>12}  {:<18} {:>14}  {:>14}",
        "offset", "record", "content", "total"
    );
    println!("{:>12}  {:<18} {:>14}  {:>14}", 0, "(magic)", "", 8);
    for (at, opcode, length) in rows {
        println!(
            "{:>12}  {:<18} {:>14}  {:>14}",
            commas(*at),
            op::name(*opcode),
            commas(*length),
            commas(length + fourdgs::serialization::RECORD_HEADER_SIZE as u64)
        );
    }
    if trailing_magic {
        println!(
            "{:>12}  {:<18} {:>14}  {:>14}",
            commas(size - 8),
            "(magic)",
            "",
            8
        );
    }
    println!(
        "\n{} records, {} bytes{}",
        rows.len(),
        commas(size),
        if stopped.is_some() {
            " (the last record is incomplete)"
        } else {
            ""
        }
    );
    if !trailing_magic && stopped.is_none() {
        println!("note: the file does not end with the magic");
    }
    if let Some(reason) = stopped {
        eprintln!("4dgs: stopped: {reason}");
    }
}

fn print_inspect_json(
    rows: &[(u64, u8, u64)],
    size: u64,
    trailing_magic: bool,
    stopped: Option<&str>,
) {
    println!("{{");
    println!("  \"size\": {size},");
    println!("  \"trailing_magic\": {trailing_magic},");
    match stopped {
        Some(reason) => println!("  \"stopped\": {},", json_string(reason)),
        None => println!("  \"stopped\": null,"),
    }
    println!("  \"records\": [");
    for (i, (at, opcode, length)) in rows.iter().enumerate() {
        let comma = if i + 1 == rows.len() { "" } else { "," };
        println!(
            "    {{\"offset\": {at}, \"opcode\": {opcode}, \"name\": {}, \"content_length\": {length}, \"total_length\": {}}}{comma}",
            json_string(&op::name(*opcode)),
            length + fourdgs::serialization::RECORD_HEADER_SIZE as u64
        );
    }
    println!("  ]");
    println!("}}");
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
        println!("{{");
        println!("  \"time\": {},", json_f64(args.time));
        println!("  \"visible\": {visible},");
        println!("  \"total\": {total}");
        println!("}}");
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

    println!("file           {}", args.file);
    println!("mode           {:?}", reader.mode());
    println!(
        "time           {:.3} s of {:.3} s",
        args.time,
        reader.header().duration_sec
    );
    println!("cutoff         {}", round4(reader.header().cutoff));
    let percent = if total == 0 {
        0.0
    } else {
        100.0 * visible as f64 / total as f64
    };
    println!(
        "visible        {} of {} gaussians  ({percent:.1}%)",
        commas(visible),
        commas(total)
    );
    println!(
        "chunks read    {ranges} ranges, {:.3} MiB",
        bytes as f64 / MIB
    );
    if visible == 0 {
        println!("nothing exists at this instant");
        return Ok(EXIT_OK);
    }
    let bounds = extent(&state.centers);
    println!(
        "centre         [{}, {}, {}]",
        round4(mean(&state.centers, 3, 0)),
        round4(mean(&state.centers, 3, 1)),
        round4(mean(&state.centers, 3, 2))
    );
    println!(
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
    println!(
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
