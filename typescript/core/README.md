# @4dgs/core

The 4dgs decoder. No I/O: everything comes through `IReadable`, so the same code runs in a browser,
on a server, and in a test over a byte array.

```ts
export interface IReadable {
  size(): Promise<bigint>;
  read(offset: bigint, length: bigint): Promise<Uint8Array>;
}
```

`IndexedDecoder` reads the index once, then only what an instant needs:

```ts
import { IndexedDecoder } from "@4dgs/core";

const scene = await IndexedDecoder.open(source);

// What does one instant cost, before paying for it?
scene.bytesForTime(1.5);

// Every chunk whose [t0, t1) contains the instant.
for (const entry of scene.chunksForTime(1.5)) {
  const chunk = await scene.readChunk(entry);
}
```

A transport goes in the `source`: [`@4dgs/browser`](https://www.npmjs.com/package/@4dgs/browser) for
a picked file or an HTTP range, [`@4dgs/nodejs`](https://www.npmjs.com/package/@4dgs/nodejs) for a
file handle. `BytesReadable` is built in, for bytes you already hold.

The format's specification, guides and feature matrix are at **[4dgs.dev](https://4dgs.dev)**.

## License

Apache-2.0
