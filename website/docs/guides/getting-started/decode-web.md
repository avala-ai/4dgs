# Decode in a browser

Two packages: `@4dgs/core` decodes, `@4dgs/browser` fetches. The core depends on neither the network
nor the filesystem — it takes anything that can report its size and read a byte range — so the code
below is the same code that runs on a server and in a test over a byte array.

See the [feature matrix](../../reference/index.md) for what the conformance suite proves today.

## Scope

This guide ends where decoding ends: typed arrays of gaussian state at a time `t`, ready to hand to
whatever draws them. Rendering is out of scope for this project — see
[AGENTS.md](https://github.com/avala-ai/4dgs/blob/main/AGENTS.md).

## A whole scene

```ts
import { decodeScene } from "@4dgs/core";
import { HttpRangeReadable } from "@4dgs/browser";

const scene = await decodeScene(new HttpRangeReadable("https://example.com/scene.4dgs"), {
  onAudioData({ sourceId, offset, bytes, final }) {
    audioSink.write(sourceId, offset, bytes, final);
  },
});

console.log(scene.gaussians.count, scene.header.durationSec);

const state = scene.gaussians.stateAt(1.5, scene.header.cutoff);
// state.indices  — which gaussians exist at t = 1.5
// state.centers  — their positions, moved by their own velocity
// state.opacity  — their alpha, faded by their own marginal
```

`decodeScene` reads front to back in bounded blocks and never holds the resource in one piece. A
file that was cut short still decodes: everything complete before the cut is returned, and
`scene.truncated` says the file ended early rather than throwing it away.

Audio is `scene.audioSources`, an array of small descriptors that is empty when audio is absent.
Each descriptor carries independent timing and a fixed or keyframed scene-space pose. `onAudioData`
is awaited for each block-sized encoded payload piece as the front-to-back read passes it, so
`decodeScene` does not retain every source:

```ts
import { audioSourceStateAt } from "@4dgs/core";

for (const source of scene.audioSources) {
  const sourceState = audioSourceStateAt(source, 1.5);
  // sourceState.active, localTime, gain, position, rotation
}
```

The player supplies its listener pose and owns HRTF/panning, attenuation, occlusion and mixing.
Consume or copy each `onAudioData` view before the callback returns. On the indexed path,
`readAudioRange(sourceId, offset, length)` transfers only the requested encoded bytes.

## One instant, not the whole file

A scene fitted from a capture partitions into chunks with their own time ranges, so displaying an
instant reads the index and then only that instant's byte ranges.

```ts
import { IndexedDecoder } from "@4dgs/core";
import { HttpRangeReadable } from "@4dgs/browser";

const scene = await IndexedDecoder.open(new HttpRangeReadable(url));

console.log(scene.bytesForTime(1.5), "bytes to display t = 1.5");

for (const entry of scene.chunksForTime(1.5)) {
  const { gaussians } = await scene.readChunk(entry, { maxShBand: 1 });
}

const descriptors = await scene.readAudioSourceDescriptors();
const sourceState = await scene.readAudioSourceState(sourceId, 1.5);
const encodedBytes = await scene.readAudioRange(sourceId, offset, length);
```

`bytesForTime` is worth asking before `readChunk`. Whether an instant is cheap to reach is a
property of the content, not of the container: gaussians with finite validity windows partition into
many small chunks, while content baked from a temporal field can leave the index with a single entry
that covers the whole timeline. Both are conforming files. Only one of them seeks cheaply, and a
consumer deserves to find out from a number rather than from a download.

`maxShBand` is the same idea for appearance. Each spherical harmonic band has its own byte range, so
a viewer that has decided to evaluate one band never transfers the others.

## A local file

```ts
import { BlobReadable } from "@4dgs/browser";

const scene = await decodeScene(new BlobReadable(fileInput.files[0]));
```

## Codecs

`deflate` is the format's default and needs nothing: the core decodes it with `DecompressionStream`.
A file using `zstd` needs a decompressor supplied explicitly, which keeps it out of bundles that
will never meet one.

```ts
import { DEFAULT_CODECS, decodeScene } from "@4dgs/core";
import { withZstd } from "@4dgs/codecs";

const scene = await decodeScene(readable, { codecs: withZstd(DEFAULT_CODECS) });
```
