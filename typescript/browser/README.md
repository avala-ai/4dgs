# @4dgs/browser

Browser transports for [`@4dgs/core`](https://www.npmjs.com/package/@4dgs/core): the two ways a page
gets bytes to the decoder.

```ts
import { BlobReadable, HttpRangeReadable } from "@4dgs/browser";
import { IndexedDecoder } from "@4dgs/core";

// A file the visitor picked. It never leaves the page.
const local = await IndexedDecoder.open(new BlobReadable(file));

// A URL, read by HTTP range: the index, then only the chunks an instant needs.
const remote = await IndexedDecoder.open(new HttpRangeReadable(url));
```

`HttpRangeReadable` is what makes seeking cheap — a `.4dgs` file names every byte range in its
index, so rendering one instant of a 500 MB scene fetches that instant rather than the scene. The
origin has to honour `Range`; one that answers `200` with the whole body is treated as an error
rather than sliced client-side.

The format's specification, guides and feature matrix are at **[4dgs.dev](https://4dgs.dev)**.

## License

Apache-2.0
