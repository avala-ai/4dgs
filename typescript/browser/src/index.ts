// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * `@4dgs/browser` — the two transports a browser needs.
 *
 * Both implement `IReadable` from `@4dgs/core` and nothing else. The decoder cannot tell
 * a local `Blob` from a remote URL and does not try; that is what lets the same decode
 * path run against a file the user dropped in and a scene on the other side of a CDN.
 */

import type { IReadable } from "@4dgs/core";

/** A `Blob` or `File`, read by slicing. */
export class BlobReadable implements IReadable {
  constructor(private readonly blob: Blob) {}

  size(): Promise<bigint> {
    return Promise.resolve(BigInt(this.blob.size));
  }

  async read(offset: bigint, length: bigint): Promise<Uint8Array> {
    const at = Number(offset);
    const n = Number(length);
    if (at < 0 || n < 0 || at + n > this.blob.size) {
      throw new RangeError(`range [${at}, ${at + n}) is outside the ${this.blob.size}-byte blob`);
    }
    return new Uint8Array(await this.blob.slice(at, at + n).arrayBuffer());
  }
}

export interface HttpRangeOptions {
  /** Passed to every request, for authorization, credentials or an abort signal. */
  readonly init?: RequestInit;
  /** Injected for testing, or to route through a cache. Defaults to global `fetch`. */
  readonly fetch?: typeof fetch;
  /**
   * Size in bytes, when the caller already knows it.
   *
   * Supplying it skips the probe request entirely, which is worth doing when the size
   * came from a manifest the application already fetched.
   */
  readonly size?: bigint;
}

/**
 * An HTTP resource read with range requests.
 *
 * The size comes from a `HEAD`, and a server that refuses `HEAD` — some CDNs and most
 * signed-URL schemes do — is handled by falling back to a one-byte ranged `GET`, whose
 * `Content-Range` carries the total. Either way the size costs one small request, once.
 *
 * A server that ignores `Range` and answers `200` with the whole body is detected rather
 * than trusted: silently decoding from the wrong offset is the failure this class exists
 * to prevent.
 */
export class HttpRangeReadable implements IReadable {
  private readonly fetchImpl: typeof fetch;
  private knownSize: bigint | null;

  constructor(
    private readonly url: string,
    private readonly options: HttpRangeOptions = {},
  ) {
    this.fetchImpl = options.fetch ?? globalThis.fetch.bind(globalThis);
    this.knownSize = options.size ?? null;
  }

  async size(): Promise<bigint> {
    if (this.knownSize !== null) return this.knownSize;

    const head = await this.fetchImpl(this.url, { ...this.options.init, method: "HEAD" });
    if (head.ok) {
      const length = head.headers.get("content-length");
      const acceptsRanges = head.headers.get("accept-ranges");
      if (acceptsRanges !== null && acceptsRanges.toLowerCase() === "none") {
        throw new Error(`${this.url} answers accept-ranges: none, so it cannot be seeked`);
      }
      if (length !== null) {
        this.knownSize = BigInt(length);
        return this.knownSize;
      }
    }

    // No usable HEAD: ask for one byte and read the total out of Content-Range.
    const probe = await this.fetchImpl(this.url, {
      ...this.options.init,
      headers: { ...headersOf(this.options.init), Range: "bytes=0-0" },
    });
    if (probe.status !== 206) {
      throw new Error(
        `${this.url} answered ${probe.status} to a range request; ` +
          "a resource that cannot be ranged must be downloaded and decoded from bytes",
      );
    }
    const contentRange = probe.headers.get("content-range");
    const total = contentRange?.split("/")[1];
    if (total === undefined || total === "*" || total === "") {
      throw new Error(`${this.url} answered 206 without a total size in content-range`);
    }
    this.knownSize = BigInt(total);
    return this.knownSize;
  }

  async read(offset: bigint, length: bigint): Promise<Uint8Array> {
    if (length === 0n) return new Uint8Array(0);
    const last = offset + length - 1n;
    const response = await this.fetchImpl(this.url, {
      ...this.options.init,
      headers: { ...headersOf(this.options.init), Range: `bytes=${offset}-${last}` },
    });
    if (response.status !== 206) {
      throw new Error(
        `${this.url} answered ${response.status} to bytes=${offset}-${last}; ` +
          "a 200 means the server ignored the range and returned the whole resource",
      );
    }
    const bytes = new Uint8Array(await response.arrayBuffer());
    if (BigInt(bytes.byteLength) !== length) {
      throw new Error(
        `${this.url} returned ${bytes.byteLength} bytes for a ${length}-byte range; ` +
          "a short read cannot be distinguished from correct data further on",
      );
    }
    return bytes;
  }
}

function headersOf(init: RequestInit | undefined): Record<string, string> {
  if (init?.headers === undefined) return {};
  if (init.headers instanceof Headers) return Object.fromEntries(init.headers.entries());
  if (Array.isArray(init.headers)) return Object.fromEntries(init.headers);
  return { ...init.headers };
}
