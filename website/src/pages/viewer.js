import BrowserOnly from "@docusaurus/BrowserOnly";
import Link from "@docusaurus/Link";
import Layout from "@theme/Layout";
import React from "react";

import styles from "./viewer.module.css";

const repositoryUrl = "https://github.com/avala-ai/4dgs";
const viewerSourceUrl = `${repositoryUrl}/tree/main/website/src/components/Viewer`;

export default function ViewerPage() {
  return (
    <Layout
      title="Viewer"
      description="Open a .4dgs file in your browser. The file is decoded in the page and is never uploaded."
    >
      <main className="container margin-vert--lg">
        <h1>Viewer</h1>
        <p className={styles.lede}>
          Open a <code>.4dgs</code> file and look at it. Drop one on the canvas, pick one with the
          file picker, or paste a URL.
        </p>

        <p className={styles.privacy}>
          <strong>Nothing is uploaded.</strong> The file is decoded by JavaScript running in this
          tab, using the same <code>@4dgs/core</code> package the command-line tools use. A local
          file is read with <code>BlobReadable</code>, which slices the <code>File</code> object
          your browser already holds; a URL is read with <code>HttpRangeReadable</code>, which
          issues range requests from your browser straight to that URL. This site has no server
          side, sends no telemetry and loads nothing from a third party — so an unreleased scene
          stays on your machine, and you can confirm that in the network panel.
        </p>

        <BrowserOnly fallback={<div className={styles.loading}>Loading the viewer…</div>}>
          {() => {
            const Viewer = require("../components/Viewer").default;
            return <Viewer />;
          }}
        </BrowserOnly>

        <section className={styles.section}>
          <h2>This is a reference renderer, not a fast one</h2>
          <p>
            It is held to the standard the reference decoders are held to: correct, readable, and
            useful as a worked example for somebody writing their own. It is <em>not</em> a
            performance-tuned rasterizer, and it is not a measurement of how fast 4dgs can be drawn.
            Concretely, and on purpose:
          </p>
          <ul>
            <li>
              the back-to-front sort is an ordinary comparison sort in JavaScript, re-run every
              frame;
            </li>
            <li>spherical harmonics are evaluated on the CPU, not in the shader;</li>
            <li>
              every gaussian alive at the instant on screen is drawn — no level of detail, no
              culling beyond the near plane, no budget;
            </li>
            <li>there is no WebAssembly, no GPU radix sort and no worker.</li>
          </ul>
          <p>
            Benchmark your renderer, not this one. The <Link to="/spec/">specification</Link> is
            deliberately renderer-agnostic: decoding ends at gaussian state at a time, and
            everything after that line is a choice this page makes rather than one the format makes.
          </p>
        </section>

        <section className={styles.section}>
          <h2>What it draws</h2>
          <ul>
            <li>
              Position, linear scale, rotation, colour and opacity, projected as screen-space
              gaussians and composited back to front.
            </li>
            <li>
              Spherical harmonics through degree 3, added to the rest colour as the view-dependent
              term. A stored coefficient byte <code>b</code> is the value{" "}
              <code>-4 + b * 8 / 255</code>; <code>step_sh</code> is an encode-side declaration and
              is not applied at decode.
            </li>
            <li>
              The timeline, honouring the format&rsquo;s half-open rules: a gaussian exists over{" "}
              <code>[win_lo, win_hi)</code>, a chunk covers <code>[t0, t1)</code>, and the scene
              clock runs over <code>[0, duration)</code> — the end is never a valid instant.
            </li>
            <li>
              A <code>gaussian-birth</code> file with a Chunk Index is <strong>seeked</strong>: for
              each instant the viewer reads the Footer, then the index, then only the byte ranges
              whose interval contains that instant. The readout under the canvas shows how much of
              the file that actually cost.
            </li>
            <li>
              A <code>keyframe-delta</code> file is composed and then reconstructed at the instant.
            </li>
          </ul>
        </section>

        <section className={styles.section}>
          <h2>What it does not draw</h2>
          <ul>
            <li>
              Audio. The format carries spatial audio sources and this page has no player for them.
            </li>
            <li>
              The object layer: object tracks are decoded by <code>@4dgs/core</code> but this page
              does not compose their poses onto the gaussians that belong to them.
            </li>
            <li>The suggested camera trajectory. The camera here is yours.</li>
            <li>
              Spherical harmonics on a <code>keyframe-delta</code> scene: SH bands live in their own
              records, which that model&rsquo;s read path does not visit.
            </li>
            <li>
              More gaussians at one instant than this device&rsquo;s WebGL texture limit holds —
              every gaussian is drawn from a single texture, so past that limit the page says so by
              name rather than showing you an empty canvas. A renderer that tiles its data across
              several textures has no such ceiling.
            </li>
          </ul>
          <p>
            The format does not impose a handedness or an up axis, so the viewer picks Y-up and lets
            you change it. If a scene looks like it is lying on its side, that is the control to
            reach for.
          </p>
        </section>

        <section className={styles.section}>
          <h2>When a file will not open</h2>
          <p>
            The refusal is printed as the decoder raised it — which byte, which record, which value,
            and what was expected. That is a rule the SDKs in this repository share, and a viewer
            that reduced it to &ldquo;could not open this file&rdquo; would waste the one moment it
            had a broken file in hand. The error type matters too: <code>UnsupportedCodec</code> and{" "}
            <code>UnsupportedVersion</code> mean the file may be perfectly conforming and this build
            cannot read part of it, while <code>MalformedFile</code> means the bytes are wrong and{" "}
            <code>TruncatedFile</code> means they ran out.
          </p>
        </section>

        <section className={styles.section}>
          <h2>Controls</h2>
          <ul>
            <li>Drag to orbit, wheel to dolly, shift-drag or right-drag to pan.</li>
            <li>Play, pause and scrub the scene clock with the transport under the canvas.</li>
          </ul>
        </section>

        <section className={styles.section}>
          <h2>Licence</h2>
          <p>
            The viewer on this page is part of this repository and is licensed under{" "}
            <Link to={`${repositoryUrl}/blob/main/LICENSE`}>Apache-2.0</Link>, the same licence as
            the specification and the SDKs. Copy it, cut it down, or use it as the thing you write
            yours against — <Link to={viewerSourceUrl}>the source is about six hundred lines</Link>{" "}
            and every format-facing decision in it is a call into <code>@4dgs/core</code>.
          </p>
        </section>
      </main>
    </Layout>
  );
}
