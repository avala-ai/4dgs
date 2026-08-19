// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The canonical JSON the suite diffs implementations on.
///
/// The harness compares parsed values rather than text, so whitespace is free — but the
/// *values* are pinned, and each rule below exists because some pair of languages would
/// otherwise disagree about representation rather than about the format:
///
/// - integers are strings, so a 64-bit value survives a parser backed by doubles;
/// - floats are rounded to six decimals before comparison, and a non-finite one is `null`;
/// - a never-fading gaussian's sigma is `null`, never a sentinel a decoder could reach by
///   accident;
/// - `audioSources` is an array, empty when absent, so multiplicity and both paths are visible;
/// - keys are sorted.
public enum JSON {
    case null
    case bool(Bool)
    /// Already-rounded, already-formatted. Build with ``JSON/number(_:)``.
    case number(String)
    case string(String)
    case array([JSON])
    case object([String: JSON])
    /// A value already serialized as JSON text — used for provenance, which the core emits
    /// as a complete object so every binding shares one slerp rather than reimplementing it.
    case raw(String)

    /// Six decimals, or `null` for a non-finite value.
    ///
    /// `%.6f` rather than arithmetic: it rounds the exact binary value half-to-even, which
    /// is what Python's `round(x, 6)` does, and the two therefore land on the same double
    /// when the harness parses them back. Rounding by `(x * 1e6).rounded() / 1e6` does not
    /// — the multiply introduces its own error, and a value one ulp under a half-way point
    /// goes the other way about once in a few thousand gaussians.
    public static func number(_ value: Double?) -> JSON {
        guard let value, value.isFinite else { return .null }
        let rounded = String(format: "%.6f", value)
        // Signed zero is not a distinct canonical value. Normalize after formatting so
        // small negative values that round to zero follow the same rule as authored -0.
        return .number(rounded == "-0.000000" ? "0.000000" : rounded)
    }

    public static func number(_ value: Float?) -> JSON {
        guard let value else { return .null }
        return number(Double(value))
    }

    /// An integer as a string, per the rule above.
    public static func integer<T: BinaryInteger>(_ value: T) -> JSON {
        .string(String(value))
    }

    public func serialized() -> String {
        var out = ""
        write(into: &out)
        return out
    }

    private func write(into out: inout String) {
        switch self {
        case .null:
            out += "null"
        case .bool(let b):
            out += b ? "true" : "false"
        case .number(let n):
            out += n
        case .string(let s):
            out += Self.quote(s)
        case .raw(let text):
            out += text
        case .array(let items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                item.write(into: &out)
            }
            out += "]"
        case .object(let fields):
            out += "{"
            for (i, key) in fields.keys.sorted().enumerated() {
                if i > 0 { out += "," }
                out += Self.quote(key)
                out += ":"
                fields[key]!.write(into: &out)
            }
            out += "}"
        }
    }

    private static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

/// A string map as a JSON object.
public func jsonMap(_ map: [String: String]) -> JSON {
    .object(map.mapValues { JSON.string($0) })
}
