# @4dgs/codecs

Optional stream codecs for [`@4dgs/core`](https://www.npmjs.com/package/@4dgs/core).

A `.4dgs` chunk may compress its attribute streams. `deflate` is decoded by the core using the
platform's own `DecompressionStream`; `zstd` needs a decompressor supplied, which is what this
package is for.

```ts
import { withZstd } from "@4dgs/codecs";
import { DEFAULT_CODECS, IndexedDecoder } from "@4dgs/core";

const scene = await IndexedDecoder.open(source, { codecs: withZstd(DEFAULT_CODECS) });
```

Kept out of the core so that a page decoding uncompressed or `deflate` scenes does not ship a
decompressor it never calls. A file whose codec this build cannot read is named rather than guessed
at.

The format's specification, guides and feature matrix are at **[4dgs.dev](https://4dgs.dev)**.

## License

Apache-2.0
