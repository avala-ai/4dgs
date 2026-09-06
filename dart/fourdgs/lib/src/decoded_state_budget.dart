// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Aggregate decoded-state accounting for collecting reader operations.
///
/// Per-record ceilings keep one Chunk bounded. A collecting call also needs a
/// ceiling over the state it has retained plus the next decode or composition
/// working set; otherwise many individually legal records can still exhaust a
/// process.
library;

import 'dart:typed_data';

import 'chunk_decoder.dart';
import 'exceptions.dart';

/// The shared default for collecting decoded gaussian state: 512 MiB.
const int defaultMaxDecodedStateBytes = 536870912;

/// Validates the public decoded-state budget option.
///
/// The static [int] type rejects booleans, fractional values and non-finite
/// numbers at the call boundary. This check owns the remaining invalid values.
int validateMaxDecodedStateBytes(int value) {
  if (value <= 0) {
    throw ArgumentError.value(
      value,
      'maxDecodedStateBytes',
      'must be a positive integer',
    );
  }
  return value;
}

/// Tracks decoded bytes retained by one collecting operation.
///
/// This is public so a collector assembled from incremental APIs can share the
/// same accounting with those APIs. Incremental callers normally omit it: once
/// a yielded value belongs to the caller, it no longer accrues to the library's
/// working set.
class FourdgsDecodedStateBudget {
  FourdgsDecodedStateBudget([
    int maxDecodedStateBytes = defaultMaxDecodedStateBytes,
  ]) : limit = validateMaxDecodedStateBytes(maxDecodedStateBytes);

  /// The caller-selected decoded-state ceiling.
  final int limit;

  int _retainedBytes = 0;

  /// Decoded state already retained by the collecting result.
  int get retainedBytes => _retainedBytes;

  /// Bytes still available before the configured ceiling is reached.
  int get remainingBytes => limit - _retainedBytes;

  Never _exceeded(String phase, String required) {
    throw FourdgsReaderLimit(
      'decoded-state resource limit during $phase: $required; configured '
      'limit is $limit bytes',
    );
  }

  /// Checks a simultaneous decoded allocation without retaining it.
  void check(int additionalBytes, String phase) {
    if (additionalBytes < 0) {
      throw StateError(
        'decoded-state accounting cannot subtract through check',
      );
    }
    checkBigInt(BigInt.from(additionalBytes), phase);
  }

  /// Checks an exact size expression that may exceed the platform [int] range.
  void checkBigInt(BigInt additionalBytes, String phase) {
    if (additionalBytes.isNegative) {
      throw StateError(
        'decoded-state accounting cannot subtract through check',
      );
    }
    final required = BigInt.from(_retainedBytes) + additionalBytes;
    if (required > BigInt.from(limit)) {
      _exceeded(phase, 'at least $required bytes are required');
    }
  }

  /// Checks `rows * bytesPerRow` without allowing size arithmetic to wrap.
  void checkRows(int rows, int bytesPerRow, String phase) {
    if (rows < 0 || bytesPerRow <= 0) {
      throw StateError(
        'decoded-state row accounting requires non-negative rows and a '
        'positive row width',
      );
    }
    if (rows > remainingBytes ~/ bytesPerRow) {
      final required =
          BigInt.from(_retainedBytes) +
          BigInt.from(rows) * BigInt.from(bytesPerRow);
      _exceeded(phase, 'at least $required bytes are required');
    }
  }

  /// Charges decoded output that remains owned by the collecting result.
  void retain(int addedBytes, String phase) {
    check(addedBytes, phase);
    _retainedBytes += addedBytes;
  }

  /// Releases a buffer that a collector replaced rather than returned.
  void release(int releasedBytes) {
    if (releasedBytes < 0 || releasedBytes > _retainedBytes) {
      throw StateError('decoded-state accounting released non-retained bytes');
    }
    _retainedBytes -= releasedBytes;
  }
}

/// Element capacity retained by one decoded gaussian-birth Chunk.
int decodedChunkStateBytes(FourdgsDecodedChunk chunk) {
  int bytes =
      chunk.positions.lengthInBytes +
      chunk.scales.lengthInBytes +
      chunk.rotations.lengthInBytes +
      chunk.colors.lengthInBytes +
      chunk.motions.lengthInBytes +
      chunk.muT.lengthInBytes +
      chunk.sigmaT.lengthInBytes +
      chunk.winLo.lengthInBytes +
      chunk.winHi.lengthInBytes +
      chunk.windowIndex.lengthInBytes;
  bytes += chunk.sourceGroup?.lengthInBytes ?? 0;
  bytes += chunk.sourceIndex?.lengthInBytes ?? 0;
  bytes += chunk.objectId?.lengthInBytes ?? 0;
  for (final band in chunk.shBands.values) {
    bytes += band.lengthInBytes;
  }
  return bytes;
}

/// Element capacity the final gaussian-birth result is about to allocate.
///
/// The merged SH buffer is passed through rather than copied and is therefore
/// charged by the caller at the merge step, not here.
int gaussianSetAssemblyBytes(List<FourdgsDecodedChunk> chunks) {
  int count = 0;
  for (final chunk in chunks) {
    count += chunk.count;
  }
  int bytesPerGaussian = 21 * 4;
  if (chunks.any((chunk) => chunk.sourceGroup != null)) {
    bytesPerGaussian += 4;
  }
  if (chunks.any((chunk) => chunk.sourceIndex != null)) {
    bytesPerGaussian += 4;
  }
  if (chunks.any((chunk) => chunk.objectId != null)) {
    bytesPerGaussian += 4;
  }
  return count * bytesPerGaussian;
}

/// Capacity of the single SH buffer produced by [mergeChunkBands].
int mergedShStateBytes(List<int> counts, List<Map<int, Uint8List>> chunkBands) {
  final present = <int>{for (final bands in chunkBands) ...bands.keys};
  if (present.isEmpty) return 0;
  final highest = present.reduce((a, b) => a > b ? a : b);
  final coefficients = shBandRange[highest]?.last ?? 0;
  final total = counts.fold<int>(0, (sum, count) => sum + count);
  return total * 3 * coefficients;
}
