# fourdgs

A decoder for the **4dgs** container: 4D gaussian splat video with native audio, in one
self-contained file you can range-request and seek.

Pure Dart, no Flutter dependency — the same code runs on the Dart VM, inside a Flutter app, and
compiled to JavaScript or Wasm.

The format's specification, the feature matrix and the guides live at
**[4dgs.dev](https://4dgs.dev)**.

## Install

```bash
dart pub add fourdgs
```

The package is `fourdgs` rather than `4dgs` because a pub.dev package name is a Dart identifier and
may not begin with a digit. The format, the file extension and the CLI are always `4dgs`.

## Decode a whole file

```dart
import 'dart:io';
import 'package:fourdgs/fourdgs.dart';

void main() {
  final scene = readFourdgsBytes(File('scene.4dgs').readAsBytesSync());

  print('${scene.gaussians.count} gaussians over ${scene.durationSec}s');
  if (scene.truncated) print('the file was cut short; this is what preceded the cut');

  // Reconstructed state at an instant, exactly as the specification defines it:
  // the validity window, then the temporal marginal against the file's cutoff.
  final live = scene.gaussians.stateAt(1.5, cutoff: scene.header.cutoff);
  print('${live.count} visible at t=1.5');

  for (final source in scene.audioSources) {
    // The format reconstructs source-local timing and scene-space pose. The
    // player combines this with its listener pose to spatialize and mix.
    final audio = source.stateAt(1.5);
    print('${source.name}: ${audio.position}, local ${audio.localTime}s');
  }
}
```

A truncated download is not an error. Records are length-prefixed, so everything complete before the
cut decodes — and `scene.truncated` says it was cut, which is the part that matters: a decoder that
quietly returned fewer gaussians would be indistinguishable from one reading a smaller file.

## Seek without reading the file

```dart
import 'package:fourdgs/fourdgs.dart';
import 'package:fourdgs/io.dart';

Future<void> main() async {
  final source = await FourdgsFileReadable.open('scene.4dgs');
  final scene = await openFourdgsIndexed(source);

  print('a seek to 1.5s costs ${scene.bytesForTime(1.5)} bytes');
  for (final entry in scene.chunksForTime(1.5)) {
    final chunk = await readFourdgsChunk(source, scene, entry);
    print('${chunk.count} gaussians from [${entry.t0}, ${entry.t1})');
  }
  await source.close();
}
```

Opening a scene reads the front matter and the index, never the file. Audio, camera, metadata and
attachments are byte ranges until you ask for them. `readFourdgsAudioSourceDescriptors` reconstructs
moving source poses without transferring codec payloads; `readFourdgsAudioRange` reads one slice of
one source; and `readFourdgsAudioSources` materializes every source. Camera, metadata and
attachments have corresponding deferred reads. A scene without audio carries no source records at
all.

```dart
final descriptors = await readFourdgsAudioSourceDescriptors(source, scene);
for (final descriptor in descriptors) {
  final state = descriptor.stateAt(1.5);
  print('${descriptor.sourceId}: ${state.position}');
}

final packet = await readFourdgsAudioRange(
  source,
  scene,
  descriptors.first.sourceId,
  0,
  4096,
);
```

**What opening actually costs.** One read of 64 KiB from the front, plus one for the footer and one
for the index. `scene.headerBytes` reports what the front-matter scan transferred — every read it
made, not just the first — so a caller can measure the part that varies rather than assume it.

A scene whose front matter is larger than that probe costs **one extra round trip** — in practice,
one with an embedded audio track, because the track sits in the front matter and the scan has to
reach the first Chunk to know what else is there. The record itself is still stepped over by
arithmetic rather than transferred, so the extra request is another 64 KiB and not another six
megabytes.

That is a deliberate trade against an earlier design that stopped as soon as the Header, the
Quantization grids and the Window Table were in hand. The specification fixes the Header first and
the Footer last and leaves the order of everything between them free, so a Camera, a Metadata record
or an Attachment may legally sit after the Window Table — and a scan that stopped early reported a
scene without them. What a reader says about a file must not depend on where its probe happened to
stop. Pass a larger `probeBytes` to `openFourdgsIndexed` if you know your scenes have big front
matter and would rather spend one bigger request than two.

## Any transport

The decoder needs exactly two things from a resource: how big it is, and the bytes in a range.

```dart
class HttpRangeReadable implements FourdgsReadable {
  @override
  Future<int> size() async => /* HEAD, or Content-Range on the first response */ 0;

  @override
  Future<Uint8List> read(int offset, int length) async =>
      /* GET with Range: bytes=$offset-${offset + length - 1} */ Uint8List(0);
}
```

`FourdgsBytes` wraps a buffer already in memory, and `package:fourdgs/io.dart` has
`FourdgsFileReadable` for a file on disk. Everything else is yours.

## Errors

Everything this package throws is a `FourdgsException`, which extends `FormatException` — so one
`catch` covers the family, and code already written against `FormatException` keeps working. The
subtypes separate the cases worth telling apart: `FourdgsTruncatedFile`,
`FourdgsUnsupportedVersion`, `FourdgsUnsupportedCodec` and `FourdgsMalformedFile`.

## Inspect and validate from a shell

`dart pub global activate fourdgs` puts a `fourdgs` command on the PATH, so a file a Flutter
application will not open can be diagnosed without leaving the toolchain that application is built
in.

```console
$ fourdgs inspect scene.4dgs
      offset  record                    content           total  crc
           0  (magic)                                         8  -
           8  Header                        137             146  -
         154  Quantization                  324             333  -
         487  WindowTable                    20              29  -
         516  Chunk                       1,849           1,858  -
       2,374  ChunkIndex                     40              49  ok
       2,423  Footer                         20              29  -
       2,452  (magic)                                         8  -

6 records, 2,460 bytes
crc: the Footer's summary checksum covers bytes 2,374..2,423; `-` is a record it does not cover

$ fourdgs validate broken.4dgs
error: a chunk does not decode: window index 1 is outside the 1-entry window table
  refusal window-index-out-of-range at byte 2506 (the Chunk record at index entry 1)
INVALID
```

Exit codes, because they are the only part of a tool another program reads: `0` fine, `1` refused or
invalid, `2` valid with warnings, `3` the tool itself could not run — a usage error, an unreadable
path. A tool that exits `1` both for "I read the file and it is not conforming" and for "I fell
over" is indistinguishable from a broken one.

`validate` decodes every chunk and every declared spherical-harmonic band, one at a time, because a
framing walk steps _over_ a chunk by its declared length and an unimplemented stream codec or an
out-of-range window index lives inside one. `inspect` reads nine bytes per record and never touches
a record's content, so it costs the same on a file with an embedded audio track as on one without. A
truncated file is walked as far as it goes and then says where it was cut and how much of it a
streamed reader still recovers.

The same answers are available without the shell: `inspectFourdgs`, `validateFourdgs`,
`walkFourdgsFraming` and `describeFourdgsRefusal` are exported from `package:fourdgs/fourdgs.dart`,
and take a `FourdgsReadable` rather than a path.

### Where this reports less than the Python validator

The findings, their severities and their order are
[`python/fourdgs/fourdgs/validate.py`](https://github.com/avala-ai/4dgs/blob/main/python/fourdgs/fourdgs/validate.py)'s,
and the refusal identifiers and byte offsets are the same in every SDK. Two places where this one
says less, deliberately, rather than saying something different:

- **Non-finite quantization parameters, inverted chunk intervals and malformed Audio Source fields**
  are refused by this package's record parsers rather than reported field by field, because Dart's
  `double.floor()` on a NaN throws from inside arithmetic three call levels below the reader. So a
  file Python reports five findings about arrives here as one `does not parse` error naming the
  record. Same verdict, fewer sentences.
- **The provenance registry checks** — a `metres_per_unit` that disagrees with its declared unit, a
  principal point outside its image — need the parsed provenance records, and are not ported here,
  exactly as they are not ported to the Rust, TypeScript or C++ validators.

## Scope

Decoding ends at reconstructed gaussian state and reconstructed audio-source state at time `t`.
Rendering and spatial audio playback—including listener orientation, HRTF, attenuation, occlusion
and mixing—belong to the renderer/player.

## Conformance

Checked against the same generated corpus every other 4dgs SDK is, on both read paths: 119 checks,
the seven invalid variants included now that a refusal here carries the identifier the suite
compares. See the [feature matrix](https://4dgs.dev/reference/) for what this SDK implements and
what it declines.

## License

[Apache-2.0](LICENSE).
