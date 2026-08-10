/**
 * Reconstructing a composed `keyframe-delta` population into drawable gaussians.
 *
 * `@4dgs/core` does the whole of the model that is hard: framing, composition over
 * integer bins, the chain walk, the tiling and level rules. What it does not publish is
 * the last step — composed bins to values at an instant — because the conformance
 * statement it is diffed on (`keyframeDeltaStatesJson`) only ever needs a sample of
 * positions and scales, while a renderer needs every attribute of every gaussian.
 *
 * So this file is that last step and nothing else. Every grid it uses comes from
 * `@4dgs/core`'s own exported primitives — `stepsFrom`, `lifeClass`, `motionStep`,
 * `muStep`, `dequantizeRotation`, `rctInverse` — because specification §11.7 is explicit
 * that a composed bin *is* the bin an absolute statement of that instant would carry:
 * dequantization here is the same arithmetic a keyframe chunk uses, and doing it any other
 * way would be a second decoder disagreeing with the first.
 */

import {
  Attribute,
  GAUSSIAN_FLAG_NEVER_FADES,
  MalformedFile,
  checkWindowIndex,
  dequantizeRotation,
  lifeClass,
  motionStep,
  muStep,
  rctInverse,
  stepsFrom,
  supportK,
  windowTableOrDefault,
} from "@4dgs/core";

const ATTRIBUTE_NAMES = new Map([
  [Attribute.Position, "position"],
  [Attribute.Scale, "scale"],
  [Attribute.RotationIndex, "rotation_index"],
  [Attribute.Rotation, "rotation"],
  [Attribute.Color, "color"],
  [Attribute.Opacity, "opacity"],
  [Attribute.Motion, "motion"],
  [Attribute.MuT, "mu_t"],
  [Attribute.SigmaT, "sigma_t"],
  [Attribute.Flags, "flags"],
  [Attribute.WindowIndex, "window_index"],
]);

function clamp(value, lo, hi) {
  return value < lo ? lo : value > hi ? hi : value;
}

/**
 * The population `chunk` carries, reconstructed at scene time `t`.
 *
 * `chunk` is the one whose half-open `[t0, t1)` contains `t`; picking it is the seek, and
 * this is what that seek was for.
 *
 * The gaussians that come back are the ones §3 calls visible at `t` —
 * `win_lo <= t < win_hi` and `marginal >= cutoff` — and no others. The window test is the
 * format's only hard temporal gate (§3.1) and it is not a property of the temporal model:
 * a composed `keyframe-delta` state carries a `window_index` per gaussian exactly as a
 * `gaussian-birth` chunk does, so the same two comparisons decide existence on both paths.
 * `@4dgs/core`'s canonical statement for this model reports every composed row rather than
 * the visible ones, because it is describing the population a chunk carries and not what a
 * consumer draws; those are different questions and this one is the renderer's.
 *
 * @param {object} sequence the decoded `KeyframeDeltaSequence`
 * @param {object} chunk one `KeyframeDeltaChunkInfo` from it
 * @param {number} t scene time, in seconds
 * @param {number} cutoff the marginal below which a gaussian is not drawn
 * @returns {import("./openScene").Frame}
 */
export function reconstructKeyframeDelta(sequence, chunk, t, cutoff) {
  const state = chunk.state;
  const count = state.count;
  const steps = stepsFrom(sequence.quantization);
  const origin = sequence.quantization.posOrigin;
  const windows = windowTableOrDefault(sequence.windows);
  const windowCount = windows.length >>> 1;
  const k = supportK(sequence.header.cutoff);

  const centers = new Float32Array(count * 3);
  const scales = new Float32Array(count * 3);
  const rotations = new Float32Array(count * 4);
  const colors = new Float32Array(count * 4);
  if (count === 0) return frameOf(t, 0, centers, scales, rotations, colors);

  const position = columnOf(state, Attribute.Position, chunk);
  const scaleBins = columnOf(state, Attribute.Scale, chunk);
  const rotationIndex = columnOf(state, Attribute.RotationIndex, chunk);
  const rotationBins = columnOf(state, Attribute.Rotation, chunk);
  const colorBins = columnOf(state, Attribute.Color, chunk);
  const opacityBins = columnOf(state, Attribute.Opacity, chunk);
  const motion = columnOf(state, Attribute.Motion, chunk);
  const muBins = columnOf(state, Attribute.MuT, chunk);
  const sigmaBins = columnOf(state, Attribute.SigmaT, chunk);
  const flags = columnOf(state, Attribute.Flags, chunk);
  const windowBins = columnOf(state, Attribute.WindowIndex, chunk);

  // Rows are written at `live`, not at `i`: a gaussian the two visibility tests reject is
  // not a transparent gaussian, it is one that does not exist at this instant, and the
  // frame the renderer is handed says so by not containing it.
  let live = 0;
  for (let i = 0; i < count; i++) {
    const i3 = i * 3;
    const sigmaBin = sigmaBins[i];
    const neverFades = (flags[i] & GAUSSIAN_FLAG_NEVER_FADES) !== 0;
    const sigma = neverFades ? Infinity : Math.exp(sigmaBin * steps.sigmaLog);

    // Velocity and birth-time pitches are derived per gaussian from its own sigma bin and
    // its own validity window (§6.3). An out-of-range window index is refused rather than
    // clamped: clamping substitutes one gaussian's lifetime for another's.
    const windowIndex = checkWindowIndex(
      windowBins[i],
      windowCount,
      `keyframe-delta chunk at byte ${chunk.offset}, gaussian id ${state.ids[i]}`,
    );
    const windowLo = windows[windowIndex * 2];
    const windowHi = windows[windowIndex * 2 + 1];
    // §3.1: the validity window is the format's only hard temporal gate, and a gaussian
    // outside it does not exist at `t` whatever its marginal says.
    if (!(windowLo <= t && t < windowHi)) continue;

    const step = motionStep(
      lifeClass(sigmaBin, steps.sigmaLog, neverFades, windowHi - windowLo, k),
      steps.motion,
    );
    const mu = muBins[i] * muStep(sigmaBin, steps.sigmaLog, neverFades, steps.time);
    const dt = t - mu;
    const marginal = sigma === Infinity ? 1 : Math.exp(-0.5 * (dt / sigma) * (dt / sigma));
    // The other half of §3's visibility test, and the file's own threshold for it.
    if (!(marginal >= cutoff)) continue;

    const o3 = live * 3;
    for (let c = 0; c < 3; c++) {
      const rest = position[i3 + c] * steps.pos + origin[c];
      centers[o3 + c] = rest + motion[i3 + c] * step * dt;
      scales[o3 + c] = Math.exp(scaleBins[i3 + c] * steps.scaleLog);
    }

    dequantizeRotation(
      rotationIndex[i],
      rotationBins[i3],
      rotationBins[i3 + 1],
      rotationBins[i3 + 2],
      steps.rot,
      rotations,
      live * 4,
    );

    const [r, g, b] = rctInverse(colorBins[i3], colorBins[i3 + 1], colorBins[i3 + 2]);
    colors[live * 4] = clamp(r * steps.rgb, 0, 1);
    colors[live * 4 + 1] = clamp(g * steps.rgb, 0, 1);
    colors[live * 4 + 2] = clamp(b * steps.rgb, 0, 1);
    colors[live * 4 + 3] = clamp(opacityBins[i] * steps.alpha, 0, 1) * marginal;
    live += 1;
  }

  return frameOf(t, live, centers, scales, rotations, colors);
}

function frameOf(t, count, centers, scales, rotations, colors) {
  return {
    time: t,
    count,
    centers: centers.subarray(0, count * 3),
    scales: scales.subarray(0, count * 3),
    rotations: rotations.subarray(0, count * 4),
    colors: colors.subarray(0, count * 4),
    sh: null,
    shCoefficients: 0,
    shDegree: 0,
  };
}

/**
 * One attribute's composed bins.
 *
 * A composed state that is missing a required attribute is refused by name here rather
 * than read as zeroes: a gaussian with no colour column is not a black gaussian, it is a
 * file this reader cannot draw.
 */
function columnOf(state, attribute, chunk) {
  const column = state.column(attribute);
  if (column === undefined) {
    const name = ATTRIBUTE_NAMES.get(attribute) ?? `attribute ${attribute}`;
    throw new MalformedFile(
      `the population composed at the chunk at byte ${chunk.offset} carries no ${name} ` +
        `column (attribute ${attribute}), which every keyframe-delta state must have`,
    );
  }
  return column.values;
}
