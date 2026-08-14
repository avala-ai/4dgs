import Link from "@docusaurus/Link";
import Layout from "@theme/Layout";
import React from "react";

import styles from "./index.module.css";

// Each point restates something the specification's own design goals section states.
// Nothing here claims a capability the spec or the feature matrix does not.
const properties = [
  {
    title: "One resource",
    body: "A whole scene — geometry, appearance, motion, audio and camera — is one file, one URL, one cache entry.",
  },
  {
    title: "Continuous time",
    body: "Each gaussian carries its own birth time, temporal extent, motion and validity window, so the number of live gaussians varies over time with no frame machinery.",
  },
  {
    title: "Seekable without a sidecar",
    body: "A byte-range index maps time to chunks. Displaying an arbitrary instant reads the file's own index and then only the ranges that instant needs.",
  },
  {
    title: "Bounded memory",
    body: "Every read path is streamable. No conforming reader ever needs the whole file resident, on any path.",
  },
  {
    title: "Native spatial audio",
    body: "Independent sources carry encoded audio, timing, gain and fixed or moving 3D poses. The scene clock stays authoritative; a scene without audio carries nothing at all.",
  },
  {
    title: "Forward compatible by construction",
    body: "Every top-level structure is a length-prefixed, opcode-tagged record, so a reader skips what it does not recognize instead of failing.",
  },
  {
    title: "Stated error bounds",
    body: "Lossy encodings declare, per attribute, the maximum deviation a decoder may observe, and the encoder is expected to verify it.",
  },
  {
    title: "Renderer-agnostic",
    body: "The format reconstructs gaussian and audio-source state at a given time. Drawing, listener pose, HRTF, attenuation and mixing stay in the renderer/player.",
  },
];

const languages = [
  { name: "Python", to: "/guides/getting-started/encode-python" },
  { name: "TypeScript", to: "/guides/getting-started/decode-web" },
  { name: "Rust", to: "/guides/getting-started/decode-rust" },
  { name: "C++", to: "/guides/getting-started/decode-cpp" },
  { name: "Swift", to: "/guides/getting-started/decode-swift" },
];

export default function Home() {
  return (
    <Layout
      title="4dgs"
      description="An open container format for 4D gaussian splat scenes: continuous time, seekable byte ranges, streaming and indexed reads, and native multi-source spatial audio."
    >
      <header className={styles.hero}>
        <div className="container">
          <h1 className={styles.heroTitle}>
            <span aria-hidden="true">🧊</span> .4dgs
          </h1>
          <p className={styles.heroSubtitle}>
            An open container format for 4D gaussian splat scenes — gaussians whose position,
            opacity and existence vary continuously over time, optionally with native spatial audio
            sources whose 3D poses can move over time, plus a default camera trajectory.
          </p>
          <p className={styles.heroDetail}>
            One self-contained, seekable file. Length-prefixed records, temporal chunking, streaming
            and indexed reads, and SDKs in five languages held to a shared conformance suite.
            Apache-2.0.
          </p>
          <div className={styles.buttons}>
            <Link className="button button--primary button--lg" to="/guides/">
              Read the guides
            </Link>
            <Link className="button button--secondary button--lg" to="/spec/">
              Read the specification
            </Link>
          </div>
        </div>
      </header>

      <main>
        <section className={styles.section}>
          <div className="container">
            <h2 className={styles.sectionTitle}>Why the format looks the way it does</h2>
            <div className={styles.grid}>
              {properties.map((property) => (
                <div className={styles.item} key={property.title}>
                  <h3>{property.title}</h3>
                  <p>{property.body}</p>
                </div>
              ))}
            </div>
          </div>
        </section>

        <section className={styles.section}>
          <div className="container">
            <h2 className={styles.sectionTitle}>SDKs</h2>
            <div className={styles.languages}>
              {languages.map((language) => (
                <Link className={styles.language} key={language.name} to={language.to}>
                  {language.name}
                </Link>
              ))}
            </div>
            <p>
              Support is stated per feature, not per language: the{" "}
              <Link to="/reference/">feature support matrix</Link> records only what the{" "}
              <Link to="/reference/conformance">conformance suite</Link> proves, and a partial SDK
              is a documented state rather than a defect.
            </p>
          </div>
        </section>
      </main>
    </Layout>
  );
}
