# 4dgs — TypeScript

Four packages, split so a browser bundle carries only what a browser needs:

| Package         | Contains                                                                                      |
| --------------- | --------------------------------------------------------------------------------------------- |
| `@4dgs/core`    | The decoder. Depends on the `IReadable` contract and nothing else — no I/O, no platform types |
| `@4dgs/browser` | `BlobReadable` and `HttpRangeReadable`                                                        |
| `@4dgs/nodejs`  | File-handle readable and writable                                                             |
| `@4dgs/codecs`  | Optional codecs kept out of the core so a bundle opts in                                      |

`@4dgs/core` has no dependencies at all: deflate, the format's default codec, is decoded with
`DecompressionStream`, which every runtime this package targets already has.

## Both read paths

```ts
import { audioSourceStateAt, decodeScene, IndexedDecoder } from "@4dgs/core";

// Front to back: works on a pipe, on a file with no index, and on a truncated file.
const scene = await decodeScene(readable, {
  // Each awaited call receives at most one input block. Consume it here; decodeScene
  // retains only the source descriptors.
  onAudioData({ sourceId, offset, bytes, final }) {
    audioSink.write(sourceId, offset, bytes, final);
  },
});
const state = scene.gaussians.stateAt(1.5); // decoding ends here
for (const source of scene.audioSources) {
  const sourceState = audioSourceStateAt(source, 1.5);
}

// Or the index, then only the byte ranges an instant needs.
const seekable = await IndexedDecoder.open(readable);
for (const entry of seekable.chunksForTime(1.5)) {
  const { gaussians } = await seekable.readChunk(entry, { maxShBand: 1 });
}
const sourceDescriptors = await seekable.readAudioSourceDescriptors();
const movingState = await seekable.readAudioSourceState(sourceId, 1.5);
const encodedRange = await seekable.readAudioRange(sourceId, offset, length);
```

Neither is an optimization of the other. `seekable.bytesForTime(t)` says what a seek will transfer
before it transfers it, because whether an instant is cheap to reach is a property of the content
and a caller deserves to know which kind it has.

## Building and testing

The repository uses the package manager its root `package.json` declares.

```bash
corepack enable
yarn install
yarn build                            # tsc -b: typecheck and build, in dependency order
python3 tests/conformance/generate.py # the corpus is generated, never committed
yarn test                             # unit tests
yarn conformance                      # the conformance suite, TypeScript runners
```

The conformance runners live in `typescript/conformance`, which is private and never published.

See the [feature matrix](../website/docs/reference/index.md) for what the suite proves and the
[specification](../website/docs/spec/index.md) for the format.
