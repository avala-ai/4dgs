/**
 * A reference gaussian splat rasterizer, in WebGL2.
 *
 * Held to the same standard as the reference decoders and no higher: correct and readable
 * first, and slow where slow is the readable choice. The sort is a comparison sort in
 * JavaScript, the spherical harmonics are evaluated on the CPU, and every gaussian alive
 * at an instant is drawn. There is no WebAssembly, no GPU radix sort, no level of detail
 * and no culling beyond the near plane. **Do not benchmark the format with this.**
 *
 * What it does do is the part worth copying:
 *
 * - the 3D covariance `Σ = R S Sᵀ Rᵀ` from the decoded scale and rotation;
 * - its projection to a 2D screen-space covariance through the perspective Jacobian;
 * - a quad on the eigenvectors of that 2D covariance, with the gaussian falloff evaluated
 *   per fragment;
 * - a back-to-front sort, because "over" compositing is not commutative and an unsorted
 *   splat cloud is wrong in a way that looks like a rendering bug rather than a decoding
 *   one.
 *
 * Two textures hold the gaussians so the sort only ever moves indices:
 *
 * - `geometry` (RGBA32F, three texels each): centre and opacity, then the six distinct
 *   entries of the symmetric 3D covariance. Rebuilt when scene time changes.
 * - `colour` (RGBA8, one texel each): the colour of that gaussian as seen from where the
 *   camera is now. Rebuilt when time changes, and when the camera moves if the scene
 *   carries spherical harmonics.
 */

/**
 * Texels per row in both data textures, when the device allows it.
 *
 * A row this narrow keeps the staging arrays small for an ordinary scene, but a texture is
 * also no taller than `MAX_TEXTURE_SIZE` — 2048 rows on a device at WebGL2's floor, which
 * at three texels a gaussian is only about 699k of them. Past that the rows are widened to
 * the device's limit instead, which is why the shaders read `textureSize()` rather than
 * this constant.
 */
const TEXTURE_WIDTH = 1024;

/** How many standard deviations of the 2D gaussian the drawn quad covers. */
const QUAD_RADIUS = 3.0;

/**
 * Screen-space dilation, in pixels², added to the 2D covariance diagonal.
 *
 * A gaussian smaller than a pixel projects to a covariance the rasterizer cannot sample,
 * and drops out entirely as the camera pulls back. The dilation is the usual EWA
 * low-pass: it costs a sub-pixel blur and keeps distant geometry on screen.
 */
const DILATION = 0.3;

const VERTEX_SHADER = `#version 300 es
precision highp float;
precision highp int;

uniform sampler2D u_geometry;
uniform sampler2D u_colour;
uniform mat4 u_view;
uniform mat4 u_projection;
uniform vec2 u_focal;
uniform vec2 u_viewport;
uniform float u_near;

in vec2 a_corner;
in uint a_index;

out vec4 v_colour;
out vec2 v_offset;

ivec2 texelAt(int width, int i) {
  return ivec2(i % width, i / width);
}

void main() {
  int gaussian = int(a_index);
  int width = textureSize(u_geometry, 0).x;
  vec4 g0 = texelFetch(u_geometry, texelAt(width, gaussian * 3), 0);
  vec4 g1 = texelFetch(u_geometry, texelAt(width, gaussian * 3 + 1), 0);
  vec4 g2 = texelFetch(u_geometry, texelAt(width, gaussian * 3 + 2), 0);

  vec4 viewPosition = u_view * vec4(g0.xyz, 1.0);
  // Behind the camera or through the near plane: the Jacobian below divides by z, and a
  // gaussian straddling the eye projects to nonsense rather than to a large splat.
  if (-viewPosition.z < u_near) {
    gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
    return;
  }

  // The symmetric 3D covariance, packed as (xx, xy, xz) and (yy, yz, zz).
  mat3 sigma = mat3(
    g1.x, g1.y, g1.z,
    g1.y, g2.x, g2.y,
    g1.z, g2.y, g2.z
  );
  mat3 rotation = mat3(u_view);
  mat3 sigmaCamera = rotation * sigma * transpose(rotation);

  // Rows of the perspective Jacobian d(screen pixels)/d(camera space), at this centre.
  float invZ = 1.0 / viewPosition.z;
  vec3 jacobianX = vec3(-u_focal.x * invZ, 0.0, u_focal.x * viewPosition.x * invZ * invZ);
  vec3 jacobianY = vec3(0.0, -u_focal.y * invZ, u_focal.y * viewPosition.y * invZ * invZ);

  float a = dot(jacobianX, sigmaCamera * jacobianX) + ${DILATION.toFixed(1)};
  float b = dot(jacobianX, sigmaCamera * jacobianY);
  float c = dot(jacobianY, sigmaCamera * jacobianY) + ${DILATION.toFixed(1)};

  // Eigenvalues and eigenvectors of the 2x2 [[a, b], [b, c]].
  float middle = 0.5 * (a + c);
  float radius = sqrt(max(middle * middle - (a * c - b * b), 0.0));
  float major = middle + radius;
  float minor = max(middle - radius, 0.0);
  if (major <= 0.0) {
    gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
    return;
  }
  vec2 axis1 = abs(b) < 1e-9 ? (a >= c ? vec2(1.0, 0.0) : vec2(0.0, 1.0))
                             : normalize(vec2(b, major - a));
  vec2 axis2 = vec2(-axis1.y, axis1.x);

  vec2 offsetPixels = ${QUAD_RADIUS.toFixed(1)} *
    (a_corner.x * axis1 * sqrt(major) + a_corner.y * axis2 * sqrt(minor));

  vec4 clip = u_projection * viewPosition;
  gl_Position = vec4(clip.xy + offsetPixels * 2.0 / u_viewport * clip.w, clip.z, clip.w);

  v_colour = vec4(texelFetch(u_colour, texelAt(textureSize(u_colour, 0).x, gaussian), 0).rgb, g0.w);
  v_offset = a_corner * ${QUAD_RADIUS.toFixed(1)};
}
`;

const FRAGMENT_SHADER = `#version 300 es
precision highp float;

in vec4 v_colour;
in vec2 v_offset;

out vec4 fragment;

void main() {
  float power = -0.5 * dot(v_offset, v_offset);
  float alpha = v_colour.a * exp(power);
  if (alpha < 1.0 / 255.0) discard;
  // Premultiplied, so the blend below is "over" with a single blend function.
  fragment = vec4(v_colour.rgb * alpha, alpha);
}
`;

/** Real spherical harmonic basis constants, band 1 through band 3. */
const SH_C1 = 0.4886025119029199;
const SH_C2 = [
  1.0925484305920792, -1.0925484305920792, 0.31539156525252005, -1.0925484305920792,
  0.5462742152960396,
];
const SH_C3 = [
  -0.5900435899266435, 2.890611442640554, -0.4570457994644658, 0.3731763325901154,
  -0.4570457994644658, 1.445305721320277, -0.5900435899266435,
];

export class SplatRenderer {
  constructor(canvas) {
    const gl = canvas.getContext("webgl2", {
      alpha: false,
      antialias: false,
      premultipliedAlpha: true,
      preserveDrawingBuffer: false,
    });
    if (gl === null) {
      throw new Error(
        "this browser did not give the page a WebGL2 context, which the viewer needs",
      );
    }
    this.gl = gl;
    this.canvas = canvas;
    // Kept before a loss: querying extensions after the context is gone is not reliable.
    // The viewer asks the platform to restore after surfacing the failure, then rebuilds
    // every GPU object in `webglcontextrestored`.
    this.contextLossExtension = gl.getExtension("WEBGL_lose_context");
    this.program = linkProgram(gl, VERTEX_SHADER, FRAGMENT_SHADER);
    this.uniforms = {
      geometry: gl.getUniformLocation(this.program, "u_geometry"),
      colour: gl.getUniformLocation(this.program, "u_colour"),
      view: gl.getUniformLocation(this.program, "u_view"),
      projection: gl.getUniformLocation(this.program, "u_projection"),
      focal: gl.getUniformLocation(this.program, "u_focal"),
      viewport: gl.getUniformLocation(this.program, "u_viewport"),
      near: gl.getUniformLocation(this.program, "u_near"),
    };

    this.vao = gl.createVertexArray();
    gl.bindVertexArray(this.vao);

    this.cornerBuffer = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, this.cornerBuffer);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
    const corner = gl.getAttribLocation(this.program, "a_corner");
    gl.enableVertexAttribArray(corner);
    gl.vertexAttribPointer(corner, 2, gl.FLOAT, false, 0, 0);

    this.indexBuffer = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, this.indexBuffer);
    const index = gl.getAttribLocation(this.program, "a_index");
    gl.enableVertexAttribArray(index);
    gl.vertexAttribIPointer(index, 1, gl.UNSIGNED_INT, 0, 0);
    gl.vertexAttribDivisor(index, 1);

    gl.bindVertexArray(null);

    this.geometryTexture = createTexture(gl);
    this.colourTexture = createTexture(gl);

    // `texImage2D` past this limit fails with INVALID_VALUE and throws nothing: the draw
    // then samples a texture that was never allocated, which is a blank canvas and no
    // message. It is asked for once, here, and respected in `ensureCapacity`.
    this.maxTextureSize = gl.getParameter(gl.MAX_TEXTURE_SIZE);
    this.geometryLayout = { width: TEXTURE_WIDTH, rows: 0, texels: 0 };
    this.colourLayout = { width: TEXTURE_WIDTH, rows: 0, texels: 0 };
    this.capacity = 0;
    this.frame = null;
    this.frameSerial = 0;
    this.colouredForFrame = -1;
    this.colouredForCamera = -1;
  }

  /** Whether anything has been given to draw yet. */
  get count() {
    return this.frame === null ? 0 : this.frame.count;
  }

  /**
   * Forget whatever was on the canvas.
   *
   * Opening a second file must not leave the first one drawn: a refusal printed over the
   * previous scene's geometry reads as "some of your file came through", which is the one
   * thing a decoder's refusal must never be mistaken for.
   */
  clear() {
    this.frame = null;
    this.frameSerial += 1;
  }

  requestContextRestore() {
    this.contextLossExtension?.restoreContext();
  }

  /**
   * Take the gaussians alive at an instant.
   *
   * The covariances are built here, once per instant, rather than per frame: they depend
   * on the scene's scale and rotation and not at all on where the camera is.
   */
  setFrame(frame) {
    // Capacity is a precondition for publishing the frame. If allocation refuses an
    // oversized scene, `draw` must continue to see the previous valid frame (or none), not
    // a count whose staging arrays and textures were never created.
    if (frame.count > 0) this.ensureCapacity(frame.count);

    if (frame.count === 0) {
      this.frame = frame;
      this.frameSerial += 1;
      return;
    }

    const geometry = this.geometryData;
    for (let i = 0; i < frame.count; i++) {
      const at = i * 12;
      geometry[at] = frame.centers[i * 3];
      geometry[at + 1] = frame.centers[i * 3 + 1];
      geometry[at + 2] = frame.centers[i * 3 + 2];
      geometry[at + 3] = frame.colors[i * 4 + 3];
      covariance(frame.scales, frame.rotations, i, geometry, at + 4);
    }

    const gl = this.gl;
    const { width, rows } = rowsFor(this.geometryLayout, frame.count * 3);
    gl.bindTexture(gl.TEXTURE_2D, this.geometryTexture);
    gl.texSubImage2D(
      gl.TEXTURE_2D,
      0,
      0,
      0,
      width,
      rows,
      gl.RGBA,
      gl.FLOAT,
      geometry.subarray(0, rows * width * 4),
    );
    this.frame = frame;
    this.frameSerial += 1;
  }

  /** Draw the current frame from the current camera. */
  draw(camera) {
    const gl = this.gl;
    const width = Math.max(1, Math.round(this.canvas.clientWidth * devicePixelRatio));
    const height = Math.max(1, Math.round(this.canvas.clientHeight * devicePixelRatio));
    if (this.canvas.width !== width || this.canvas.height !== height) {
      this.canvas.width = width;
      this.canvas.height = height;
    }
    gl.viewport(0, 0, width, height);
    gl.disable(gl.DEPTH_TEST);
    gl.enable(gl.BLEND);
    gl.blendFuncSeparate(gl.ONE, gl.ONE_MINUS_SRC_ALPHA, gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
    gl.clearColor(0.06, 0.07, 0.09, 1);
    gl.clear(gl.COLOR_BUFFER_BIT);

    const frame = this.frame;
    if (frame === null || frame.count === 0) return;

    const view = camera.view();
    const eye = camera.eye();
    this.refreshColours(frame, eye, camera.version);
    const visible = this.sortBackToFront(frame, view);
    if (visible === 0) return;

    const near = Math.max(camera.distance * 0.005, 1e-5);
    gl.useProgram(this.program);
    gl.bindVertexArray(this.vao);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, this.geometryTexture);
    gl.uniform1i(this.uniforms.geometry, 0);
    gl.activeTexture(gl.TEXTURE1);
    gl.bindTexture(gl.TEXTURE_2D, this.colourTexture);
    gl.uniform1i(this.uniforms.colour, 1);
    gl.uniformMatrix4fv(this.uniforms.view, false, view);
    gl.uniformMatrix4fv(this.uniforms.projection, false, camera.projection(width / height));
    const focal = camera.focal(height);
    gl.uniform2f(this.uniforms.focal, focal, focal);
    gl.uniform2f(this.uniforms.viewport, width, height);
    gl.uniform1f(this.uniforms.near, near);
    gl.drawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, visible);
    gl.bindVertexArray(null);
  }

  dispose() {
    const gl = this.gl;
    gl.deleteProgram(this.program);
    gl.deleteVertexArray(this.vao);
    gl.deleteBuffer(this.cornerBuffer);
    gl.deleteBuffer(this.indexBuffer);
    gl.deleteTexture(this.geometryTexture);
    gl.deleteTexture(this.colourTexture);
    this.frame = null;
  }

  /**
   * Back to front, by view-space depth.
   *
   * A plain comparison sort over an index array, run every frame. It is the single
   * slowest thing on this page and it is deliberately the obvious implementation: a
   * production renderer replaces it with a bucketed or GPU radix sort, and that choice
   * belongs to the renderer rather than to the format.
   */
  sortBackToFront(frame, view) {
    const depths = this.depths;
    const order = this.order;
    let visible = 0;
    for (let i = 0; i < frame.count; i++) {
      const x = frame.centers[i * 3];
      const y = frame.centers[i * 3 + 1];
      const z = frame.centers[i * 3 + 2];
      // Row 3 of a column-major view matrix: camera-space z, negative in front of the eye.
      const depth = view[2] * x + view[6] * y + view[10] * z + view[14];
      if (!Number.isFinite(depth) || depth >= 0) continue;
      depths[i] = depth;
      order[visible] = i;
      visible += 1;
    }
    // Ascending camera-space z is farthest first, which is the order "over" wants.
    order.subarray(0, visible).sort((a, b) => depths[a] - depths[b]);
    const gl = this.gl;
    gl.bindBuffer(gl.ARRAY_BUFFER, this.indexBuffer);
    gl.bufferData(gl.ARRAY_BUFFER, order.subarray(0, visible), gl.DYNAMIC_DRAW);
    return visible;
  }

  /**
   * Rebuild the colour texture when the answer it holds has changed.
   *
   * Without spherical harmonics a gaussian's colour is a property of the scene, so this
   * runs once per instant. With them it is a property of the direction the gaussian is
   * seen from, so it also runs whenever the camera moves.
   */
  refreshColours(frame, eye, cameraVersion) {
    const viewDependent = frame.sh !== null && frame.shCoefficients > 0;
    if (
      this.colouredForFrame === this.frameSerial &&
      (!viewDependent || this.colouredForCamera === cameraVersion)
    ) {
      return;
    }
    this.colouredForFrame = this.frameSerial;
    this.colouredForCamera = cameraVersion;

    const colours = this.colourData;
    const rgb = [0, 0, 0];
    for (let i = 0; i < frame.count; i++) {
      rgb[0] = frame.colors[i * 4];
      rgb[1] = frame.colors[i * 4 + 1];
      rgb[2] = frame.colors[i * 4 + 2];
      if (viewDependent) addSphericalHarmonics(frame, i, eye, rgb);
      for (let c = 0; c < 3; c++) {
        colours[i * 4 + c] = Math.round(255 * linearToSrgb(clamp01(rgb[c])));
      }
      colours[i * 4 + 3] = 255;
    }

    const gl = this.gl;
    const { width, rows } = rowsFor(this.colourLayout, frame.count);
    gl.bindTexture(gl.TEXTURE_2D, this.colourTexture);
    gl.texSubImage2D(
      gl.TEXTURE_2D,
      0,
      0,
      0,
      width,
      rows,
      gl.RGBA,
      gl.UNSIGNED_BYTE,
      colours.subarray(0, rows * width * 4),
    );
  }

  /** Grow the staging arrays and the textures. They never shrink. */
  ensureCapacity(count) {
    if (count <= this.capacity) return;
    const limit = this.maxTextureSize;
    // Three texels a gaussian, in a texture that is at most `limit` texels each way.
    const supported = Math.floor((limit * limit) / 3);
    if (count > supported) {
      throw new Error(
        `this scene has ${count} gaussians alive at one instant, and this device's WebGL2 ` +
          `MAX_TEXTURE_SIZE of ${limit} holds at most ${supported} of them (three texels ` +
          `each) in the one texture this viewer draws from. The file is fine; the page will ` +
          `not draw it. A renderer that tiles its data across several textures would.`,
      );
    }
    const capacity = Math.min(supported, Math.max(count, TEXTURE_WIDTH, this.capacity * 2));
    this.geometryLayout = layoutFor(capacity * 3, limit);
    this.colourLayout = layoutFor(capacity, limit);
    this.capacity = capacity;
    // Whole rows, so a partial `texSubImage2D` always has the bytes it says it has.
    this.geometryData = new Float32Array(this.geometryLayout.texels * 4);
    this.colourData = new Uint8Array(this.colourLayout.texels * 4);
    this.depths = new Float32Array(this.capacity);
    this.order = new Uint32Array(this.capacity);

    const gl = this.gl;
    gl.bindTexture(gl.TEXTURE_2D, this.geometryTexture);
    gl.texImage2D(
      gl.TEXTURE_2D,
      0,
      gl.RGBA32F,
      this.geometryLayout.width,
      this.geometryLayout.rows,
      0,
      gl.RGBA,
      gl.FLOAT,
      null,
    );
    gl.bindTexture(gl.TEXTURE_2D, this.colourTexture);
    gl.texImage2D(
      gl.TEXTURE_2D,
      0,
      gl.RGBA8,
      this.colourLayout.width,
      this.colourLayout.rows,
      0,
      gl.RGBA,
      gl.UNSIGNED_BYTE,
      null,
    );
    this.colouredForFrame = -1;
  }
}

/**
 * A texture wide enough to hold `texels` in no more than `limit` rows.
 *
 * The narrow default row is kept while it fits, because it is what makes the staging array
 * for a small scene small. Once the row count would pass `MAX_TEXTURE_SIZE` the widest row
 * the device allows is the only shape left, and it raises the ceiling to `limit²` texels.
 */
function layoutFor(texels, limit) {
  const narrow = Math.min(TEXTURE_WIDTH, limit);
  const width = Math.ceil(texels / narrow) > limit ? limit : narrow;
  const rows = Math.max(1, Math.ceil(texels / width));
  return { width, rows, texels: width * rows };
}

/** The whole rows of `layout` that `texels` occupies, which is what an upload covers. */
function rowsFor(layout, texels) {
  return { width: layout.width, rows: Math.max(1, Math.ceil(texels / layout.width)) };
}

/**
 * `Σ = R S Sᵀ Rᵀ` for gaussian `i`, written as its six distinct entries.
 *
 * The quaternion is xyzw, the convention §3 fixes and the one the decoder hands over, so
 * no component shuffle happens anywhere on this page.
 */
function covariance(scales, rotations, i, out, at) {
  const x = rotations[i * 4];
  const y = rotations[i * 4 + 1];
  const z = rotations[i * 4 + 2];
  const w = rotations[i * 4 + 3];
  // Rotation matrix columns from the unit quaternion.
  const r = [
    1 - 2 * (y * y + z * z),
    2 * (x * y + w * z),
    2 * (x * z - w * y),
    2 * (x * y - w * z),
    1 - 2 * (x * x + z * z),
    2 * (y * z + w * x),
    2 * (x * z + w * y),
    2 * (y * z - w * x),
    1 - 2 * (x * x + y * y),
  ];
  const sx = scales[i * 3];
  const sy = scales[i * 3 + 1];
  const sz = scales[i * 3 + 2];
  // M = R * S, so Σ = M Mᵀ.
  const m = [
    r[0] * sx,
    r[1] * sx,
    r[2] * sx,
    r[3] * sy,
    r[4] * sy,
    r[5] * sy,
    r[6] * sz,
    r[7] * sz,
    r[8] * sz,
  ];
  out[at] = m[0] * m[0] + m[3] * m[3] + m[6] * m[6];
  out[at + 1] = m[0] * m[1] + m[3] * m[4] + m[6] * m[7];
  out[at + 2] = m[0] * m[2] + m[3] * m[5] + m[6] * m[8];
  out[at + 3] = 0;
  out[at + 4] = m[1] * m[1] + m[4] * m[4] + m[7] * m[7];
  out[at + 5] = m[1] * m[2] + m[4] * m[5] + m[7] * m[8];
  out[at + 6] = m[2] * m[2] + m[5] * m[5] + m[8] * m[8];
  out[at + 7] = 0;
}

/**
 * Add the view-dependent term to a gaussian's rest colour.
 *
 * A stored coefficient byte `b` is the value `-4 + b * 8 / 255` on `[-4, +4]`
 * (specification §6.5). `step_sh` is an encode-side declaration and is deliberately not
 * applied: multiplying by it here would scale appearance by one to three.
 */
function addSphericalHarmonics(frame, i, eye, rgb) {
  const dx = frame.centers[i * 3] - eye[0];
  const dy = frame.centers[i * 3 + 1] - eye[1];
  const dz = frame.centers[i * 3 + 2] - eye[2];
  const norm = Math.hypot(dx, dy, dz) || 1;
  const x = dx / norm;
  const y = dy / norm;
  const z = dz / norm;

  const coefficients = frame.shCoefficients;
  const values = frame.sh;
  const base = i * 3 * coefficients;
  const degree = frame.shDegree;

  for (let c = 0; c < 3; c++) {
    const at = base + c * coefficients;
    const k = (index) => -4 + (values[at + index] * 8) / 255;
    let sum = SH_C1 * (-y * k(0) + z * k(1) - x * k(2));
    if (degree >= 2) {
      const xx = x * x;
      const yy = y * y;
      const zz = z * z;
      sum +=
        SH_C2[0] * x * y * k(3) +
        SH_C2[1] * y * z * k(4) +
        SH_C2[2] * (2 * zz - xx - yy) * k(5) +
        SH_C2[3] * x * z * k(6) +
        SH_C2[4] * (xx - yy) * k(7);
      if (degree >= 3) {
        sum +=
          SH_C3[0] * y * (3 * xx - yy) * k(8) +
          SH_C3[1] * x * y * z * k(9) +
          SH_C3[2] * y * (4 * zz - xx - yy) * k(10) +
          SH_C3[3] * z * (2 * zz - 3 * xx - 3 * yy) * k(11) +
          SH_C3[4] * x * (4 * zz - xx - yy) * k(12) +
          SH_C3[5] * z * (xx - yy) * k(13) +
          SH_C3[6] * x * (xx - 3 * yy) * k(14);
      }
    }
    rgb[c] += sum;
  }
}

function clamp01(value) {
  return value < 0 ? 0 : value > 1 ? 1 : value;
}

/**
 * Linear light to sRGB, done once per gaussian on the way into the colour texture.
 *
 * The decoded colours are linear RGB, and the default drawing buffer is read back as
 * sRGB, so something has to encode. Doing it here rather than per fragment means the
 * compositing below happens on encoded values — a simplification, and one a renderer that
 * cares about it fixes by blending into a linear float target and encoding once at the
 * end. That target is a fifth of this file again, and it is not what the page is for.
 */
function linearToSrgb(value) {
  return value <= 0.0031308 ? value * 12.92 : 1.055 * Math.pow(value, 1 / 2.4) - 0.055;
}

function createTexture(gl) {
  const texture = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, texture);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  return texture;
}

function linkProgram(gl, vertexSource, fragmentSource) {
  const program = gl.createProgram();
  gl.attachShader(program, compile(gl, gl.VERTEX_SHADER, vertexSource));
  gl.attachShader(program, compile(gl, gl.FRAGMENT_SHADER, fragmentSource));
  gl.linkProgram(program);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
    throw new Error(`the viewer's shader program did not link: ${gl.getProgramInfoLog(program)}`);
  }
  return program;
}

function compile(gl, type, source) {
  const shader = gl.createShader(type);
  gl.shaderSource(shader, source);
  gl.compileShader(shader);
  if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
    throw new Error(`the viewer's shader did not compile: ${gl.getShaderInfoLog(shader)}`);
  }
  return shader;
}
