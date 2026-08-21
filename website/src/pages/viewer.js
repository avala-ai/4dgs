// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

import Layout from "@theme/Layout";
import React from "react";

const VIEWER = "https://viewer.4dgs.dev";

/**
 * A signpost, because the viewer is not in this repository.
 *
 * Rendering is out of scope here (AGENTS.md §5) — no ordering, culling, device tiering or
 * shader code — so the viewer lives in `avala-ai/4dgs-viewer` and deploys to
 * `viewer.4dgs.dev`. This path existed briefly and is kept so its links resolve.
 */
export default function Viewer() {
  return (
    <Layout title="Viewer" description="The .4dgs viewer lives at viewer.4dgs.dev">
      <main style={{ maxWidth: "42rem", margin: "0 auto", padding: "4rem 1rem" }}>
        <h1>The viewer moved</h1>
        <p>
          It is at <a href={VIEWER}>viewer.4dgs.dev</a> — open a <code>.4dgs</code> file from your
          machine or a URL, and it is drawn in the browser. Local files stay local; there is no
          backend.
        </p>
        <p>
          It lives in <a href="https://github.com/avala-ai/4dgs-viewer">avala-ai/4dgs-viewer</a>{" "}
          rather than here because this repository is the format and its decoders. Decoding ends at
          reconstructed gaussian state; how that state is drawn belongs to whatever draws it.
        </p>
      </main>
    </Layout>
  );
}
