# @4dgs/core

The 4dgs decoder. No I/O: everything comes through `IReadable`, so the same code runs in a browser,
on a server, and in a test over a byte array.

```ts
export interface IReadable {
  size(): Promise<bigint>;
  read(offset: bigint, length: bigint): Promise<Uint8Array>;
}
```

See the [root README](../../README.md) for concepts and the
[specification](../../website/docs/spec/index.md) for the format.
