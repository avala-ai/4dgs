/**
 * An orbit camera and the four matrix helpers it needs.
 *
 * Small on purpose. The format does not impose a handedness or an up axis — §2 says a
 * producer SHOULD record one in a Coordinate Frame record — so the viewer picks a
 * convention, states it, and lets the visitor change it. Everything here is
 * column-major, the layout `uniformMatrix4fv` wants.
 */

/** Column-major 4×4 identity. */
export function identity() {
  // prettier-ignore
  return new Float32Array([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]);
}

/** Right-handed perspective projection, looking down −z, depth in `[-1, 1]`. */
export function perspective(fovYRadians, aspect, near, far) {
  const f = 1 / Math.tan(fovYRadians / 2);
  const out = new Float32Array(16);
  out[0] = f / aspect;
  out[5] = f;
  out[10] = (far + near) / (near - far);
  out[11] = -1;
  out[14] = (2 * far * near) / (near - far);
  return out;
}

/** Right-handed view matrix placing `eye`, looking at `target`, roughly `up`. */
export function lookAt(eye, target, up) {
  const z = normalize([eye[0] - target[0], eye[1] - target[1], eye[2] - target[2]]);
  let x = cross(up, z);
  // A camera looking straight along `up` leaves no side vector. Nudging `up` is the
  // ordinary fix and keeps the pole from producing a NaN matrix.
  if (length(x) < 1e-6) x = cross([up[1], up[2], up[0]], z);
  x = normalize(x);
  const y = cross(z, x);
  const out = new Float32Array(16);
  out[0] = x[0];
  out[1] = y[0];
  out[2] = z[0];
  out[4] = x[1];
  out[5] = y[1];
  out[6] = z[1];
  out[8] = x[2];
  out[9] = y[2];
  out[10] = z[2];
  out[12] = -dot(x, eye);
  out[13] = -dot(y, eye);
  out[14] = -dot(z, eye);
  out[15] = 1;
  return out;
}

function dot(a, b) {
  return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

function cross(a, b) {
  return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
}

function length(a) {
  return Math.sqrt(dot(a, a));
}

function normalize(a) {
  const n = length(a) || 1;
  return [a[0] / n, a[1] / n, a[2] / n];
}

/** How far the pitch may go before the view vector and the up axis are parallel. */
const PITCH_LIMIT = Math.PI / 2 - 0.01;

/**
 * A camera the pointer drives: drag to orbit, wheel to dolly, shift-drag to pan.
 *
 * Held in spherical coordinates about a target rather than as a matrix, because that is
 * what the three gestures actually change.
 */
export class OrbitCamera {
  constructor() {
    this.target = [0, 0, 0];
    this.distance = 4;
    this.yaw = 0.6;
    this.pitch = 0.3;
    /** `"y"` or `"z"`: which axis of the scene points up on screen. */
    this.upAxis = "y";
    this.fovY = (50 * Math.PI) / 180;
    /** Bumped on every change, so the renderer can tell whether the view moved. */
    this.version = 0;
  }

  /** The world-space up vector for the chosen axis. */
  up() {
    return this.upAxis === "z" ? [0, 0, 1] : [0, 1, 0];
  }

  /** Where the camera is, in world space. */
  eye() {
    const c = Math.cos(this.pitch) * this.distance;
    const height = Math.sin(this.pitch) * this.distance;
    const a = this.yaw;
    if (this.upAxis === "z") {
      return [
        this.target[0] + c * Math.cos(a),
        this.target[1] + c * Math.sin(a),
        this.target[2] + height,
      ];
    }
    return [
      this.target[0] + c * Math.sin(a),
      this.target[1] + height,
      this.target[2] + c * Math.cos(a),
    ];
  }

  view() {
    return lookAt(this.eye(), this.target, this.up());
  }

  projection(aspect) {
    // The near plane follows the orbit distance so a scene a millimetre across and one a
    // kilometre across both keep their depth precision without the visitor tuning anything.
    const near = Math.max(this.distance * 0.005, 1e-5);
    return perspective(this.fovY, aspect, near, near + this.distance * 1000 + 1000);
  }

  /** Vertical focal length in pixels, which is what the covariance projection needs. */
  focal(height) {
    return 0.5 * height * (1 / Math.tan(this.fovY / 2));
  }

  orbit(dx, dy) {
    this.yaw -= dx;
    this.pitch = Math.max(-PITCH_LIMIT, Math.min(PITCH_LIMIT, this.pitch + dy));
    this.version += 1;
  }

  dolly(factor) {
    this.distance = Math.max(1e-4, this.distance * factor);
    this.version += 1;
  }

  /** Pan across the screen plane, in units scaled to how far away the target is. */
  pan(dx, dy) {
    const eye = this.eye();
    const forward = normalize([
      this.target[0] - eye[0],
      this.target[1] - eye[1],
      this.target[2] - eye[2],
    ]);
    const right = normalize(cross(forward, this.up()));
    const up = cross(right, forward);
    const scale = this.distance * 0.75;
    for (let i = 0; i < 3; i++) {
      this.target[i] += (-dx * right[i] + dy * up[i]) * scale;
    }
    this.version += 1;
  }

  /** Point the camera at a bounding sphere, whatever its size. */
  frame(center, radius) {
    this.target = [center[0], center[1], center[2]];
    this.distance = Math.max(radius, 1e-4) / Math.tan(this.fovY / 2) + Math.max(radius, 1e-4);
    this.version += 1;
  }
}

/**
 * The centre and radius of a sphere containing every gaussian in a frame.
 *
 * Centres only: the scale of a gaussian is small beside the extent of a scene, and a
 * frame with none has nothing to frame, which the caller handles.
 */
export function boundsOf(centers, count) {
  if (count === 0) return null;
  const lo = [Infinity, Infinity, Infinity];
  const hi = [-Infinity, -Infinity, -Infinity];
  for (let i = 0; i < count; i++) {
    for (let c = 0; c < 3; c++) {
      const value = centers[i * 3 + c];
      if (!Number.isFinite(value)) continue;
      if (value < lo[c]) lo[c] = value;
      if (value > hi[c]) hi[c] = value;
    }
  }
  if (!Number.isFinite(lo[0]) || !Number.isFinite(hi[0])) return null;
  const center = [0, 0, 0];
  let radius = 0;
  for (let c = 0; c < 3; c++) {
    center[c] = (lo[c] + hi[c]) / 2;
    radius = Math.max(radius, (hi[c] - lo[c]) / 2);
  }
  return { center, radius: radius === 0 ? 1 : radius * Math.sqrt(3) };
}
