# Decode in Dart

`fourdgs` is a pure Dart decoder, not a binding: no native library, no `dart:ffi`, nothing to build
before `dart pub get` works. It runs on the Dart VM, inside Flutter, and compiles to JS and Wasm
unchanged, because the decoder never touches a file, a socket, or anything platform-specific — see
the [feature matrix](../../reference/index.md) for what the conformance suite proves today.

```bash
dart pub add fourdgs
```

The package is named `fourdgs` rather than `4dgs` for the same reason the Rust crate and the Swift
package are: a pub.dev name is a Dart identifier, and an identifier cannot begin with a digit. The
format, the CLI and the file extension are always `4dgs`.

## Reading a file needs one more import

`package:fourdgs/fourdgs.dart` is the whole decoder and knows nothing about `dart:io`. Reading a
file from disk is `package:fourdgs/io.dart`, a separate library so that a browser build never pulls
in an import it cannot use:

```dart
import 'package:fourdgs/fourdgs.dart';
import 'package:fourdgs/io.dart';

final file = await FourdgsFileReadable.open('scene.4dgs');
```

## The whole scene, front to back

```dart
import 'dart:io';

final bytes = await File('scene.4dgs').readAsBytes();
final scene = readFourdgsBytes(bytes);

scene.gaussians.count;
scene.header.durationSec;

final state = scene.gaussians.stateAt(1.5, cutoff: scene.header.cutoff);
state.indices;  // which gaussians exist at t = 1.5
state.centers;  // their positions, moved by their own velocity
state.opacity;  // their alpha, faded by their own marginal
```

`readFourdgsBytes` defaults to `recoverTruncated: true`: a file cut short mid-download decodes to
everything complete before the cut, with `scene.truncated` set to say so, rather than throwing away
a mostly-good scene because the last few bytes never arrived. Pass `maxShBand` to stop the decode
short of the file's full spherical-harmonic degree.

## An instant, without reading the file

A scene fitted from a capture partitions into chunks with their own time ranges, so the indexed path
opens a file the way a seeking client does — the Footer, then the index, then only the byte ranges
an instant needs:

```dart
final scene = await openFourdgsIndexed(file);

scene.header.gaussianCount;
scene.bytesForTime(2.5);  // what that seek transfers, before asking for it

for (final entry in scene.chunksForTime(2.5)) {
  final chunk = await readFourdgsChunk(file, scene, entry, maxShBand: 1);
}
```

`bytesForTime` is worth calling before `readFourdgsChunk`. Whether an instant is cheap to reach is a
property of the content, not of the container: gaussians with finite validity windows partition into
many small chunks, while content baked from a temporal field can leave the index with one entry
spanning the whole timeline. Both are conforming files, and only one of them seeks cheaply.

Audio sources are independent and may move on the scene clock. Reading their small descriptors and
reconstructing pose does not transfer encoded audio:

```dart
final sources = await readFourdgsAudioSourceDescriptors(file, scene);
for (final source in sources) {
  final audio = source.stateAt(2.5);
  audio.active;
  audio.localTime;
  audio.position;
  audio.rotation;
}

final packet = await readFourdgsAudioRange(
  file,
  scene,
  sources.first.sourceId,
  0,
  4096,
);
```

The decoder stops at source pose, gain and local playback time. Listener orientation, HRTF, distance
attenuation, occlusion and mixing are renderer/player decisions. Use `readFourdgsAudioSources` when
the complete payloads are wanted.

`readFourdgsCamera`, `readFourdgsMetadata` and `readFourdgsAttachments` similarly fetch deferred
front-matter records by their own byte ranges.

## Where decoding ends

`stateAt` reconstructs indices, centers and opacity at a time — and stops there. The format is
renderer-agnostic and so is this decoder: ordering, culling, level of detail and anything touching a
GPU belong to whatever draws the splats, which is not this package.

## Any transport

Both read paths depend on `FourdgsReadable` — something that can report its size and read a byte
range — and on nothing else:

```dart
abstract class FourdgsReadable {
  Future<int> size();
  Future<Uint8List> read(int offset, int length);
}
```

`FourdgsFileReadable` (in `package:fourdgs/io.dart`) and `FourdgsBytes` ship with the package. An
HTTP range reader is a transport like any other and belongs in the consumer:

```dart
class HttpRangeReadable implements FourdgsReadable {
  HttpRangeReadable(this.url);
  final Uri url;

  @override
  Future<int> size() async {
    // HEAD the resource, or a zero-length ranged GET, and read Content-Range.
    throw UnimplementedError();
  }

  @override
  Future<Uint8List> read(int offset, int length) async {
    // GET with a Range header covering [offset, offset + length).
    // A short read must be reported as a failure — returning fewer bytes than
    // asked for silently is the one behaviour that breaks every caller.
    throw UnimplementedError();
  }
}
```

## Errors

Everything this package throws is a `FourdgsException`, which extends `FormatException`, so one
clause covers the family — and code already written against `FormatException` keeps working:

```dart
try {
  final scene = readFourdgsBytes(bytes);
} on FourdgsException catch (error) {
  // Every way this decoder can refuse a file arrives here, including a corrupt
  // deflate payload: the codec library's own errors are translated, so a caller
  // never has to know which library is underneath.
  stderr.writeln(error);
}
```

`FourdgsMalformedFile` means the bytes are wrong, `FourdgsUnsupportedVersion` and
`FourdgsUnsupportedCodec` mean the file is legal and this build cannot read it, and
`FourdgsTruncatedFile` means it was cut short.
