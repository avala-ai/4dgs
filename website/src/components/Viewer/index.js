/**
 * The viewer: a drop target, a canvas, a transport control and a refusal panel.
 *
 * The file never leaves the page. `BlobReadable` slices a local `File`; `HttpRangeReadable`
 * range-reads a URL the visitor pastes. Neither one posts anything anywhere, and there is
 * no server side to this page to post it to.
 */

import { BlobReadable, HttpRangeReadable } from "@4dgs/browser";
import {
  FourdgsError,
  MalformedFile,
  TruncatedFile,
  UnsupportedCodec,
  UnsupportedVersion,
} from "@4dgs/core";
import React, { useCallback, useEffect, useRef, useState } from "react";

import { OrbitCamera, boundsOf } from "./camera.js";
import { openScene } from "./openScene.js";
import { SplatRenderer } from "./renderer.js";
import styles from "./styles.module.css";

/** Times to try when looking for a non-empty instant to frame the camera on. */
const FRAMING_PROBES = [0, 0.25, 0.5, 0.75, 0.999];

/** How often the readouts under the canvas are allowed to re-render, in milliseconds. */
const READOUT_INTERVAL = 100;

export default function Viewer() {
  const canvasRef = useRef(null);
  const rendererRef = useRef(null);
  const cameraRef = useRef(null);
  /** Everything the animation loop reads and writes without re-rendering React. */
  const playbackRef = useRef({ playable: null, time: 0, playing: false, loop: true, serial: 0 });
  const dragRef = useRef(null);
  /** True only between pointer-down and pointer-up on the scrubber. */
  const draggingScrubRef = useRef(false);

  const [source, setSource] = useState(null);
  const [scene, setScene] = useState(null);
  const [error, setError] = useState(null);
  const [busy, setBusy] = useState(false);
  const [dragging, setDragging] = useState(false);
  const [url, setUrl] = useState("");
  const [upAxis, setUpAxis] = useState("y");
  const [playing, setPlaying] = useState(false);
  const [loop, setLoop] = useState(true);
  /**
   * Set when an instant refuses to decode, which retires the file.
   *
   * The scene's facts stay on the page — they are still true of the file, and they are half
   * of the diagnosis next to the refusal — but nothing is left to play, so the transport
   * says so by being disabled rather than by accepting clicks and ignoring them.
   */
  const [decodeFailed, setDecodeFailed] = useState(false);
  /** Non-null while the visitor is dragging the scrubber, so the readout cannot fight it. */
  const [scrub, setScrub] = useState(null);
  const [readout, setReadout] = useState({ time: 0, count: 0, intervals: [], transfer: null });

  // --- the render loop -----------------------------------------------------

  useEffect(() => {
    const canvas = canvasRef.current;
    if (canvas === null) return undefined;
    let renderer;
    try {
      renderer = new SplatRenderer(canvas);
    } catch (failure) {
      setError(failure);
      return undefined;
    }
    rendererRef.current = renderer;
    cameraRef.current = new OrbitCamera();

    let running = true;
    let previous = performance.now();
    let lastReadout = 0;
    let pending = false;

    const tick = (now) => {
      if (!running) return;
      const dt = Math.min((now - previous) / 1000, 0.25);
      previous = now;
      const playback = playbackRef.current;
      const playable = playback.playable;

      if (playable !== null) {
        if (playback.playing && playable.duration > 0) {
          playback.time += dt;
          if (playback.time >= playable.duration) {
            // The timeline is the half-open [0, duration): the end is never a valid instant.
            playback.time = playback.loop ? 0 : lastInstant(playable.duration);
            if (!playback.loop) {
              playback.playing = false;
              setPlaying(false);
            }
          }
        }
        // One instant in flight at a time. A seek that has not come back yet simply keeps
        // the previous frame on screen for another animation frame.
        if (!pending && playback.rendered !== playback.time) {
          pending = true;
          const wanted = playback.time;
          const serial = playback.serial;
          playable
            .frameAt(wanted)
            .then((frame) => {
              pending = false;
              if (!running || playbackRef.current.serial !== serial) return;
              playbackRef.current.rendered = wanted;
              renderer.setFrame(frame);
            })
            .catch((failure) => {
              pending = false;
              if (!running || playbackRef.current.serial !== serial) return;
              playbackRef.current.playable = null;
              setPlaying(false);
              setDecodeFailed(true);
              setError(failure);
            });
        }
      }

      renderer.draw(cameraRef.current);

      if (now - lastReadout > READOUT_INTERVAL) {
        lastReadout = now;
        setReadout({
          time: playback.time,
          count: renderer.count,
          intervals: playable === null ? [] : playable.intervalsAt(playback.time),
          transfer: playable === null ? null : playable.transfer(),
        });
      }
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);

    return () => {
      running = false;
      renderer.dispose();
      rendererRef.current = null;
    };
  }, []);

  useEffect(() => {
    if (cameraRef.current !== null) {
      cameraRef.current.upAxis = upAxis;
      cameraRef.current.version += 1;
    }
  }, [upAxis]);

  // --- opening a file ------------------------------------------------------

  const open = useCallback(async (readable, label) => {
    const playback = playbackRef.current;
    // A URL over a slow link and a large local file both take long enough that a visitor
    // can start a second open before the first returns. Every effect below is guarded by
    // the serial this call started under, so the file that finishes last does not win: the
    // one the page says it is showing does, and an older refusal never replaces a newer
    // one.
    playback.serial += 1;
    const serial = playback.serial;
    const current = () => playbackRef.current.serial === serial;
    playback.playable = null;
    playback.playing = false;
    playback.time = 0;
    playback.rendered = undefined;
    setPlaying(false);
    setScene(null);
    setError(null);
    setDecodeFailed(false);
    setSource(label);
    setBusy(true);
    try {
      const playable = await openScene(readable);
      if (!current()) return;
      // Framing also probes a handful of instants. One that will not decode is worth
      // saying now rather than three seconds into playback, so its refusal joins the notes.
      playable.notes.push(
        ...(await frameCamera(playable, rendererRef.current, cameraRef.current, current)),
      );
      if (!current()) return;
      playback.playable = playable;
      playback.time = 0;
      playback.rendered = 0;
      setScene(playable);
    } catch (failure) {
      if (current()) setError(failure);
    } finally {
      if (current()) setBusy(false);
    }
  }, []);

  const openFile = useCallback(
    (file) => {
      if (file === undefined || file === null) return;
      open(new BlobReadable(file), `${file.name} — ${formatBytes(file.size)}, read in this page`);
    },
    [open],
  );

  const openUrl = useCallback(() => {
    const trimmed = url.trim();
    if (trimmed === "") return;
    open(new HttpRangeReadable(trimmed), `${trimmed} — read by byte range from your browser`);
  }, [open, url]);

  // --- pointer camera ------------------------------------------------------

  const onPointerDown = useCallback((event) => {
    event.currentTarget.setPointerCapture(event.pointerId);
    dragRef.current = {
      mode: event.shiftKey || event.button === 2 ? "pan" : "orbit",
      x: event.clientX,
      y: event.clientY,
    };
  }, []);

  const onPointerMove = useCallback((event) => {
    const drag = dragRef.current;
    const camera = cameraRef.current;
    if (drag === null || camera === null) return;
    const rect = event.currentTarget.getBoundingClientRect();
    const dx = (event.clientX - drag.x) / rect.width;
    const dy = (event.clientY - drag.y) / rect.height;
    drag.x = event.clientX;
    drag.y = event.clientY;
    if (drag.mode === "pan") camera.pan(dx, dy);
    else camera.orbit(dx * Math.PI * 2, dy * Math.PI);
  }, []);

  const onPointerUp = useCallback(() => {
    dragRef.current = null;
  }, []);

  const onWheel = useCallback((event) => {
    const camera = cameraRef.current;
    if (camera === null) return;
    camera.dolly(Math.exp(event.deltaY * 0.001));
  }, []);

  // --- transport -----------------------------------------------------------

  const seek = useCallback((value) => {
    const playback = playbackRef.current;
    if (playback.playable === null) return;
    playback.time = Math.max(0, Math.min(value, lastInstant(playback.playable.duration)));
  }, []);

  const togglePlay = useCallback(() => {
    const playback = playbackRef.current;
    if (playback.playable === null) return;
    // A run that ended without looping left the clock on the last instant the timeline
    // contains. Starting from there would reach the duration on the first tick and stop
    // again, so Play from the end means play it again rather than nothing at all.
    if (!playback.playing && playback.time >= lastInstant(playback.playable.duration)) {
      playback.time = 0;
    }
    playback.playing = !playback.playing;
    setPlaying(playback.playing);
  }, []);

  useEffect(() => {
    playbackRef.current.loop = loop;
  }, [loop]);

  // --- markup --------------------------------------------------------------

  const duration = scene === null ? 0 : scene.duration;
  const playableNow = scene !== null && duration > 0 && !decodeFailed;

  return (
    <div className={styles.viewer}>
      <div
        className={dragging ? `${styles.stage} ${styles.stageDragging}` : styles.stage}
        onDragOver={(event) => {
          event.preventDefault();
          setDragging(true);
        }}
        onDragLeave={() => setDragging(false)}
        onDrop={(event) => {
          event.preventDefault();
          setDragging(false);
          openFile(event.dataTransfer.files[0]);
        }}
      >
        <canvas
          ref={canvasRef}
          className={styles.canvas}
          onPointerDown={onPointerDown}
          onPointerMove={onPointerMove}
          onPointerUp={onPointerUp}
          onPointerCancel={onPointerUp}
          onWheel={onWheel}
          onContextMenu={(event) => event.preventDefault()}
        />
        {scene === null && error === null && (
          <div className={styles.placeholder}>
            <p className={styles.placeholderTitle}>Drop a .4dgs file here</p>
            <p>
              {busy
                ? "Decoding…"
                : "Or use the file picker below. The file is decoded in this page and is not uploaded."}
            </p>
          </div>
        )}
      </div>

      <div className={styles.transport}>
        <button
          type="button"
          className="button button--secondary button--sm"
          onClick={togglePlay}
          disabled={!playableNow}
        >
          {playing ? "Pause" : "Play"}
        </button>
        <input
          className={styles.scrub}
          type="range"
          min={0}
          max={duration > 0 ? duration : 1}
          step={duration > 0 ? duration / 2000 : 0.001}
          value={scrub ?? readout.time}
          disabled={!playableNow}
          // The override exists so a dragging thumb is not yanked back by the readout, and
          // it lasts exactly as long as the drag. An arrow key is not a drag: it seeks, and
          // the slider goes straight back to following playback, so the next key press
          // starts from where the scene actually is rather than from a frozen value.
          onPointerDown={() => {
            draggingScrubRef.current = true;
          }}
          onChange={(event) => {
            const value = Number(event.target.value);
            setScrub(draggingScrubRef.current ? value : null);
            seek(value);
          }}
          onPointerUp={() => {
            draggingScrubRef.current = false;
            setScrub(null);
          }}
          onPointerCancel={() => {
            draggingScrubRef.current = false;
            setScrub(null);
          }}
          onBlur={() => {
            draggingScrubRef.current = false;
            setScrub(null);
          }}
          aria-label="Scene time"
        />
        <span className={styles.clock}>
          {readout.time.toFixed(3)} / {duration.toFixed(3)} s
        </span>
        <label className={styles.toggle}>
          <input
            type="checkbox"
            checked={loop}
            onChange={(event) => setLoop(event.target.checked)}
          />{" "}
          Loop
        </label>
        <label className={styles.toggle}>
          Up axis{" "}
          <select value={upAxis} onChange={(event) => setUpAxis(event.target.value)}>
            <option value="y">Y</option>
            <option value="z">Z</option>
          </select>
        </label>
      </div>

      <div className={styles.controls}>
        <label className={styles.file}>
          <input
            type="file"
            accept=".4dgs,application/octet-stream"
            onChange={(event) => openFile(event.target.files[0])}
          />
        </label>
        <div className={styles.urlRow}>
          <input
            className={styles.url}
            type="url"
            placeholder="…or a URL to a .4dgs, read by byte range"
            value={url}
            onChange={(event) => setUrl(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Enter") openUrl();
            }}
          />
          <button
            type="button"
            className="button button--secondary button--sm"
            onClick={openUrl}
            disabled={url.trim() === ""}
          >
            Open URL
          </button>
        </div>
      </div>

      {source !== null && <p className={styles.source}>{source}</p>}

      {error !== null && <Refusal error={error} />}
      {scene !== null && <Facts scene={scene} readout={readout} />}
    </div>
  );
}

/**
 * The decoder's refusal, printed as it came.
 *
 * `@4dgs/core` names the byte, the record, the value and what was expected, and it
 * distinguishes a malformed file from a legal one this build cannot read. Restating any of
 * that as "could not open this file" would waste the one moment the page had a broken file
 * in hand.
 */
/**
 * Which refusal this is, by type rather than by `error.name`.
 *
 * The site is minified, and a minifier renames classes — `FourdgsError` sets its `name`
 * from `new.target.name`, which in a production bundle is a single letter. The
 * distinction between "your file is broken" and "this build cannot read your file" is
 * worth more than that, so it is recovered from the prototype chain, which survives.
 */
const REFUSAL_NAMES = [
  [MalformedFile, "MalformedFile"],
  [TruncatedFile, "TruncatedFile"],
  [UnsupportedCodec, "UnsupportedCodec"],
  [UnsupportedVersion, "UnsupportedVersion"],
  [FourdgsError, "FourdgsError"],
];

function refusalName(error) {
  for (const [type, name] of REFUSAL_NAMES) if (error instanceof type) return name;
  return error?.name ?? "Error";
}

function Refusal({ error }) {
  return (
    <div className={styles.refusal}>
      <h3 className={styles.refusalTitle}>{refusalName(error)}</h3>
      <pre className={styles.refusalBody}>{error.message}</pre>
      <p className={styles.refusalNote}>
        Printed exactly as <code>@4dgs/core</code> raised it. <code>UnsupportedCodec</code> and{" "}
        <code>UnsupportedVersion</code> mean the file may be perfectly conforming and this build
        cannot read part of it; <code>MalformedFile</code> means the bytes are wrong;{" "}
        <code>TruncatedFile</code> means they ran out.
      </p>
    </div>
  );
}

function Facts({ scene, readout }) {
  const { header } = scene;
  const rows = [
    ["Temporal model", header.temporalModel],
    ["Read path", READ_MODES[scene.readMode]],
    ["Gaussians in the file", header.gaussianCount.toLocaleString()],
    ["Live at this instant", readout.count.toLocaleString()],
    ["Duration", `${scene.duration} s`],
    ["Marginal cutoff", String(header.cutoff)],
    ["SH degree", String(header.shDegree)],
    ["Profile", header.profile === "" ? "—" : header.profile],
    ["Written by", header.library === "" ? "—" : header.library],
    [
      "Chunk covering this instant",
      readout.intervals.length === 0
        ? "none"
        : readout.intervals.map((i) => `[${i.t0}, ${i.t1})`).join(" "),
    ],
  ];
  if (readout.transfer !== null) {
    rows.push([
      "Bytes read so far",
      `${formatBytes(readout.transfer.bytes)} of ${formatBytes(readout.transfer.size)}, in ${
        readout.transfer.reads
      } reads`,
    ]);
  }
  return (
    <div className={styles.facts}>
      <dl className={styles.factList}>
        {rows.map(([label, value]) => (
          <React.Fragment key={label}>
            <dt>{label}</dt>
            <dd>{value}</dd>
          </React.Fragment>
        ))}
      </dl>
      {scene.notes.length > 0 && (
        <ul className={styles.notes}>
          {scene.notes.map((note) => (
            <li key={note}>{note}</li>
          ))}
        </ul>
      )}
    </div>
  );
}

const READ_MODES = {
  indexed: "indexed — only the chunks whose [t0, t1) contains the instant on screen",
  streamed: "streamed — the resource read front to back in bounded blocks",
  "keyframe-delta": "keyframe-delta — composed front to back, then reconstructed at the instant",
};

/**
 * Put the camera round the scene, using the first instant that has anything in it.
 *
 * A scene whose gaussians are all born late has nothing at `t = 0`, and framing an empty
 * frame would leave the camera at the origin looking at nothing.
 */
async function frameCamera(playable, renderer, camera, isCurrent) {
  // The instant the visitor lands on. A refusal here is the file's answer to "can you open
  // this", and is allowed to propagate.
  const first = await playable.frameAt(0);
  // A file the visitor has already moved on from does not get to put a frame on the canvas
  // or move the camera; its caller will discard the rest of this open too.
  if (!isCurrent()) return [];
  if (renderer !== null) renderer.setFrame(first);
  if (camera === null) return [];

  const warnings = [];
  let bounds = boundsOf(first.centers, first.count);
  for (const fraction of FRAMING_PROBES) {
    if (fraction === 0 || !(playable.duration > 0)) continue;
    const t = Math.min(playable.duration * fraction, lastInstant(playable.duration));
    try {
      const frame = await playable.frameAt(t);
      bounds ??= boundsOf(frame.centers, frame.count);
    } catch (failure) {
      // Not a refusal of the file: everything before this instant still decodes, and an
      // indexed reader only meets a bad chunk when something seeks into it.
      warnings.push(`t = ${t} does not decode — ${refusalName(failure)}: ${failure.message}`);
    }
  }
  if (!isCurrent()) return [];
  camera.frame(bounds === null ? [0, 0, 0] : bounds.center, bounds === null ? 1 : bounds.radius);
  return warnings;
}

/** The largest instant the half-open timeline `[0, duration)` actually contains. */
function lastInstant(duration) {
  if (!(duration > 0)) return 0;
  return Math.max(0, duration - Math.max(duration * 1e-9, Number.EPSILON));
}

function formatBytes(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KiB`;
  return `${(bytes / (1024 * 1024)).toFixed(2)} MiB`;
}
