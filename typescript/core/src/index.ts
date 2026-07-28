/**
 * @4dgs/core — the 4dgs decoder.
 *
 * In progress. The contract below is stable and is what every transport implements; the
 * decoder built on it lands with the TypeScript milestone.
 */

/**
 * Anything that can report its size and read a byte range.
 *
 * The core depends on this and nothing else. A transport may be an HTTP range reader, a
 * file handle, a Blob, an in-memory buffer, or a cache wrapping another readable — the
 * decoder cannot tell the difference and does not try.
 */
export interface IReadable {
  /** Total size of the resource in bytes. */
  size(): Promise<bigint>;

  /**
   * Read exactly `length` bytes starting at `offset`.
   *
   * Implementations MUST return the requested range or throw. Returning a short read
   * silently is the one behaviour that breaks every caller.
   */
  read(offset: bigint, length: bigint): Promise<Uint8Array>;
}

/** Gaussian state reconstructed at one instant, structure-of-arrays. */
export interface GaussianSet {
  count: number;
  positions: Float32Array;
  scales: Float32Array;
  rotations: Float32Array;
  colors: Float32Array;
}
