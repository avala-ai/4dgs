// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

import CFourDGS

/// **The seam.** Every call this package makes into the Rust core goes through this file
/// and no other.
///
/// The Swift SDK is a binding, not a second implementation: there is one decoder in this
/// repository, and hand-writing a parallel one in Swift would give the format two
/// interpretations to keep in agreement. So everything above this file — the model, the
/// errors, the readers, the §3 arithmetic — is Swift, and everything below it is
/// `rust/fourdgs` reached over the C ABI in `rust/fourdgs/include/fourdgs.h`.
///
/// ## Ownership at the boundary
///
/// Four rules, and every unsafe line in this file is one of them:
///
/// 1. **Buffers the core allocates are copied into Swift storage before the call returns.**
///    No Swift value ever points into memory the core owns. The header says the resident
///    arrays are invalidated by the next load on the same scene, so a `GaussianState`
///    holding a view into them would be a use-after-free the moment anyone seeked twice.
///    Copying is what makes the model types honestly `Sendable`.
/// 2. **Buffers Swift lends to the core are lent for the duration of one call**, through
///    `withUnsafeBufferPointer`, and are never retained past it.
/// 3. **A handle is owned by exactly one Swift object**, a `final class` that frees it in
///    `deinit`. That is why `SceneHandle` is a class and not a struct: a struct would be
///    copied by every `var` assignment and freed once per copy.
/// 4. **Strings cross as UTF-8 with an explicit length** wherever the ABI allows it,
///    because the format's own `string` type is length-prefixed and may legally contain a
///    NUL. Where the ABI uses a NUL-terminated C string — paths, codec names, error
///    messages — that is the ABI's contract and is honoured as such.
enum Core {

    // MARK: - Handles

    /// An open scene. One owner, freed once.
    ///
    /// The reader box handed to `fourdgs_open_reader` is released by the core through the
    /// `release` callback, exactly once, when the scene is freed — including when the open
    /// itself fails. So this class must not release it too; doing so is the double-free
    /// this design exists to prevent.
    final class SceneHandle {
        let raw: OpaquePointer

        init(raw: OpaquePointer) {
            self.raw = raw
        }

        deinit {
            fourdgs_scene_free(raw)
        }
    }

    /// Reconstructed state at one instant. Owned by the caller, freed once.
    final class StateHandle {
        let raw: OpaquePointer

        init(raw: OpaquePointer) {
            self.raw = raw
        }

        deinit {
            fourdgs_state_free(raw)
        }
    }

    /// Keeps a Swift reader alive across the C boundary.
    ///
    /// A class, because what crosses is a pointer and the core needs something stable to
    /// point at for the scene's whole life. The `any` existential is deliberate: the core
    /// does not care which transport this is, which is the entire point of the abstraction.
    final class ReaderBox {
        var reader: any ByteRangeReader

        init(_ reader: any ByteRangeReader) {
            self.reader = reader
        }
    }

    // MARK: - Opening

    /// Open a scene over a Swift byte-range reader.
    ///
    /// The box is passed **retained**. The core takes ownership of it and calls `release`
    /// once, when the scene is freed; `release` balances that retain. There is no path
    /// where this leaks and none where it double-frees, which is the property that matters
    /// most here — a transport is the one object whose lifetime spans every later call.
    static func open(_ reader: any ByteRangeReader) throws -> SceneHandle {
        let box = ReaderBox(reader)
        var descriptor = fourdgs_reader()
        descriptor.ctx = Unmanaged.passRetained(box).toOpaque()
        descriptor.size = readerSize
        descriptor.read = readerRead
        descriptor.release = readerRelease

        var scene: OpaquePointer?
        let status = fourdgs_open_reader(descriptor, &scene)
        guard status == ok, let scene else {
            // The core has already released the box on this path; nothing to undo.
            throw error(status)
        }
        return SceneHandle(raw: scene)
    }

    // MARK: - The scene's own statements

    static func header(_ scene: SceneHandle) -> Header {
        Header(
            profile: "",
            library: "",
            durationSec: fourdgs_scene_duration_sec(scene.raw),
            gaussianCount: fourdgs_scene_gaussian_count(scene.raw),
            cutoff: fourdgs_scene_cutoff(scene.raw),
            temporalModel: "",
            aabb: [],
            shDegree: Int(fourdgs_scene_sh_degree(scene.raw)),
            hasAudio: fourdgs_scene_has_audio(scene.raw) != 0,
            hasCompressedChunks: false,
            attributes: [:])
    }

    /// Whether the core opened this file on the indexed path.
    static func isIndexed(_ scene: SceneHandle) -> Bool {
        fourdgs_scene_is_indexed(scene.raw) != 0
    }

    /// The chunk intervals the index declares. Empty for a file with no index, which is a
    /// valid file that has to be read sequentially.
    static func chunkIntervals(_ scene: SceneHandle) throws -> [(Double, Double)] {
        let count = fourdgs_scene_chunk_count(scene.raw)
        var intervals: [(Double, Double)] = []
        intervals.reserveCapacity(Int(count))
        for i in 0..<count {
            var t0 = 0.0
            var t1 = 0.0
            let status = fourdgs_scene_chunk_interval(scene.raw, i, &t0, &t1)
            guard status == ok else { throw error(status) }
            intervals.append((t0, t1))
        }
        return intervals
    }

    /// The soundtrack, or `nil`. Answered from the Header alone — §7's discovery rule — so
    /// a scene without audio costs no read at all.
    static func audio(_ scene: SceneHandle) throws -> Audio? {
        guard fourdgs_scene_has_audio(scene.raw) != 0 else { return nil }
        let codec = fourdgs_scene_audio_codec(scene.raw).map { String(cString: $0) } ?? ""
        let size = fourdgs_scene_audio_size(scene.raw)
        var data = [UInt8](repeating: 0, count: Int(size))
        if size > 0 {
            let status = data.withUnsafeMutableBufferPointer { buffer in
                fourdgs_scene_audio_read(scene.raw, 0, size, buffer.baseAddress)
            }
            guard status == ok else { throw error(status) }
        }
        // `start_sec` has no accessor yet; the ABI exposes the track, not its offset.
        return Audio(codec: codec, startSec: 0, data: data)
    }

    /// What a seek to `t` would transfer, so a consumer can budget before asking.
    static func bytesForTime(_ scene: SceneHandle, _ t: Double, bandCap: Int?) -> UInt64 {
        fourdgs_scene_bytes_for_time(scene.raw, t, bandCapByte(bandCap))
    }

    // MARK: - Gaussians

    /// Decode every chunk into the scene's working set and copy it out.
    static func loadAll(_ scene: SceneHandle, bandCap: Int?) throws -> GaussianState {
        let status = fourdgs_scene_load_all(scene.raw, bandCapByte(bandCap))
        guard status == ok else { throw error(status) }
        return resident(scene)
    }

    /// Decode only the chunks covering `t` and copy the working set out.
    static func load(_ scene: SceneHandle, at t: Double, bandCap: Int?) throws -> GaussianState {
        let status = fourdgs_scene_load_at(scene.raw, t, bandCapByte(bandCap))
        guard status == ok else { throw error(status) }
        return resident(scene)
    }

    /// Copy the resident arrays into Swift storage.
    ///
    /// Rule 1 in full: the header states these pointers are invalidated by the next load on
    /// the same scene, so every one of them is copied here and nothing survives that
    /// borrows from the core.
    private static func resident(_ scene: SceneHandle) -> GaussianState {
        let count = Int(fourdgs_scene_loaded_count(scene.raw))
        guard count > 0 else { return .empty }

        func floats(_ pointer: UnsafePointer<Float>?, _ width: Int) -> [Float] {
            guard let pointer else { return [] }
            return Array(UnsafeBufferPointer(start: pointer, count: count * width))
        }

        let coefficients = Int(fourdgs_scene_sh_coefficients(scene.raw))
        var sh: [UInt8] = []
        if coefficients > 0, let pointer = fourdgs_scene_sh(scene.raw) {
            sh = Array(UnsafeBufferPointer(start: pointer, count: count * coefficients * 3))
        }

        return GaussianState(
            count: count,
            positions: floats(fourdgs_scene_positions(scene.raw), 3),
            scales: floats(fourdgs_scene_scales(scene.raw), 3),
            rotations: floats(fourdgs_scene_rotations(scene.raw), 4),
            colors: floats(fourdgs_scene_colors(scene.raw), 4),
            motions: floats(fourdgs_scene_motions(scene.raw), 3),
            muT: floats(fourdgs_scene_mu_t(scene.raw), 1),
            sigmaT: floats(fourdgs_scene_sigma_t(scene.raw), 1),
            winLo: floats(fourdgs_scene_win_lo(scene.raw), 1),
            winHi: floats(fourdgs_scene_win_hi(scene.raw), 1),
            shDegree: Int(fourdgs_scene_sh_degree(scene.raw)),
            sh: sh)
    }

    // MARK: - Errors

    private static let ok = Int32(FOURDGS_STATUS_OK.rawValue)

    /// Translate a status into a Swift error, carrying the core's own message.
    ///
    /// The mapping is deliberately partial. A code this binding has no case for becomes
    /// ``FourDGSError/core(code:message:)`` with the message passed through verbatim, so a
    /// core that grows a failure mode stays diagnosable from Swift rather than being
    /// flattened into "decode failed".
    ///
    /// `fourdgs_last_error` is thread-local and borrowed until the next failure on this
    /// thread, so the message is copied into a Swift `String` here rather than held.
    static func error(_ status: Int32) -> FourDGSError {
        let message = String(cString: fourdgs_last_error())
        switch status {
        // The ABI conflates "not a 4dgs file" with "a version this build does not
        // implement" into one status, and from here there is no way to tell which. Rather
        // than guess and name a version byte nobody read, the core's own message is passed
        // through. Swift's `validateMagic` distinguishes the two before the boundary, which
        // is where a caller normally meets them.
        case Int32(FOURDGS_STATUS_UNSUPPORTED_VERSION.rawValue):
            return .core(code: status, message: message)
        case Int32(FOURDGS_STATUS_TRUNCATED.rawValue):
            return .truncated(offset: 0, record: message, needed: 0, available: 0)
        case Int32(FOURDGS_STATUS_MALFORMED.rawValue):
            return .malformed(offset: 0, record: "file", field: "", reason: message)
        case Int32(FOURDGS_STATUS_UNSUPPORTED_CODEC.rawValue):
            return .unsupportedCodec(offset: 0, record: "Chunk", name: message)
        case Int32(FOURDGS_STATUS_IO.rawValue):
            return .unreadableSource(description: message)
        case Int32(FOURDGS_STATUS_OUT_OF_RANGE.rawValue):
            return .invalidRange(offset: 0, count: 0)
        default:
            return .core(code: status, message: message)
        }
    }

    /// `\x89 4 D G S 1 \r \n`. §4.1.
    static let magic: [UInt8] = [0x89, 0x34, 0x44, 0x47, 0x53, 0x31, 0x0D, 0x0A]

    /// The 8-byte magic, checked on the Swift side before any byte crosses the ABI.
    ///
    /// The core checks it too. Doing it here as well is not redundancy for its own sake: a
    /// binding's job at an FFI boundary is to reject what it can before handing untrusted
    /// input to code that cannot throw, and this is the cheapest possible instance of that
    /// — eight bytes, one comparison, and the file is either ours or it is not.
    static func validateMagic<S: ByteRangeReader>(_ source: inout S) throws {
        let found = try source.read(offset: 0, count: magic.count)
        guard found.count == magic.count else {
            throw FourDGSError.truncated(
                offset: 0, record: "magic", needed: Int64(magic.count), available: Int64(found.count))
        }
        // The version byte is diagnosed separately from the rest, because "a .4dgs from the
        // future" and "not a .4dgs" send a reader to different places.
        if Array(found[0..<5]) == Array(magic[0..<5]), Array(found[6...]) == Array(magic[6...]),
            found[5] != magic[5]
        {
            throw FourDGSError.unsupportedMajorVersion(found: found[5], supported: magic[5])
        }
        guard found == magic else {
            throw FourDGSError.notFourDGS(offset: 0, found: found)
        }
    }

    /// `0` means every band the file carries; the ABI takes a cap, not an optional.
    private static func bandCapByte(_ bandCap: Int?) -> UInt8 {
        guard let bandCap else { return 3 }
        return UInt8(clamping: bandCap)
    }
}

// MARK: - The reader callbacks

// Three C function pointers, which is why they are file-scope constants rather than
// closures: a `@convention(c)` function may not capture, so everything they need arrives
// through `ctx`.

private let readerSize: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt64>?) -> Int32 = {
    ctx, out in
    guard let ctx, let out else { return Int32(FOURDGS_STATUS_INVALID_ARGUMENT.rawValue) }
    let box = Unmanaged<Core.ReaderBox>.fromOpaque(ctx).takeUnretainedValue()
    do {
        out.pointee = UInt64(try box.reader.byteCount())
        return Int32(FOURDGS_STATUS_OK.rawValue)
    } catch {
        return Int32(FOURDGS_STATUS_IO.rawValue)
    }
}

private let readerRead:
    @convention(c) (UnsafeMutableRawPointer?, UInt64, UInt64, UnsafeMutablePointer<UInt8>?) -> Int32 = {
        ctx, offset, length, out in
        guard let ctx, let out else { return Int32(FOURDGS_STATUS_INVALID_ARGUMENT.rawValue) }
        let box = Unmanaged<Core.ReaderBox>.fromOpaque(ctx).takeUnretainedValue()
        do {
            let bytes = try box.reader.read(offset: Int64(offset), count: Int(length))
            // The header is explicit that returning OK after a short read breaks every
            // caller. A truncated file is a real and expected input here, and it has to
            // arrive as a status rather than as fewer bytes than the core asked for.
            guard bytes.count == Int(length) else { return Int32(FOURDGS_STATUS_TRUNCATED.rawValue) }
            // The copy happens inside `withUnsafeBufferPointer`. Letting the pointer out
            // of that closure and writing through it afterwards is undefined behaviour
            // even when it appears to work.
            bytes.withUnsafeBufferPointer { buffer in
                if let base = buffer.baseAddress, !buffer.isEmpty {
                    out.update(from: base, count: buffer.count)
                }
            }
            return Int32(FOURDGS_STATUS_OK.rawValue)
        } catch {
            return Int32(FOURDGS_STATUS_IO.rawValue)
        }
    }

private let readerRelease: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ctx in
    guard let ctx else { return }
    // Balances the `passRetained` in `Core.open`. Called exactly once by the core.
    Unmanaged<Core.ReaderBox>.fromOpaque(ctx).release()
}
