# 4dgs — TypeScript

Four packages, split so a browser bundle carries only what a browser needs:

| Package | Contains |
|---|---|
| `@4dgs/core` | The decoder. Depends on the `IReadable` contract and nothing else — no I/O, no platform types |
| `@4dgs/browser` | `BlobReadable` and `HttpRangeReadable` |
| `@4dgs/nodejs` | File-handle readable and writable |
| `@4dgs/codecs` | Optional codecs kept out of the core so a bundle opts in |

In progress. See the [feature matrix](../website/docs/reference/index.md) for status and
the [specification](../website/docs/spec/index.md) for the format.
