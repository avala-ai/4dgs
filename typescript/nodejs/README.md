# @4dgs/nodejs

The `4dgs` command-line tool, and Node transports for
[`@4dgs/core`](https://www.npmjs.com/package/@4dgs/core).

```sh
npx @4dgs/nodejs 4dgs inspect scene.4dgs
npx @4dgs/nodejs 4dgs validate scene.4dgs
```

`inspect` reports what a file declares — header, chunk intervals, what an instant costs to seek.
`validate` decodes it and names the first thing that is wrong, with the byte it is at.

```ts
import { FileHandleReadable } from "@4dgs/nodejs";
import { IndexedDecoder } from "@4dgs/core";

const source = await FileHandleReadable.open("scene.4dgs");
const scene = await IndexedDecoder.open(source);
```

`FileHandleReadable` opens once and issues positioned reads, so an indexed decode costs the ranges
it asks for rather than the file.

The format's specification, guides and feature matrix are at **[4dgs.dev](https://4dgs.dev)**.

## License

Apache-2.0
