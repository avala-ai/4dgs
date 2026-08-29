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
        /// The size of the resource this scene was opened over, captured once at open time.
        ///
        /// A plain number rather than a reference to the transport: the core owns the reader
        /// for the scene's lifetime, and a second owner here would be a second thing to get
        /// wrong. All this needs to answer is "could a declared length possibly fit".
        let resourceByteCount: Int64?

        init(raw: OpaquePointer, resourceByteCount: Int64?) {
            self.raw = raw
            self.resourceByteCount = resourceByteCount
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

    /// Which read path the core should take.
    ///
    /// Not a performance knob. Streamed and indexed are two different consumers, and the
    /// conformance suite runs a runner for each precisely so they can disagree — with one
    /// auto-selecting open, both runners would exercise whichever path the core happened
    /// to pick and a green suite would have tested one thing twice.
    enum OpenMode {
        case auto
        case sequential
        case indexed

        var rawValue: Int32 {
            switch self {
            case .auto: return Int32(FOURDGS_OPEN_AUTO.rawValue)
            case .sequential: return Int32(FOURDGS_OPEN_SEQUENTIAL.rawValue)
            case .indexed: return Int32(FOURDGS_OPEN_INDEXED.rawValue)
            }
        }
    }

    /// Open a scene over a Swift byte-range reader.
    ///
    /// The box is passed **retained**. The core takes ownership of it and calls `release`
    /// once, when the scene is freed; `release` balances that retain. There is no path
    /// where this leaks and none where it double-frees, which is the property that matters
    /// most here — a transport is the one object whose lifetime spans every later call.
    static func open(_ reader: any ByteRangeReader, mode: OpenMode = .auto) throws -> SceneHandle {
        let box = ReaderBox(reader)
        var descriptor = fourdgs_reader()
        descriptor.ctx = Unmanaged.passRetained(box).toOpaque()
        descriptor.size = readerSize
        descriptor.read = readerRead
        descriptor.release = readerRelease

        // Asked before the open, because afterwards the core owns the reader.
        var probe = reader
        let resourceByteCount = try? probe.byteCount()

        var scene: OpaquePointer?
        let status = fourdgs_open_reader_ex(descriptor, mode.rawValue, &scene)
        guard status == ok, let scene else {
            // The core has already released the box on this path; nothing to undo.
            throw error(status)
        }
        return SceneHandle(raw: scene, resourceByteCount: resourceByteCount)
    }

    // MARK: - The scene's own statements

    static func header(_ scene: SceneHandle) throws -> Header {
        var attributes: [String: String] = [:]
        for i in 0..<fourdgs_scene_attribute_count(scene.raw) {
            var key: UnsafePointer<CChar>?
            var keyLength = 0
            var value: UnsafePointer<CChar>?
            var valueLength = 0
            let status = fourdgs_scene_attribute_at(scene.raw, i, &key, &keyLength, &value, &valueLength)
            guard status == ok else { throw error(status) }
            attributes[string(key, keyLength)] = string(value, valueLength)
        }
        return Header(
            profile: try borrowedString(scene, fourdgs_scene_profile),
            library: try borrowedString(scene, fourdgs_scene_library),
            durationSec: fourdgs_scene_duration_sec(scene.raw),
            gaussianCount: fourdgs_scene_gaussian_count(scene.raw),
            cutoff: fourdgs_scene_cutoff(scene.raw),
            temporalModel: try borrowedString(scene, fourdgs_scene_temporal_model),
            aabb: [],
            shDegree: Int(fourdgs_scene_sh_degree(scene.raw)),
            hasAudio: fourdgs_scene_has_audio(scene.raw) != 0,
            hasCompressedChunks: false,
            attributes: attributes)
    }

    /// Whether the file was cut short. The records that were read are still valid; this
    /// says the file ended before the ones after them.
    static func isTruncated(_ scene: SceneHandle) -> Bool {
        fourdgs_scene_truncated(scene.raw) != 0
    }

    /// Whether the Footer's CRC over the summary region verified.
    ///
    /// Three states, not two: `nil` means nothing declared a CRC or nothing checked one,
    /// which is a different claim from a check that ran and failed.
    static func summaryChecksum(_ scene: SceneHandle) -> Bool? {
        switch fourdgs_scene_summary_crc_state(scene.raw) {
        case Int32(FOURDGS_CRC_VERIFIED.rawValue): return true
        case Int32(FOURDGS_CRC_FAILED.rawValue): return false
        default: return nil
        }
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

    /// Every source descriptor, without its encoded payload. A scene with none costs no
    /// descriptor read; payload bytes move only through `audioSourceData`.
    static func audioSources(_ scene: SceneHandle) throws -> [AudioSource] {
        let count = fourdgs_scene_audio_source_count(scene.raw)
        var sources: [AudioSource] = []
        sources.reserveCapacity(Int(count))
        for index in 0..<count {
            var raw = fourdgs_audio_source()
            var status = fourdgs_scene_audio_source(scene.raw, index, &raw)
            guard status == ok else { throw error(status) }

            var keyframes: [AudioSource.Keyframe] = []
            keyframes.reserveCapacity(Int(raw.keyframe_count))
            for keyframeIndex in 0..<raw.keyframe_count {
                var frame = fourdgs_audio_source_keyframe()
                status = fourdgs_scene_audio_source_keyframe(scene.raw, index, keyframeIndex, &frame)
                guard status == ok else { throw error(status) }
                keyframes.append(
                    AudioSource.Keyframe(
                        time: frame.time,
                        position: [frame.position.0, frame.position.1, frame.position.2],
                        rotation: [
                            frame.rotation.0, frame.rotation.1, frame.rotation.2, frame.rotation.3,
                        ]))
            }

            sources.append(
                AudioSource(
                    sourceId: raw.source_id,
                    name: string(raw.name, raw.name_length),
                    codec: string(raw.codec, raw.codec_length),
                    channelLayout: string(raw.channel_layout, raw.channel_layout_length),
                    startSec: raw.start_sec,
                    durationSec: raw.duration_sec,
                    gain: raw.gain,
                    spatial: raw.spatial != 0,
                    loop: raw.loop_playback != 0,
                    position: [raw.position.0, raw.position.1, raw.position.2],
                    rotation: [raw.rotation.0, raw.rotation.1, raw.rotation.2, raw.rotation.3],
                    keyframes: keyframes,
                    interpolation: string(raw.interpolation, raw.interpolation_length),
                    dataSize: raw.data_size))
        }
        return sources
    }

    static func audioSourceData(
        _ scene: SceneHandle, index: UInt32, offset: UInt64, length: UInt64
    ) throws -> [UInt8] {
        if let resourceSize = scene.resourceByteCount, length > UInt64(max(resourceSize, 0)) {
            throw FourDGSError.malformed(
                offset: 0, record: "Audio Data", field: "data",
                reason: "requests \(length) bytes, more than the \(resourceSize) the whole file holds")
        }
        guard length <= UInt64(Int.max) else {
            throw FourDGSError.malformed(
                offset: 0, record: "Audio Data", field: "data",
                reason: "length \(length) is past this platform's allocation limit")
        }
        var data = [UInt8](repeating: 0, count: Int(length))
        if length > 0 {
            let status = data.withUnsafeMutableBufferPointer { buffer in
                fourdgs_scene_audio_source_read(scene.raw, index, offset, length, buffer.baseAddress)
            }
            guard status == ok else { throw error(status) }
        }
        return data
    }

    static func audioSourceState(
        _ scene: SceneHandle, index: UInt32, at t: Double
    ) throws -> AudioSourceState {
        var raw = fourdgs_audio_source_state()
        let status = fourdgs_scene_audio_source_state_at(scene.raw, index, t, &raw)
        guard status == ok else { throw error(status) }
        return AudioSourceState(
            active: raw.active != 0,
            localTime: raw.local_time,
            position: [raw.position.0, raw.position.1, raw.position.2],
            rotation: [raw.rotation.0, raw.rotation.1, raw.rotation.2, raw.rotation.3],
            gain: raw.gain)
    }

    /// A conservative upper bound on a cold seek, including potentially referenced Object Tracks.
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
            sh: sh,
            objectIds: objectIds(scene, count: count))
    }

    // MARK: - The records that are not gaussians

    /// Read the metadata, attachment, camera, statistics and summary-offset records.
    ///
    /// A separate step because these live in the front matter and the tail, and a consumer
    /// that only wants gaussians should not pay for them.
    static func loadRecords(_ scene: SceneHandle) throws {
        let status = fourdgs_scene_load_records(scene.raw)
        guard status == ok else { throw error(status) }
    }

    static func metadata(_ scene: SceneHandle) throws -> [MetadataRecord] {
        var records: [MetadataRecord] = []
        for i in 0..<fourdgs_scene_metadata_count(scene.raw) {
            var name: UnsafePointer<CChar>?
            var nameLength = 0
            var status = fourdgs_scene_metadata_name(scene.raw, i, &name, &nameLength)
            guard status == ok else { throw error(status) }
            var entries: [String: String] = [:]
            for j in 0..<fourdgs_scene_metadata_entry_count(scene.raw, i) {
                var key: UnsafePointer<CChar>?
                var keyLength = 0
                var value: UnsafePointer<CChar>?
                var valueLength = 0
                status = fourdgs_scene_metadata_entry_at(
                    scene.raw, i, j, &key, &keyLength, &value, &valueLength)
                guard status == ok else { throw error(status) }
                entries[string(key, keyLength)] = string(value, valueLength)
            }
            records.append(MetadataRecord(name: string(name, nameLength), entries: entries))
        }
        return records
    }

    static func attachments(_ scene: SceneHandle) throws -> [Attachment] {
        var attachments: [Attachment] = []
        for i in 0..<fourdgs_scene_attachment_count(scene.raw) {
            var name: UnsafePointer<CChar>?
            var nameLength = 0
            var mediaType: UnsafePointer<CChar>?
            var mediaTypeLength = 0
            var status = fourdgs_scene_attachment_name(scene.raw, i, &name, &nameLength)
            guard status == ok else { throw error(status) }
            status = fourdgs_scene_attachment_media_type(scene.raw, i, &mediaType, &mediaTypeLength)
            guard status == ok else { throw error(status) }

            let size = fourdgs_scene_attachment_size(scene.raw, i)
            var data = [UInt8](repeating: 0, count: Int(size))
            if size > 0 {
                status = data.withUnsafeMutableBufferPointer { buffer in
                    fourdgs_scene_attachment_read(scene.raw, i, 0, size, buffer.baseAddress)
                }
                guard status == ok else { throw error(status) }
            }
            attachments.append(
                Attachment(
                    name: string(name, nameLength), mediaType: string(mediaType, mediaTypeLength),
                    data: data))
        }
        return attachments
    }

    static func camera(_ scene: SceneHandle) throws -> Camera? {
        guard fourdgs_scene_has_camera(scene.raw) != 0 else { return nil }
        var raw = fourdgs_camera()
        let status = fourdgs_scene_camera(scene.raw, &raw)
        guard status == ok else { throw error(status) }

        var keyframes: [Camera.Keyframe] = []
        keyframes.reserveCapacity(Int(raw.keyframe_count))
        for i in 0..<raw.keyframe_count {
            var time = 0.0
            var position = [Double](repeating: 0, count: 3)
            var target = [Double](repeating: 0, count: 3)
            let status = position.withUnsafeMutableBufferPointer { p in
                target.withUnsafeMutableBufferPointer { t in
                    fourdgs_scene_camera_keyframe(scene.raw, i, &time, p.baseAddress, t.baseAddress)
                }
            }
            guard status == ok else { throw error(status) }
            keyframes.append(Camera.Keyframe(time: time, position: position, target: target))
        }
        return Camera(
            fovYDeg: raw.fov_y_deg,
            position: [raw.position.0, raw.position.1, raw.position.2],
            target: [raw.target.0, raw.target.1, raw.target.2],
            keyframes: keyframes,
            interpolation: string(raw.interpolation, raw.interpolation_length),
            loop: raw.loop_enabled != 0)
    }

    static func statistics(_ scene: SceneHandle) throws -> Statistics? {
        guard fourdgs_scene_has_statistics(scene.raw) != 0 else { return nil }
        var gaussianCount: UInt64 = 0
        var chunkCount: UInt32 = 0
        var durationSec = 0.0
        var aabb = [Double](repeating: 0, count: 6)
        let status = aabb.withUnsafeMutableBufferPointer { box in
            fourdgs_scene_statistics(scene.raw, &gaussianCount, &chunkCount, &durationSec, box.baseAddress)
        }
        guard status == ok else { throw error(status) }
        return Statistics(
            gaussianCount: gaussianCount, chunkCount: chunkCount, durationSec: durationSec, aabb: aabb)
    }

    static func summaryOffsets(_ scene: SceneHandle) throws -> [SummaryOffset] {
        var offsets: [SummaryOffset] = []
        for i in 0..<fourdgs_scene_summary_offset_count(scene.raw) {
            var opcode: UInt8 = 0
            var start: UInt64 = 0
            var length: UInt64 = 0
            let status = fourdgs_scene_summary_offset_at(scene.raw, i, &opcode, &start, &length)
            guard status == ok else { throw error(status) }
            offsets.append(SummaryOffset(groupOpcode: opcode, groupStart: start, groupLength: length))
        }
        return offsets
    }

    /// Decode one chunk by index, transferring only its bytes — and, under a band cap,
    /// only the bands at or below it.
    static func loadChunk(_ scene: SceneHandle, _ i: UInt32, bandCap: Int?) throws -> GaussianState {
        let status = fourdgs_scene_load_chunk(scene.raw, i, bandCapByte(bandCap))
        guard status == ok else { throw error(status) }
        return resident(scene)
    }

    /// What reading chunk `i` would transfer at this band cap.
    static func bytesForChunk(_ scene: SceneHandle, _ i: UInt32, bandCap: Int?) -> UInt64 {
        fourdgs_scene_bytes_for_chunk(scene.raw, i, bandCapByte(bandCap))
    }

    // MARK: - Encoding

    /// Encode a set of gaussians into a `.4dgs` byte buffer through the core's writer.
    ///
    /// Every column is lent to the core for the length of one call — rule 2 — and the core
    /// copies it in, so nothing here outlives the buffer pointers. The finished bytes are
    /// copied out of the core's buffer before it is freed, exactly as the resident arrays are
    /// on the decode side, so what this returns is owned Swift storage the caller keeps.
    static func encode(
        _ gaussians: GaussianState, durationSec: Double, options: WriteOptions
    ) throws
        -> [UInt8]
    {
        guard let writer = fourdgs_writer_new() else {
            throw FourDGSError.core(
                code: Int32(FOURDGS_STATUS_INTERNAL.rawValue),
                message: "the core could not allocate a writer")
        }
        defer { fourdgs_writer_free(writer) }

        try check(fourdgs_writer_set_duration(writer, durationSec))
        try check(fourdgs_writer_set_cutoff(writer, options.cutoff))
        try check(fourdgs_writer_set_chunking(writer, options.maxDepth, options.minChunkGaussians))
        try check(
            fourdgs_writer_set_summary(
                writer, Int32(options.writeIndex ? 1 : 0), Int32(options.writeStatistics ? 1 : 0),
                Int32(options.writeSummaryOffsets ? 1 : 0), Int32(options.writeCrc ? 1 : 0)))
        try check(fourdgs_writer_set_sh_bands(writer, options.shBands))
        try options.shBitDepths.withUnsafeBufferPointer { buffer in
            try check(fourdgs_writer_set_sh_bit_depths(writer, buffer.baseAddress, buffer.count))
        }
        if !options.profile.isEmpty {
            try setString(options.profile) { fourdgs_writer_set_profile(writer, $0, $1) }
        }
        if !options.library.isEmpty {
            try setString(options.library) { fourdgs_writer_set_library(writer, $0, $1) }
        }
        for (key, value) in options.attributes {
            var keyBytes = Array(key.utf8)
            var valueBytes = Array(value.utf8)
            try keyBytes.withUnsafeMutableBufferPointer { keyBuffer in
                try valueBytes.withUnsafeMutableBufferPointer { valueBuffer in
                    let keyPtr = keyBuffer.baseAddress.map {
                        UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)
                    }
                    let valuePtr = valueBuffer.baseAddress.map {
                        UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)
                    }
                    try check(
                        fourdgs_writer_add_attribute(
                            writer, keyPtr, keyBuffer.count, valuePtr, valueBuffer.count))
                }
            }
        }

        // All nine columns have to be valid at once, because the ABI reads them in one call —
        // hence the nest rather than nine sequential borrows.
        try withColumns(
            [
                gaussians.positions, gaussians.scales, gaussians.rotations, gaussians.colors,
                gaussians.motions, gaussians.muT, gaussians.sigmaT, gaussians.winLo, gaussians.winHi,
            ]
        ) { column in
            try check(
                fourdgs_writer_set_gaussians(
                    writer, UInt32(gaussians.count), column[0], column[1], column[2], column[3],
                    column[4], column[5], column[6], column[7], column[8]))
        }

        if gaussians.shDegree > 0, !gaussians.sh.isEmpty {
            let coefficients = gaussians.shCoefficientsPerComponent
            try gaussians.sh.withUnsafeBufferPointer { buffer in
                try check(
                    fourdgs_writer_set_sh(
                        writer, UInt8(gaussians.shDegree), UInt32(coefficients), buffer.baseAddress,
                        buffer.count))
            }
        }

        var buffer: OpaquePointer?
        let status = fourdgs_writer_encode(writer, &buffer)
        guard status == ok, let buffer else { throw error(status) }
        defer { fourdgs_buffer_free(buffer) }

        let length = fourdgs_buffer_len(buffer)
        guard length > 0, let data = fourdgs_buffer_data(buffer) else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: length))
    }

    /// Lend a string to the core as `(pointer, length)` UTF-8, not NUL-terminated: the
    /// format's own `string` may legally contain a NUL. An empty string crosses as a null
    /// pointer with length zero, which the ABI reads as empty.
    private static func setString(
        _ text: String, _ apply: (UnsafePointer<CChar>?, Int) -> Int32
    ) throws {
        var bytes = Array(text.utf8)
        try bytes.withUnsafeMutableBufferPointer { buffer in
            let chars = buffer.baseAddress.map {
                UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)
            }
            try check(apply(chars, buffer.count))
        }
    }

    /// Hold every column's pointer valid at once, so the ABI can read them all in one call.
    private static func withColumns(
        _ columns: [[Float]], _ body: ([UnsafePointer<Float>?]) throws -> Void
    ) throws {
        var pointers: [UnsafePointer<Float>?] = []
        func descend(_ i: Int) throws {
            if i == columns.count {
                try body(pointers)
                return
            }
            try columns[i].withUnsafeBufferPointer { buffer in
                pointers.append(buffer.baseAddress)
                try descend(i + 1)
                pointers.removeLast()
            }
        }
        try descend(0)
    }

    /// A status that is not OK becomes the same typed error the decode side throws.
    private static func check(_ status: Int32) throws {
        guard status == ok else { throw error(status) }
    }

    // MARK: - keyframe-delta

    // A whole-file temporal model an opened scene refuses, decoded through the core's
    // byte-in / owned-string-out ABI. The core allocates the result; it is copied into Swift
    // storage and freed with `fourdgs_string_free` before either function returns — rule 1,
    // the same discipline the resident arrays and the encoder's buffer follow. The bytes are
    // lent to the core for the length of one call — rule 2 — through `withUnsafeBufferPointer`.

    /// The Header's declared temporal model, read from bytes without opening a scene.
    static func peekTemporalModel(_ bytes: [UInt8]) throws -> String {
        var out: UnsafePointer<CChar>?
        var length = 0
        let status = bytes.withUnsafeBufferPointer { buffer in
            fourdgs_peek_temporal_model(buffer.baseAddress, buffer.count, &out, &length)
        }
        guard status == ok else { throw error(status) }
        let result = string(out, length)
        fourdgs_string_free(out, length)
        return result
    }

    /// Decode a keyframe-delta file to its canonical states JSON. `indexed` chooses the read
    /// path: `false` composes front to back, `true` walks each instant's chain through the
    /// index. Both must agree, which is why the suite runs this on both.
    static func keyframeDeltaStatesJson(_ bytes: [UInt8], indexed: Bool) throws -> String {
        var out: UnsafePointer<CChar>?
        var length = 0
        let status = bytes.withUnsafeBufferPointer { buffer in
            fourdgs_keyframe_delta_states_json(
                buffer.baseAddress, buffer.count, Int32(indexed ? 1 : 0), &out, &length)
        }
        guard status == ok else { throw error(status) }
        let result = string(out, length)
        fourdgs_string_free(out, length)
        return result
    }

    /// Encode a sequence of samples into a `keyframe-delta` file through the core's writer.
    ///
    /// The whole sequence crosses before anything is encoded, because it has to: a delta is a
    /// difference of bins and never a quantization of a difference (spec §11.7), which holds
    /// only if every sample was quantized on grids derived from the whole sequence. So this
    /// pushes each sample into the core's handle and encodes once at the end. Nothing here
    /// subtracts anything — assembling deltas in Swift would be a second encoder with its own
    /// rounding, and the point of a binding is that its bytes are the reference's bytes.
    ///
    /// Each sample's columns are lent for the length of one call — rule 2 — and the core
    /// copies them in, so nothing outlives the buffer pointers. The finished bytes are copied
    /// out before the core's buffer is freed, exactly as ``encode(_:durationSec:options:)``
    /// does.
    static func encodeKeyframeDelta(
        _ samples: [KeyframeDeltaSample], durationSec: Double, options: KeyframeDeltaWriteOptions
    ) throws -> [UInt8] {
        guard let writer = fourdgs_kd_writer_new() else {
            throw FourDGSError.core(
                code: Int32(FOURDGS_STATUS_INTERNAL.rawValue),
                message: "the core could not allocate a keyframe-delta writer")
        }
        defer { fourdgs_kd_writer_free(writer) }

        try check(fourdgs_kd_writer_set_duration(writer, durationSec))
        try check(fourdgs_kd_writer_set_cutoff(writer, options.cutoff))
        try check(
            fourdgs_kd_writer_set_cadence(writer, options.keyframeEvery, options.deltaMode.rawValue))
        for index in options.keyframeAt {
            try check(fourdgs_kd_writer_add_keyframe_at(writer, index))
        }
        try setString(options.profile) { fourdgs_kd_writer_set_profile(writer, $0, $1) }
        if !options.library.isEmpty {
            try setString(options.library) { fourdgs_kd_writer_set_library(writer, $0, $1) }
        }
        try check(
            fourdgs_kd_writer_set_compression(writer, options.codec, options.compressionLevel))

        for sample in samples {
            let gaussians = sample.gaussians
            guard sample.ids.count == gaussians.count else {
                throw FourDGSError.core(
                    code: Int32(FOURDGS_STATUS_INVALID_ARGUMENT.rawValue),
                    message:
                        "the sample at t0 \(sample.t0) carries \(gaussians.count) gaussians and "
                        + "\(sample.ids.count) ids; a delta names gaussians by id, so the two are "
                        + "one list")
            }
            // The ids and all nine columns have to be valid at once, because the ABI reads
            // them in one call — hence the nest, as on the gaussian-birth side.
            try sample.ids.withUnsafeBufferPointer { identity in
                try withColumns(
                    [
                        gaussians.positions, gaussians.scales, gaussians.rotations, gaussians.colors,
                        gaussians.motions, gaussians.muT, gaussians.sigmaT, gaussians.winLo,
                        gaussians.winHi,
                    ]
                ) { column in
                    try check(
                        fourdgs_kd_writer_add_sample(
                            writer, sample.t0, UInt32(gaussians.count), identity.baseAddress,
                            column[0], column[1], column[2], column[3], column[4], column[5],
                            column[6], column[7], column[8]))
                }
            }
        }

        var buffer: OpaquePointer?
        let status = fourdgs_kd_writer_encode(writer, &buffer)
        guard status == ok, let buffer else { throw error(status) }
        defer { fourdgs_buffer_free(buffer) }

        let length = fourdgs_buffer_len(buffer)
        guard length > 0, let data = fourdgs_buffer_data(buffer) else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: length))
    }

    // MARK: - Provenance

    /// Canonical provenance JSON for an opened scene (spec §5.15). Empty when the file
    /// carries none — the binding should omit the key rather than emit null. On the indexed
    /// path the records are fetched here if not already resident; the core computes posesAt
    /// and sensorPosesAt so every binding shares one slerp.
    static func provenanceJson(_ scene: SceneHandle) throws -> String {
        var out: UnsafePointer<CChar>?
        var length = 0
        let status = fourdgs_scene_provenance_json(scene.raw, &out, &length)
        guard status == ok else { throw error(status) }
        let result = string(out, length)
        fourdgs_string_free(out, length)
        return result
    }

    // MARK: - State at an instant

    /// The scene reconstructed at `t`, with Object Tracks composed.
    ///
    /// The core does the reconstruction, which is the point: §3's visibility rule and the
    /// base-then-track composition of §5.15.7 are stated once, in Rust, and this binding
    /// reports them. `Gaussian/state(at:)` is the local §3 arithmetic and knows nothing
    /// about objects — for a scene that carries tracks the two answer different questions.
    static func stateAt(_ scene: SceneHandle, _ t: Double, bandCap: Int?) throws -> InstantState {
        var raw: OpaquePointer?
        let status = fourdgs_scene_state_at(scene.raw, t, bandCapByte(bandCap), &raw)
        guard status == ok else { throw error(status) }
        guard let raw else { return InstantState.empty }
        defer { fourdgs_state_free(raw) }

        let count = Int(fourdgs_state_count(raw))
        guard count > 0 else { return InstantState.empty }

        // Copied, like everything else that crosses this seam: the header states these
        // pointers live until the state is freed, and that is at the end of this call.
        func floats(_ pointer: UnsafePointer<Float>?, _ width: Int) -> [Float] {
            guard let pointer else { return [] }
            return Array(UnsafeBufferPointer(start: pointer, count: count * width))
        }
        let indices: [UInt32] =
            fourdgs_state_indices(raw).map {
                Array(UnsafeBufferPointer(start: $0, count: count))
            } ?? []

        return InstantState(
            indices: indices,
            centers: floats(fourdgs_state_centers(raw), 3),
            orientations: floats(fourdgs_state_orientations(raw), 4),
            opacity: floats(fourdgs_state_opacity(raw), 1))
    }

    // MARK: - Object layer

    /// The `objects` member of the canonical summary (spec §5.15.6-§5.15.7): the Object
    /// Table's entries and the SE(3) tracks with their sampled poses. Empty when the file
    /// carries neither object records nor per-gaussian membership — omit the key rather
    /// than emit null. The core composes base-then-track and samples each pose, so this
    /// binding reports the arithmetic instead of repeating it.
    static func objectsJson(_ scene: SceneHandle) throws -> String {
        try ownedString { out, length in
            fourdgs_scene_objects_json(scene.raw, &out, &length)
        }
    }

    /// The `states` member: composed centres, orientations and membership at each probe.
    ///
    /// Two calls rather than one document because these are two root keys of the summary.
    static func objectStatesJson(_ scene: SceneHandle) throws -> String {
        try ownedString { out, length in
            fourdgs_scene_object_states_json(scene.raw, &out, &length)
        }
    }

    /// Object membership per resident gaussian (spec §6.6), or empty when the scene
    /// carries no `object_id` stream.
    ///
    /// Empty and all-zero are different claims and both are legal: a file with no
    /// membership at all, and a file where every gaussian is background.
    static func objectIds(_ scene: SceneHandle, count: Int) -> [UInt32] {
        guard count > 0, let base = fourdgs_scene_object_ids(scene.raw) else { return [] }
        return Array(UnsafeBufferPointer(start: base, count: count))
    }

    /// Shared shape for the core's owned-string accessors.
    private static func ownedString(
        _ call: (inout UnsafePointer<CChar>?, inout Int) -> Int32
    ) throws -> String {
        var out: UnsafePointer<CChar>?
        var length = 0
        let status = call(&out, &length)
        guard status == ok else { throw error(status) }
        let result = string(out, length)
        fourdgs_string_free(out, length)
        return result
    }

    // MARK: - Strings

    /// A string the core lends us, copied into Swift storage before the call returns.
    ///
    /// Length-delimited rather than NUL-terminated, because the format's own `string` type
    /// is length-prefixed and may legally contain a NUL: reading to the first zero byte
    /// would silently truncate a legal value.
    static func string(_ pointer: UnsafePointer<CChar>?, _ length: Int) -> String {
        guard let pointer, length > 0 else { return "" }
        return pointer.withMemoryRebound(to: UInt8.self, capacity: length) { bytes in
            String(decoding: UnsafeBufferPointer(start: bytes, count: length), as: UTF8.self)
        }
    }

    private static func borrowedString(
        _ scene: SceneHandle,
        _ accessor: (OpaquePointer?, UnsafeMutablePointer<UnsafePointer<CChar>?>?, UnsafeMutablePointer<Int>?)
            -> Int32
    ) throws -> String {
        var pointer: UnsafePointer<CChar>?
        var length = 0
        let status = accessor(scene.raw, &pointer, &length)
        guard status == ok else { throw error(status) }
        return string(pointer, length)
    }

    // MARK: - Errors

    private static let ok = Int32(FOURDGS_STATUS_OK.rawValue)

    /// Translate a status into a Swift error, carrying the core's own message.
    ///
    /// The mapping is deliberately partial. A code this binding has no case for becomes
    /// ``FourDGSError/core(code:message:refusal:)`` with the message passed through verbatim, so a
    /// core that grows a failure mode stays diagnosable from Swift rather than being
    /// flattened into "decode failed".
    ///
    /// `fourdgs_last_error` is thread-local and borrowed until the next failure on this
    /// thread, so the message is copied into a Swift `String` here rather than held.
    static func error(_ status: Int32) -> FourDGSError {
        let message = String(cString: fourdgs_last_error())
        // Read beside the message and never held: both are thread-local and both describe
        // the same failure, so reading them together is what keeps a diagnosis from being
        // paired with the identifier of an older one.
        let refusal = lastRefusalCode()
        switch status {
        // The ABI conflates "not a 4dgs file" with "a version this build does not
        // implement" into one status, and from here there is no way to tell which. Rather
        // than guess and name a version byte nobody read, the core's own message is passed
        // through. Swift's `validateMagic` distinguishes the two before the boundary, which
        // is where a caller normally meets them.
        case Int32(FOURDGS_STATUS_UNSUPPORTED_VERSION.rawValue):
            return .core(code: status, message: message, refusal: refusal)
        case Int32(FOURDGS_STATUS_TRUNCATED.rawValue):
            return .truncated(offset: 0, record: message, needed: 0, available: 0)
        case Int32(FOURDGS_STATUS_MALFORMED.rawValue):
            return .malformed(offset: 0, record: "file", field: "", reason: message, refusal: refusal)
        case Int32(FOURDGS_STATUS_UNSUPPORTED_CODEC.rawValue):
            return .unsupportedCodec(offset: 0, record: "Chunk", name: message, refusal: refusal)
        case Int32(FOURDGS_STATUS_IO.rawValue):
            return .unreadableSource(description: message)
        case Int32(FOURDGS_STATUS_OUT_OF_RANGE.rawValue):
            return .invalidRange(offset: 0, count: 0)
        default:
            return .core(code: status, message: message, refusal: refusal)
        }
    }

    /// Which rule the core's last failure on this thread broke, or `nil` when the refusal
    /// table does not name it.
    ///
    /// `nil` is an answer rather than a failure to ask, and the ABI says so twice: the call
    /// returns `FOURDGS_STATUS_OK` while writing a null pointer and a zero length. A
    /// truncated file, an I/O error and a null argument are real errors the table has no
    /// name for, and the sentence for them is in `fourdgs_last_error`.
    ///
    /// The bytes are **not** NUL-terminated. They are read through ``string(_:_:)``, which
    /// copies exactly the length the core reported — `String(cString:)` on this pointer
    /// would run off the end of a `&'static str` that has no terminator, which is the bug
    /// the length in this signature exists to prevent. They are static, so nothing frees
    /// them, and copying is what keeps them from changing under the returned value.
    private static func lastRefusalCode() -> RefusalCode? {
        var pointer: UnsafePointer<CChar>?
        var length = 0
        guard fourdgs_last_refusal_code(&pointer, &length) == ok else { return nil }
        guard pointer != nil, length > 0 else { return nil }
        // An identifier this build has no case for is `nil` rather than a fabricated one: a
        // core that grows an eighth refusal should look unnamed here, not misnamed.
        return RefusalCode(rawValue: string(pointer, length))
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

// MARK: - keyframe-delta (public)

/// The `keyframe-delta` temporal model (spec §11), a whole-file format an opened
/// ``SceneReader`` refuses because its scene reader does not implement it. These bind the
/// core's additive byte-in / string-out surface: the canonical states summary is computed in
/// the Rust core, so a binding does no arithmetic of its own and cannot drift from it.

/// The Header's declared temporal model, read from bytes without opening a scene — what a
/// runner dispatches on before choosing a read path.
public func peekTemporalModel(_ bytes: [UInt8]) throws -> String {
    try Core.peekTemporalModel(bytes)
}

/// Decode a keyframe-delta file to its canonical states JSON. `indexed` chooses the read
/// path: `false` composes front to back, `true` walks each instant's chain through the index.
public func keyframeDeltaStatesJson(_ bytes: [UInt8], indexed: Bool) throws -> String {
    try Core.keyframeDeltaStatesJson(bytes, indexed: indexed)
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
