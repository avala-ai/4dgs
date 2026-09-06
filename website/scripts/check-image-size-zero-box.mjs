// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

import { Worker } from "node:worker_threads";

const workerSource = String.raw`
  const { parentPort } = require("node:worker_threads");
  const { HEIF } = require("image-size/types/heif");
  const { ICNS } = require("image-size/types/icns");
  const { JXL } = require("image-size/types/jxl");

  function ascii(bytes, offset, value) {
    bytes.set(Buffer.from(value, "ascii"), offset);
  }

  function u32be(bytes, offset, value) {
    new DataView(bytes.buffer).setUint32(offset, value, false);
  }

  function mustReject(name, calculate) {
    try {
      calculate();
    } catch {
      return;
    }
    throw new Error(name + " accepted a zero-length box");
  }

  const icns = new Uint8Array(16);
  ascii(icns, 0, "icns");
  u32be(icns, 4, 16);
  ascii(icns, 8, "ic07");
  u32be(icns, 12, 0);

  const heif = new Uint8Array(48);
  u32be(heif, 0, 48);
  ascii(heif, 4, "meta");
  u32be(heif, 12, 36);
  ascii(heif, 16, "iprp");
  u32be(heif, 20, 28);
  ascii(heif, 24, "ipco");
  u32be(heif, 28, 0);
  ascii(heif, 32, "ispe");

  const jxl = new Uint8Array(12);
  u32be(jxl, 0, 0);
  ascii(jxl, 4, "jxlp");

  mustReject("ICNS", () => ICNS.calculate(icns));
  mustReject("HEIF", () => HEIF.calculate(heif));
  mustReject("JXL", () => JXL.calculate(jxl));
  parentPort.postMessage("ok");
`;

await new Promise((resolve, reject) => {
  const worker = new Worker(workerSource, { eval: true });
  let settled = false;

  const finish = (callback) => {
    if (settled) return;
    settled = true;
    clearTimeout(timer);
    callback();
  };

  const timer = setTimeout(() => {
    void worker.terminate();
    finish(() => reject(new Error("image-size hung while parsing a zero-length image box")));
  }, 1_000);

  worker.once("message", () => finish(resolve));
  worker.once("error", (error) => finish(() => reject(error)));
  worker.once("exit", (code) => {
    if (code !== 0) finish(() => reject(new Error(`image-size probe worker exited ${code}`)));
  });
});
