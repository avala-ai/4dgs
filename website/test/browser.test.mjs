/**
 * The viewer page itself, in a real browser, against the built site.
 *
 * Everything here is a claim that cannot be checked in Node: what is drawn on the canvas,
 * what the transport does, what happens to a page whose browser has no WebGL2, and what the
 * device's texture limit does to a large scene. The site under test is `website/build`, so
 * these run against the bundle that ships, minifier and all.
 *
 * Requires a built site and a Chrome. Both are hard failures rather than skips under CI.
 */

import assert from "node:assert/strict";
import { after, before, describe, it } from "node:test";

import { findChrome, launchChrome, requireBuiltSite, serveSite } from "./support/browser.mjs";

const chromePath = findChrome();
const available = chromePath !== null;
if (available) requireBuiltSite();

const VALID = "TenWindows-UseChunkIndex-UseCrc.4dgs";
const INVALID = "invalid/UnknownTemporalModel.4dgs";

/** Read the page's whole visible state in one round trip. */
function readState() {
  const rows = {};
  for (const dt of document.querySelectorAll("dt")) {
    rows[dt.textContent] = dt.nextElementSibling ? dt.nextElementSibling.textContent : "";
  }
  const buttons = [...document.querySelectorAll("button")];
  const play = buttons.find((b) => b.textContent === "Play" || b.textContent === "Pause");
  const scrub = document.querySelector('input[type="range"]');
  return {
    rows,
    notes: [...document.querySelectorAll("li")].map((li) => li.textContent),
    refusalTitle: document.querySelector("h3") ? document.querySelector("h3").textContent : null,
    refusalBody: document.querySelector("pre") ? document.querySelector("pre").textContent : null,
    sources: [...document.querySelectorAll("p")].map((p) => p.textContent),
    playLabel: play ? play.textContent : null,
    playDisabled: play ? play.disabled : null,
    scrubDisabled: scrub ? scrub.disabled : null,
    scrubValue: scrub ? Number(scrub.value) : null,
    fileDisabled: document.querySelector('input[type="file"]').disabled,
    clock: [...document.querySelectorAll("span")]
      .map((s) => s.textContent)
      .find((text) => / s$/.test(text)),
  };
}

/** Hand the page a corpus file through its own file input, fetched in-page. */
function pickFile(url) {
  return fetch(url)
    .then((response) => response.arrayBuffer())
    .then((bytes) => {
      const file = new File([bytes], url.split("/").pop(), { type: "application/octet-stream" });
      const input = document.querySelector('input[type="file"]');
      const transfer = new DataTransfer();
      transfer.items.add(file);
      input.files = transfer.files;
      input.dispatchEvent(new Event("change", { bubbles: true }));
      return true;
    });
}

/** How much of the canvas is not the clear colour: zero means nothing is drawn. */
function countDrawnPixels() {
  const canvas = document.querySelector("canvas");
  const gl = canvas.getContext("webgl2");
  const w = canvas.width;
  const h = canvas.height;
  const pixels = new Uint8Array(w * h * 4);
  gl.readPixels(0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, pixels);
  let hash = 0;
  let drawn = 0;
  for (let i = 0; i < w * h; i++) {
    const r = pixels[i * 4];
    const g = pixels[i * 4 + 1];
    const b = pixels[i * 4 + 2];
    if (Math.abs(r - pixels[0]) > 2 || Math.abs(g - pixels[1]) > 2 || Math.abs(b - pixels[2]) > 2) {
      drawn++;
      hash = (hash * 31 + i * 7 + r * 3 + g * 5 + b) % 2147483647;
    }
  }
  return { drawn, total: w * h, hash };
}

/**
 * `preserveDrawingBuffer`, so `readPixels` can see what was composited.
 *
 * The page deliberately does not ask for it — it costs a copy per frame — so a test that
 * wants to look at the picture has to ask on its behalf.
 */
const PRESERVE_BUFFER = `
  (() => {
    const real = HTMLCanvasElement.prototype.getContext;
    HTMLCanvasElement.prototype.getContext = function (kind, attributes) {
      if (kind === "webgl2") {
        return real.call(this, kind, Object.assign({}, attributes || {}, {
          preserveDrawingBuffer: true,
        }));
      }
      return real.call(this, kind, attributes);
    };
  })();
`;

/** Make the device's WebGL2 texture limit whatever a test needs it to be. */
const forceTextureLimit = (limit) => `
  (() => {
    const real = WebGL2RenderingContext.prototype.getParameter;
    WebGL2RenderingContext.prototype.getParameter = function (name) {
      if (name === this.MAX_TEXTURE_SIZE) return ${limit};
      return real.call(this, name);
    };
  })();
`;

describe("the viewer in a browser", { skip: available ? false : "no Chrome found" }, () => {
  let chrome;
  let site;

  before(async () => {
    site = await serveSite();
    chrome = await launchChrome(chromePath);
  });

  after(async () => {
    await chrome?.close();
    await site?.close();
  });

  /** A page at /viewer with the given scripts installed before anything runs. */
  async function viewer(...scripts) {
    const page = await chrome.newPage();
    for (const script of scripts) await page.onNewDocument(script);
    await page.goto(`${site.base}/viewer/`);
    return page;
  }

  const opened = () => {
    const live = [...document.querySelectorAll("dt")].find(
      (entry) => entry.textContent === "Live at this instant",
    );
    return (
      live !== undefined &&
      Number(live.nextElementSibling?.textContent.replace(/,/g, "")) > 0 &&
      [...document.querySelectorAll("button")].some((b) => b.textContent === "Play" && !b.disabled)
    );
  };
  const refused = () => document.querySelector("h3") !== null;

  it("opens a corpus file and shows the file's own facts", async () => {
    const page = await viewer();
    await page.waitFor(
      () => {
        const input = document.querySelector('input[type="file"]');
        return input !== null && !input.disabled;
      },
      { what: "the renderer to survive browser startup" },
    );
    await page.evaluate(pickFile, `${site.base}/corpus/${VALID}`);
    await page.waitFor(opened, { what: "a scene with an enabled transport" });
    const state = await page.evaluate(readState);
    assert.equal(state.rows["Temporal model"], "gaussian-birth");
    assert.match(state.rows["Read path"], /^indexed/);
    assert.ok(Number(state.rows["Live at this instant"].replace(/,/g, "")) > 0);
    assert.equal(state.refusalTitle, null);
    await page.close();
  });

  it("prints the decoder's own refusal for an invalid file", async () => {
    const page = await viewer();
    await page.evaluate(pickFile, `${site.base}/corpus/${INVALID}`);
    await page.waitFor(refused, { what: "a refusal panel" });
    const state = await page.evaluate(readState);
    // The type survives minification, which is why it is recovered with `instanceof`.
    assert.equal(state.refusalTitle, "UnsupportedCodec");
    assert.match(state.refusalBody, /temporal model 'frame-sequence'/);
    assert.equal(state.playDisabled, true);
    await page.close();
  });

  it("keeps a WebGL2 failure across an attempt to open a file", async () => {
    const page = await viewer(`
      (() => {
        const real = HTMLCanvasElement.prototype.getContext;
        HTMLCanvasElement.prototype.getContext = function (kind, attributes) {
          if (kind === "webgl2") return null;
          return real.call(this, kind, attributes);
        };
      })();
    `);
    await page.waitFor(refused, { what: "the WebGL2 refusal" });
    const before = await page.evaluate(readState);
    assert.match(before.refusalBody, /WebGL2/);
    assert.equal(before.fileDisabled, true);

    await page.evaluate(pickFile, `${site.base}/corpus/${VALID}`);
    await new Promise((resolve) => setTimeout(resolve, 2500));
    const after = await page.evaluate(readState);
    assert.equal(after.refusalBody, before.refusalBody, "the capability failure must survive");
    assert.equal(after.fileDisabled, true);
    assert.equal(
      Object.keys(after.rows).length,
      0,
      "no scene may be accepted into a page with no render loop",
    );
    await page.close();
  });

  it("clears the canvas when a replacement file is refused", async () => {
    const page = await viewer(PRESERVE_BUFFER);
    await page.evaluate(pickFile, `${site.base}/corpus/${VALID}`);
    await page.waitFor(opened);
    await new Promise((resolve) => setTimeout(resolve, 1200));
    const drawn = await page.evaluate(countDrawnPixels);
    assert.ok(drawn.drawn > 0, "the first file must actually draw something");

    await page.evaluate(pickFile, `${site.base}/corpus/${INVALID}`);
    await page.waitFor(refused);
    await new Promise((resolve) => setTimeout(resolve, 1200));
    const after = await page.evaluate(countDrawnPixels);
    assert.equal(after.drawn, 0, "the previous file's geometry must not survive the refusal");
    await page.close();
  });

  it("does not freeze a new file behind a read left in flight on the old one", async () => {
    const page = await viewer();
    await page.waitFor(() => document.querySelector('input[type="url"]') !== null, {
      what: "the URL control to mount",
    });
    await page.evaluate((href) => {
      const input = document.querySelector('input[type="url"]');
      const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set;
      setter.call(input, href);
      input.dispatchEvent(new Event("input", { bubbles: true }));
      [...document.querySelectorAll("button")].find((b) => b.textContent === "Open URL").click();
      return true;
    }, `${site.base}/slow/${VALID}`);
    await page.waitFor(opened, { what: "the URL-backed scene" });

    // From here the origin answers nothing, and a seek into an unread chunk hangs forever.
    await fetch(`${site.base}/hangnow`);
    await page.evaluate(() => {
      const scrub = document.querySelector('input[type="range"]');
      const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set;
      setter.call(scrub, String(Number(scrub.max) * 0.6));
      scrub.dispatchEvent(new Event("change", { bubbles: true }));
      return true;
    });
    await new Promise((resolve) => setTimeout(resolve, 1500));

    await page.evaluate(pickFile, `${site.base}/corpus/${VALID}`);
    await page.waitFor(
      () =>
        [...document.querySelectorAll("p")].some((p) =>
          p.textContent.includes("read in this page"),
        ) &&
        [...document.querySelectorAll("button")].some(
          (b) => b.textContent === "Play" && !b.disabled,
        ),
      { what: "the local file, open and playable" },
    );
    await page.evaluate(() => {
      [...document.querySelectorAll("button")].find((b) => b.textContent === "Play").click();
      return true;
    });

    const seen = new Set();
    for (let i = 0; i < 5; i++) {
      await new Promise((resolve) => setTimeout(resolve, 700));
      const state = await page.evaluate(readState);
      seen.add(state.rows["Live at this instant"]);
    }
    assert.ok(
      seen.size > 1,
      `the live count never changed (${[...seen].join(", ")}): the replacement is not being framed`,
    );
    await page.close();
  });

  it("plays again when Play is pressed at the end of a scene", async () => {
    const page = await viewer();
    await page.evaluate(pickFile, `${site.base}/corpus/${VALID}`);
    await page.waitFor(opened);
    // Stop looping, seek to the last instant the timeline contains, and press Play.
    await page.evaluate(() => {
      const loop = document.querySelector('input[type="checkbox"]');
      if (loop.checked) loop.click();
      const scrub = document.querySelector('input[type="range"]');
      const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set;
      setter.call(scrub, scrub.max);
      scrub.dispatchEvent(new Event("change", { bubbles: true }));
      return true;
    });
    await new Promise((resolve) => setTimeout(resolve, 500));
    const atEnd = await page.evaluate(readState);
    await page.evaluate(() => {
      [...document.querySelectorAll("button")].find((b) => b.textContent === "Play").click();
      return true;
    });
    await new Promise((resolve) => setTimeout(resolve, 1200));
    const playing = await page.evaluate(readState);
    assert.equal(playing.playLabel, "Pause", "Play at the end must start playing");
    assert.ok(
      playing.scrubValue < atEnd.scrubValue,
      `the clock did not restart: ${atEnd.clock} then ${playing.clock}`,
    );
    await page.close();
  });

  it("draws the same picture when the device forces a narrower texture", async () => {
    const wide = await viewer(PRESERVE_BUFFER);
    await wide.evaluate(pickFile, `${site.base}/corpus/${VALID}`);
    await wide.waitFor(opened);
    await new Promise((resolve) => setTimeout(resolve, 1200));
    const reference = await wide.evaluate(countDrawnPixels);
    await wide.close();

    const narrow = await viewer(PRESERVE_BUFFER, forceTextureLimit(128));
    await narrow.evaluate(pickFile, `${site.base}/corpus/${VALID}`);
    await narrow.waitFor(opened);
    await new Promise((resolve) => setTimeout(resolve, 1200));
    const limited = await narrow.evaluate(countDrawnPixels);
    assert.ok(reference.drawn > 0);
    assert.equal(limited.drawn, reference.drawn, "a narrower texture must not change the picture");
    assert.equal(limited.hash, reference.hash);
    await narrow.close();
  });

  it("refuses a scene past the device's texture limit, naming the count and the limit", async () => {
    // Two texels each way holds one gaussian; any real scene is past it.
    const page = await viewer(forceTextureLimit(2));
    await page.evaluate(pickFile, `${site.base}/corpus/${VALID}`);
    await page.waitFor(refused, { what: "the texture-limit refusal" });
    const state = await page.evaluate(readState);
    assert.match(state.refusalBody, /MAX_TEXTURE_SIZE of 2/);
    assert.match(state.refusalBody, /gaussians alive at one instant/);
    assert.match(state.refusalBody, /The file is fine/);
    await page.close();
  });

  it("surfaces WebGL context loss and rebuilds after restoration", async () => {
    const page = await viewer();
    await page.evaluate(pickFile, `${site.base}/corpus/${VALID}`);
    await page.waitFor(opened);
    const canRestore = await page.evaluate(() => {
      const gl = document.querySelector("canvas").getContext("webgl2");
      const extension = gl.getExtension("WEBGL_lose_context");
      if (extension === null) throw new Error("WEBGL_lose_context is unavailable");
      window.__restoreWebglForTest = () => extension.restoreContext();
      extension.loseContext();
      return true;
    });
    assert.equal(canRestore, true);
    await page.waitFor(refused, { what: "the WebGL context-loss refusal" });
    const lost = await page.evaluate(readState);
    assert.equal(lost.refusalTitle, "ViewerCapabilityError");
    assert.match(lost.refusalBody, /WebGL2 context was lost/);
    assert.equal(lost.fileDisabled, true);

    await page.evaluate(() => window.__restoreWebglForTest());
    await page.waitFor(opened, { what: "the rebuilt renderer" });
    const after = await page.evaluate(readState);
    assert.equal(after.refusalTitle, null);
    assert.equal(after.playDisabled, false);
    await page.close();
  });
});
