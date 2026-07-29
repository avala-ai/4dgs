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
attachments are byte ranges until you ask for them — `readFourdgsAudio`, `readFourdgsCamera`,
`readFourdgsMetadata`, `readFourdgsAttachments` — so a scene with a soundtrack costs nothing to open
and a scene without one carries no audio record at all.

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

## Scope

Decoding ends at reconstructed gaussian state at time `t`. How that state is drawn is out of scope,
and nothing here knows or cares.

## Conformance

Checked against the same generated corpus every other 4dgs SDK is, on both read paths: 67 checks.
See the [feature matrix](https://4dgs.dev/reference/) for what this SDK implements and what it
declines.

## License

[Apache-2.0](LICENSE).
