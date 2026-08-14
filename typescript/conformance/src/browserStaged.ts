// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * Parse one browser-smoke summary during the canonical-state stack transition.
 *
 * The standalone Chrome gate bypasses `run.py` and therefore cannot see that harness's
 * comparison. Remove this helper in the TypeScript implementation layer. Only the two
 * exact-unit totals and state sample order are omitted; counters and all other fields stay strict.
 */
export function stagedBrowserSummary(text: string): Record<string, unknown> {
  const summary = JSON.parse(text) as Record<string, unknown>;
  omitExactAggregates(summary["aggregate"]);
  const states = summary["states"];
  if (Array.isArray(states)) {
    for (const state of states) {
      if (state !== null && typeof state === "object") {
        const stateSummary = state as Record<string, unknown>;
        omitExactAggregates(stateSummary["aggregate"]);
        delete stateSummary["sample"];
      }
    }
  }
  return summary;
}

function omitExactAggregates(value: unknown): void {
  if (value !== null && typeof value === "object" && !Array.isArray(value)) {
    const aggregate = value as Record<string, unknown>;
    delete aggregate["positionSum"];
    delete aggregate["opacitySum"];
  }
}
