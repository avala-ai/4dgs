// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * A lossless comparison form for canonical JSON text.
 *
 * JSON.parse would make `1.0` and `1` comparable, but it would also narrow an exact
 * aggregate with hundreds of digits through binary64. This scanner normalizes numeric
 * tokens as decimal coefficient/exponent pairs and never converts them to Number.
 */
export function comparableCanonicalJson(text: string): string {
  let at = 0;
  let out = "";
  while (at < text.length) {
    const char = text[at]!;
    if (/\s/.test(char)) {
      at += 1;
      continue;
    }
    if (char === '"') {
      const start = at++;
      let escaped = false;
      while (at < text.length) {
        const current = text[at++]!;
        if (escaped) escaped = false;
        else if (current === "\\") escaped = true;
        else if (current === '"') break;
      }
      const token = text.slice(start, at);
      out += JSON.stringify(JSON.parse(token));
      continue;
    }
    if (char === "-" || (char >= "0" && char <= "9")) {
      const match = text.slice(at).match(/^(-?)(0|[1-9]\d*)(?:\.(\d+))?(?:[eE]([+-]?\d+))?/);
      if (match === null) throw new Error(`invalid JSON number at character ${at}`);
      out += normalizeDecimal(match[1]!, match[2]!, match[3] ?? "", match[4] ?? "0");
      at += match[0].length;
      continue;
    }
    out += char;
    at += 1;
  }
  return out;
}

function normalizeDecimal(
  sign: string,
  whole: string,
  fraction: string,
  rawExponent: string,
): string {
  let digits = `${whole}${fraction}`.replace(/^0+/, "");
  if (digits.length === 0) return "0e0";
  let exponent = Number(rawExponent) - fraction.length;
  while (digits.endsWith("0")) {
    digits = digits.slice(0, -1);
    exponent += 1;
  }
  return `${sign}${digits}e${exponent}`;
}
