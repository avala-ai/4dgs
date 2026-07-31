# 4dgs — Dart

`fourdgs` is a decoder for the `.4dgs` container, written from the specification in pure Dart. Not a
binding: it shares no code with the other SDKs, which is what makes its agreement with them in the
[conformance suite](../tests/conformance/) worth something.

Both read paths pass every variant this SDK declares support for — including the provenance family
(spec section 5.15) — so every decode row in the [feature matrix](../website/docs/reference/index.md)
is filled in from a suite that runs. It declines the object-layer variants and the invalid corpus's
refusal expectations, which is what the remaining `No` cells in that table record.

Scope: decoding a `.4dgs` to gaussian state and audio-source state at a time `t`. **Rendering and
listener-relative spatialization are out of scope — the SDK ends at decoded state.**

```dart
import 'dart:io';
import 'package:fourdgs/fourdgs.dart';

final scene = readFourdgsBytes(File('scene.4dgs').readAsBytesSync());
final live = scene.gaussians.stateAt(1.5); // §3: the window, then the marginal against the cutoff
print('${live.count} gaussians at t=1.5');
for (final source in scene.audioSources) {
  print('${source.name} at ${source.stateAt(1.5).position}');
}
```

Seeking reads the index and then only the ranges an instant needs:

```dart
import 'package:fourdgs/fourdgs.dart';
import 'package:fourdgs/io.dart';

final source = await FourdgsFileReadable.open('scene.4dgs');
final scene = await openFourdgsIndexed(source);
final cost = scene.bytesForTime(1.5);            // what the seek transfers, before asking for it
for (final entry in scene.chunksForTime(1.5)) {
  final chunk = await readFourdgsChunk(source, scene, entry);
}
```

## Pure Dart, and deliberately platform-free

The decoder imports no `dart:io` and nothing from Flutter, so the same code runs on the Dart VM, in
a Flutter app, and compiled to JavaScript or Wasm. The one platform dependency anybody actually
needs — reading a file — lives in a separate library, `package:fourdgs/io.dart`, so importing the
decoder never drags `dart:io` in.

Anything else is a transport, and transports live at the edges: implement `FourdgsReadable`'s two
methods — a size and a byte range — and the indexed path works over HTTP range requests, a cache, or
anything else, with no change to the decoder.

Two details exist because Dart compiles to JavaScript as well as native. `u64` values are read as
two `u32`s, since `ByteData.getUint64` is unsupported on the JS backend and a decoder that used it
would pass every test and then throw in a browser; and a length above 2^53 is refused as corrupt
rather than truncated, because no honest length in this format approaches it.

## Layout

| Path           | What it is                                                           |
| -------------- | -------------------------------------------------------------------- |
| `fourdgs/`     | The published package: `lib/fourdgs.dart`, `lib/io.dart`, `lib/src/` |
| `conformance/` | The two stdout runners the shared harness drives. Not published      |

The changelog is `fourdgs/CHANGELOG.md`, one level deeper than the other languages keep theirs. That
is pub.dev's requirement rather than a preference: it renders the changelog from the package root,
so a file at `dart/CHANGELOG.md` would not be published with the package at all.

## Building and testing

The Dart SDK, 3.7 or newer. It ships with Flutter, so `dart` is already on the path of anyone with
Flutter installed.

```bash
python3 tests/conformance/generate.py   # from the repository root, first
cd dart/fourdgs
dart pub get
dart analyze
dart test
```

The corpus comes first because `test/front_matter_test.dart` decodes real files from it. Those tests
**fail rather than skip** when it is absent — a test that quietly tested nothing is worse than no
test. The rest of the suite needs nothing but the package.

The conformance runners are compiled rather than run from source, so that a machine without a Dart
SDK reports them as _not built_ and skips them instead of failing 79 checks:

```bash
cd dart/conformance
dart pub get
dart compile exe bin/decode_streamed.dart -o build/decode_streamed
dart compile exe bin/decode_indexed.dart  -o build/decode_indexed
python3 ../../tests/conformance/generate.py
python3 ../../tests/conformance/run.py --runner dart
```

## Naming

The package is `fourdgs`, not `4dgs`: a pub.dev package name is a Dart identifier and may not begin
with a digit — the same constraint Cargo and Swift impose. The format, the CLI and the file
extension are always `4dgs`. [RELEASING.md](../RELEASING.md) has the constraint per registry.

Nothing is released yet. See [CHANGELOG.md](CHANGELOG.md).
