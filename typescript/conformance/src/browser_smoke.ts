// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * The browser smoke test: a real Chrome, a real HTTP server, real range requests.
 *
 * Node can prove the decoder decodes. It cannot prove the two things a browser build
 * actually depends on: that the browser's own `DecompressionStream` inflates these
 * streams, and that `HttpRangeReadable` gets what it asked for from a server answering
 * `206 Partial Content`. Both are exercised here and nowhere else.
 *
 * No browser automation dependency. Chrome is driven over the DevTools protocol with the
 * WebSocket client Node already has, and the page is served by `node:http`. The whole
 * harness is the standard library plus a browser the runner already has installed, which
 * is the same reason the decoder itself has no dependencies.
 *
 *     node typescript/conformance/dist/browser_smoke.js
 *
 * Set `CHROME` to point at a binary if the usual names are not on PATH.
 */

import { spawn, type ChildProcess } from "node:child_process";
import { createReadStream, existsSync, statSync } from "node:fs";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = fileURLToPath(new URL("../../../", import.meta.url));

/**
 * Three variants: the simple case, one with harmonics, chunks and quantization, and one
 * whose gaussians share positions — the browser assembles chunks itself over the range
 * transport, so the ordering rule is worth holding on this path too and not only in Node.
 */
const VARIANTS = [
  "OneWindow-UseChunkIndex-UseCrc-WithCamera-WithMetadata-WithSpatialAudio",
  "MixedLifetimes-Quantized-SHDegree2-UseChunkIndex-UseChunks-UseCrc",
  "RepeatedPositions-SHDegree2-UseChunkIndex-UseChunks-UseCrc",
];

const CHROME_NAMES = [
  process.env["CHROME"],
  "google-chrome",
  "google-chrome-stable",
  "chromium",
  "chromium-browser",
].filter((name): name is string => typeof name === "string" && name.length > 0);

const MOUNTS: [string, string][] = [
  ["/core/", join(ROOT, "typescript/core/dist/")],
  ["/browser/", join(ROOT, "typescript/browser/dist/")],
  ["/conformance/", join(ROOT, "typescript/conformance/dist/")],
  ["/data/", join(ROOT, "tests/conformance/data/")],
];

const PAGE = `<!doctype html>
<meta charset="utf-8">
<title>4dgs browser smoke test</title>
<script type="importmap">
  {
    "imports": {
      "@4dgs/core": "/core/index.js",
      "@4dgs/browser": "/browser/index.js"
    }
  }
</script>
<script type="module">
  import "/conformance/browser_page.js";
  window.fourdgsReady = true;
</script>
<p>Decoding happens in the console.</p>
`;

function contentType(path: string): string {
  if (path.endsWith(".js")) return "text/javascript; charset=utf-8";
  if (path.endsWith(".json")) return "application/json; charset=utf-8";
  return "application/octet-stream";
}

/**
 * A static server that answers range requests properly.
 *
 * Serving `206` with a correct `Content-Range` is not incidental to this test — it is
 * half of what is under test, because a transport that asks for a range is only correct
 * against a server that honours one.
 */
function serve(): Promise<{ server: Server; port: number }> {
  const server = createServer((request: IncomingMessage, response: ServerResponse) => {
    const url = request.url ?? "/";
    if (url === "/" || url === "/index.html") {
      response.writeHead(200, { "content-type": "text/html; charset=utf-8" });
      response.end(PAGE);
      return;
    }
    const mount = MOUNTS.find(([prefix]) => url.startsWith(prefix));
    if (!mount) {
      response.writeHead(404).end();
      return;
    }
    const path = join(mount[1], url.slice(mount[0].length));
    if (!path.startsWith(mount[1]) || !existsSync(path)) {
      response.writeHead(404).end();
      return;
    }
    const size = statSync(path).size;
    const range = /^bytes=(\d+)-(\d+)$/.exec(request.headers.range ?? "");
    if (range) {
      const from = Number(range[1]);
      const to = Math.min(Number(range[2]), size - 1);
      response.writeHead(206, {
        "content-type": contentType(path),
        "content-range": `bytes ${from}-${to}/${size}`,
        "content-length": String(to - from + 1),
        "accept-ranges": "bytes",
      });
      createReadStream(path, { start: from, end: to }).pipe(response);
      return;
    }
    response.writeHead(200, {
      "content-type": contentType(path),
      "content-length": String(size),
      "accept-ranges": "bytes",
    });
    createReadStream(path).pipe(response);
  });
  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      resolve({ server, port: typeof address === "object" && address ? address.port : 0 });
    });
  });
}

/** Start Chrome headless and wait for it to say where its debugger is listening. */
async function launchChrome(profile: string): Promise<{ child: ChildProcess; endpoint: string }> {
  let lastError = "";
  for (const binary of CHROME_NAMES) {
    const child = spawn(
      binary,
      [
        "--headless=new",
        "--disable-gpu",
        "--no-sandbox",
        "--disable-dev-shm-usage",
        "--remote-debugging-port=0",
        `--user-data-dir=${profile}`,
        "about:blank",
      ],
      { stdio: ["ignore", "ignore", "pipe"] },
    );
    const endpoint = await new Promise<string>((resolve) => {
      let buffered = "";
      const timer = setTimeout(() => resolve(""), 20000);
      child.stderr?.on("data", (chunk: Buffer) => {
        buffered += chunk.toString();
        const found = /DevTools listening on (ws:\/\/\S+)/.exec(buffered);
        if (found) {
          clearTimeout(timer);
          resolve(found[1]!);
        }
      });
      child.on("error", () => {
        clearTimeout(timer);
        resolve("");
      });
      child.on("exit", () => {
        clearTimeout(timer);
        resolve("");
      });
    });
    if (endpoint) return { child, endpoint };
    lastError = `${binary} did not report a debugging endpoint`;
    child.kill("SIGKILL");
  }
  throw new Error(
    `no usable Chrome found (tried ${CHROME_NAMES.join(", ")}). ${lastError}. ` +
      "Set CHROME to a binary path.",
  );
}

/** The page target Chrome opened for itself, once it exists. */
async function findPageTarget(debugPort: string): Promise<string> {
  for (let attempt = 0; attempt < 60; attempt++) {
    try {
      const response = await fetch(`http://127.0.0.1:${debugPort}/json/list`);
      const targets = (await response.json()) as { type: string; webSocketDebuggerUrl?: string }[];
      const page = targets.find((one) => one.type === "page" && one.webSocketDebuggerUrl);
      if (page?.webSocketDebuggerUrl) return page.webSocketDebuggerUrl;
    } catch {
      // Chrome is still starting; the endpoint exists before the list does.
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error("Chrome never opened a page target");
}

/** The smallest DevTools client that can open a page and evaluate one expression. */
class Devtools {
  private next = 1;
  private readonly pending = new Map<number, (result: Record<string, unknown>) => void>();

  private constructor(private readonly socket: WebSocket) {}

  static connect(endpoint: string): Promise<Devtools> {
    return new Promise((resolve, reject) => {
      const socket = new WebSocket(endpoint);
      const client = new Devtools(socket);
      socket.addEventListener("message", (event) => client.receive(String(event.data)));
      socket.addEventListener("open", () => resolve(client));
      socket.addEventListener("error", () => reject(new Error(`cannot connect to ${endpoint}`)));
    });
  }

  /** Resolve when the page reports an event, or after `ms`. */
  waitFor(event: string, ms: number): Promise<void> {
    return new Promise((resolve) => {
      const timer = setTimeout(resolve, ms);
      const handler = (message: MessageEvent) => {
        if ((JSON.parse(String(message.data)) as { method?: string }).method === event) {
          clearTimeout(timer);
          this.socket.removeEventListener("message", handler);
          resolve();
        }
      };
      this.socket.addEventListener("message", handler);
    });
  }

  private receive(raw: string): void {
    const message = JSON.parse(raw) as {
      id?: number;
      result?: Record<string, unknown>;
      error?: unknown;
    };
    if (typeof message.id === "number") {
      const waiting = this.pending.get(message.id);
      this.pending.delete(message.id);
      if (waiting) waiting({ result: message.result, error: message.error });
    }
  }

  send(method: string, params: Record<string, unknown> = {}): Promise<Record<string, unknown>> {
    const id = this.next++;
    const frame: Record<string, unknown> = { id, method, params };
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`${method} timed out`)), 60000);
      this.pending.set(id, (message) => {
        clearTimeout(timer);
        if (message["error"]) reject(new Error(`${method}: ${JSON.stringify(message["error"])}`));
        else resolve((message["result"] ?? {}) as Record<string, unknown>);
      });
      this.socket.send(JSON.stringify(frame));
    });
  }

  close(): void {
    this.socket.close();
  }
}

interface PageResult {
  variant: string;
  path: string;
  ok: boolean;
  detail: string;
}

async function main(): Promise<number> {
  for (const variant of VARIANTS) {
    if (!existsSync(join(ROOT, "tests/conformance/data", `${variant}.4dgs`))) {
      process.stderr.write(`missing ${variant}.4dgs — run tests/conformance/generate.py first\n`);
      return 1;
    }
  }
  if (!existsSync(join(ROOT, "typescript/core/dist/index.js"))) {
    process.stderr.write("the packages are not built — run `yarn build` first\n");
    return 1;
  }

  const { server, port } = await serve();
  const profile = await mkdtemp(join(tmpdir(), "fourdgs-chrome-"));
  let chrome: { child: ChildProcess; endpoint: string } | null = null;
  let devtools: Devtools | null = null;
  try {
    chrome = await launchChrome(profile);
    // Attach to the tab Chrome already opened and navigate it, rather than creating a
    // target and hoping it loads: a created target reports the URL it intends to visit
    // before it has fetched anything, which makes "is it loaded yet" unanswerable.
    const target = await findPageTarget(new URL(chrome.endpoint).port);
    devtools = await Devtools.connect(target);
    await devtools.send("Page.enable");
    await devtools.send("Runtime.enable");
    const loaded = devtools.waitFor("Page.loadEventFired", 30000);
    await devtools.send("Page.navigate", { url: `http://127.0.0.1:${port}/` });
    await loaded;

    // The module the page imports loads asynchronously; wait for it to announce itself
    // rather than guessing at a delay.
    const expression = `
      (async () => {
        for (let i = 0; i < 200 && !window.fourdgsSmokeTest; i++) {
          await new Promise((r) => setTimeout(r, 50));
        }
        if (!window.fourdgsSmokeTest) throw new Error("the page module never loaded");
        return JSON.stringify(await window.fourdgsSmokeTest(${JSON.stringify(VARIANTS)}));
      })()`;
    const evaluated = await devtools.send("Runtime.evaluate", {
      expression,
      awaitPromise: true,
      returnByValue: true,
    });
    const exception = evaluated["exceptionDetails"] as
      { text?: string; exception?: { description?: string } } | undefined;
    if (exception) {
      process.stderr.write(`page threw: ${exception.exception?.description ?? exception.text}\n`);
      return 1;
    }

    const results = JSON.parse((evaluated["result"] as { value: string }).value) as PageResult[];
    let failed = 0;
    for (const one of results) {
      const status = one.ok ? "ok  " : "FAIL";
      process.stdout.write(`${status} ${one.path.padEnd(18)} ${one.variant}\n     ${one.detail}\n`);
      if (!one.ok) failed++;
    }
    const version = await devtools.send("Browser.getVersion");
    process.stdout.write(
      `\n${results.length - failed}/${results.length} passed in ${version["product"]}\n`,
    );
    return failed === 0 ? 0 : 1;
  } finally {
    devtools?.close();
    if (chrome) {
      // The kill returns before the process dies, and Chrome keeps writing to its
      // profile while it goes down — removing the directory at that moment is a
      // teardown race that fails a run whose assertions all passed. Wait for the
      // exit event (bounded, in case it already fired), then remove with retries
      // for whatever the filesystem is still settling.
      const child = chrome.child;
      const gone =
        child.exitCode !== null
          ? Promise.resolve()
          : new Promise<void>((resolve) => {
              child.once("exit", () => resolve());
              setTimeout(resolve, 5000).unref();
            });
      child.kill("SIGKILL");
      await gone;
    }
    server.close();
    await rm(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  }
}

process.exitCode = await main();
