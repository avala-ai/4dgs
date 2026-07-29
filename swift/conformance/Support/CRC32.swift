// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// CRC-32 (IEEE), the same one `zlib.crc32` computes.
///
/// Used where a summary has to prove it read the bytes and not merely their length: an
/// attachment, an audio track, and the spherical-harmonic coefficients — all of which a
/// decoder could throw away and still match a summary that only counted them.
public enum CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    public static func compute<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
