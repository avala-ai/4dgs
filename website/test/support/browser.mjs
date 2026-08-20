/**
 * A headless Chrome, driven over the DevTools protocol, with no dependencies.
 *
 * The viewer's transport, its refusal panel and its WebGL limits are only observable in a
 * browser, so those tests need one. Chrome is spawned and spoken to over the protocol
 * directly — Node has had a WebSocket client since 22 — rather than pulling a driver into
 * this repository's dependency graph for one page's tests.
 */

import { spawn } from "node:child_process";
import { createReadStream, existsSync, readFileSync, statSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import http from "node:http";
import { tmpdir } from "node:os";
import path from "node:path";

import { CORPUS, REPO_ROOT } from "./corpus.mjs";

const SITE = path.join(REPO_ROOT, "website/build");

const CHROMES = [
  process.env.CHROME_PATH,
  "/usr/bin/google-chrome",
  "/usr/bin/google-chrome-stable",
  "/usr/bin/chromium",
  "/usr/bin/chromium-browser",
  "/snap/bin/chromium",
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
];

/**
 * The Chrome to drive, or `null` when there is none.
 *
 * Under CI this is an error rather than a `null`: a browser suite that quietly finds no
 * browser and reports success is the failure mode these tests exist to avoid.
 */
export function findChrome() {
  for (const candidate of CHROMES) {
    if (candidate !== undefined && candidate !== "" && existsSync(candidate)) return candidate;
  }
  if (process.env.CI) {
    throw new Error(
      `no Chrome found for the viewer's browser tests. Tried: ${CHROMES.filter(Boolean).join(", ")}. ` +
        "Set CHROME_PATH.",
    );
  }
  return null;
}

/** The built site must exist; these tests are about what ships, not about the sources. */
export function requireBuiltSite() {
  if (!existsSync(path.join(SITE, "viewer", "index.html"))) {
    throw new Error(
      `the site is not built at ${SITE}. Build it first:\n    yarn workspace website build`,
    );
  }
}

const MIME = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".css": "text/css",
  ".json": "application/json",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".ico": "image/x-icon",
  ".woff2": "font/woff2",
  ".4dgs": "application/octet-stream",
};

/**
 * Serves the built site and the corpus.
 *
 * `/corpus/…` is an ordinary file, for the file picker. `/slow/…` is the same file over
 * byte ranges, and stops answering the moment `/hangnow` is fetched — which is how a test
 * leaves an indexed read in flight forever.
 */
export async function serveSite() {
  let hanging = false;
  const server = http.createServer((request, response) => {
    const url = new URL(request.url, "http://localhost");
    if (url.pathname === "/hangnow") {
      hanging = true;
      response.writeHead(200).end("ok");
      return;
    }
    if (url.pathname.startsWith("/slow/")) {
      if (hanging) return; // deliberately never answers
      serveRange(path.join(CORPUS, url.pathname.slice("/slow/".length)), request, response);
      return;
    }
    let file = url.pathname.startsWith("/corpus/")
      ? path.join(CORPUS, url.pathname.slice("/corpus/".length))
      : path.join(SITE, url.pathname);
    try {
      if (statSync(file).isDirectory()) file = path.join(file, "index.html");
    } catch {
      response.writeHead(404).end("not found");
      return;
    }
    response.writeHead(200, {
      "content-type": MIME[path.extname(file)] ?? "application/octet-stream",
      "accept-ranges": "bytes",
    });
    createReadStream(file).pipe(response);
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return {
    base: `http://127.0.0.1:${server.address().port}`,
    close: () => new Promise((resolve) => server.close(resolve)),
  };
}

function serveRange(file, request, response) {
  let size;
  try {
    size = statSync(file).size;
  } catch {
    response.writeHead(404).end("not found");
    return;
  }
  const bytes = readFileSync(file);
  const match = /bytes=(\d+)-(\d*)/.exec(request.headers.range ?? "");
  if (match === null) {
    response.writeHead(200, { "content-length": String(size), "accept-ranges": "bytes" });
    response.end(bytes);
    return;
  }
  const start = Number(match[1]);
  const end = match[2] === "" ? size - 1 : Number(match[2]);
  const slice = bytes.subarray(start, end + 1);
  response.writeHead(206, {
    "content-range": `bytes ${start}-${end}/${size}`,
    "content-length": String(slice.length),
    "accept-ranges": "bytes",
  });
  response.end(slice);
}

/** Launch Chrome and connect to its browser-level DevTools endpoint. */
export async function launchChrome(executable) {
  const profile = await mkdtemp(path.join(tmpdir(), "4dgs-viewer-test-"));
  const child = spawn(
    executable,
    [
      "--headless=new",
      "--remote-debugging-port=0",
      `--user-data-dir=${profile}`,
      "--no-sandbox",
      "--disable-gpu-sandbox",
      "--disable-dev-shm-usage",
      // SwiftShader, so WebGL2 exists on a machine with no GPU. The viewer is a reference
      // renderer; what is under test is what it computes, not how fast.
      "--use-gl=swiftshader",
      "--enable-unsafe-swiftshader",
      "about:blank",
    ],
    { stdio: ["ignore", "pipe", "pipe"] },
  );

  const endpoint = await new Promise((resolve, reject) => {
    let buffer = "";
    const timer = setTimeout(
      () => reject(new Error(`Chrome did not report a port:\n${buffer}`)),
      30000,
    );
    child.stderr.on("data", (chunk) => {
      buffer += chunk;
      const found = /ws:\/\/[^\s]+/.exec(buffer);
      if (found !== null) {
        clearTimeout(timer);
        resolve(found[0]);
      }
    });
    child.on("exit", (code) => reject(new Error(`Chrome exited with ${code}:\n${buffer}`)));
  });

  const socket = new WebSocket(endpoint);
  await new Promise((resolve, reject) => {
    socket.addEventListener("open", resolve, { once: true });
    socket.addEventListener("error", reject, { once: true });
  });

  let nextId = 1;
  const pending = new Map();
  socket.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    const waiter = pending.get(message.id);
    if (waiter === undefined) return;
    pending.delete(message.id);
    if (message.error)
      waiter.reject(new Error(`${message.error.message} (${JSON.stringify(message.error)})`));
    else waiter.resolve(message.result);
  });

  const send = (method, params = {}, sessionId) =>
    new Promise((resolve, reject) => {
      const id = nextId++;
      pending.set(id, { resolve, reject });
      socket.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
    });

  return {
    send,
    async newPage() {
      const { targetId } = await send("Target.createTarget", { url: "about:blank" });
      const { sessionId } = await send("Target.attachToTarget", { targetId, flatten: true });
      await send("Page.enable", {}, sessionId);
      await send("Runtime.enable", {}, sessionId);
      return makePage(send, sessionId, targetId);
    },
    async close() {
      try {
        socket.close();
      } catch {
        /* already gone */
      }
      child.kill("SIGKILL");
      // Chrome is still letting go of its profile; failing to delete a temporary directory
      // is not a test result.
      await rm(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 }).catch(
        () => {},
      );
    },
  };
}

function makePage(send, sessionId, targetId) {
  const page = {
    async onNewDocument(source) {
      await send("Page.addScriptToEvaluateOnNewDocument", { source }, sessionId);
    },
    async goto(url) {
      await send("Page.navigate", { url }, sessionId);
      await page.waitFor(() => document.readyState === "complete");
      // `readyState === "complete"` means the document and its subresources loaded, which
      // on a Docusaurus page is BEFORE React has hydrated: the server-rendered markup is
      // there, the interactive controls are not. A test that starts driving at that point
      // races hydration and fails on whichever machine is slow enough that day — locally
      // it never lost, in CI it lost about a third of the time, with
      // `Cannot set properties of null (setting 'files')` from a file input that had not
      // been mounted yet.
      //
      // Waiting for the control itself rather than for a timeout: the page is ready when
      // the thing under test exists, and nothing else is a proxy for that.
      await page.waitFor(() => document.querySelector('input[type="file"]') !== null, {
        what: "the viewer's file input to hydrate",
      });
    },
    /** Evaluate `fn(...args)` in the page and return its value. */
    async evaluate(fn, ...args) {
      const expression = `(${fn.toString()})(${args.map((a) => JSON.stringify(a)).join(", ")})`;
      const result = await send(
        "Runtime.evaluate",
        { expression, awaitPromise: true, returnByValue: true },
        sessionId,
      );
      if (result.exceptionDetails) {
        throw new Error(
          `page threw: ${result.exceptionDetails.exception?.description ?? result.exceptionDetails.text}`,
        );
      }
      return result.result.value;
    },
    /** Poll `fn` in the page until it returns true, or fail with what it last saw. */
    async waitFor(fn, { timeout = 30000, what = fn.toString() } = {}) {
      const deadline = Date.now() + timeout;
      for (;;) {
        if (await page.evaluate(fn)) return;
        if (Date.now() > deadline) throw new Error(`timed out waiting for: ${what}`);
        await new Promise((resolve) => setTimeout(resolve, 100));
      }
    },
    async close() {
      await send("Target.closeTarget", { targetId });
    },
  };
  return page;
}
