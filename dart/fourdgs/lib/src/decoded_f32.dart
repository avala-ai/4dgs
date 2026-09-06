// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Checks the format's binary32 decoded-state range before Dart narrows it.
library;

import 'exceptions.dart';

/// Greatest finite IEEE 754 binary32 value (spec section 3.2).
const double fourdgsF32Max = 3.4028234663852886e38;

/// Reconstruct one linear grid lane without making a zero bin inherit overflow.
///
/// Quantization parameters have no global finite magnitude ceiling. A derived
/// effective pitch can therefore overflow binary64 even though bin zero still
/// names exactly zero. Multiplying that pair would produce NaN and turn a legal
/// value into a refusal, so zero is handled by its exact grid meaning first.
double reconstructLinear(int bin, double step, {double? origin}) {
  final scaled = bin == 0 ? 0.0 : bin * step;
  // Do not add a default +0.0: that would turn a legal negative-zero
  // underflow into positive zero on lanes that have no origin.
  return origin == null ? scaled : scaled + origin;
}

/// Enforce the decoded binary32 boundary before a wider value is narrowed.
///
/// [recordOffset] is the byte of the physical state record's opcode. [rowKind]
/// is `gaussian-birth`, `keyframe`, `update`, or `birth`; a Delta Chunk can hold
/// the last two, so naming only the record would still leave the bad stream
/// ambiguous. [inputs] is deliberately lazy: valid rows should not allocate the
/// detailed bin, step, and origin sentence they never use. The temporal-model
/// decoder supplies it at the last place both stored and composed provenance
/// exist.
@pragma('vm:prefer-inline')
double requireDecodedF32(
  double value, {
  required String record,
  required int recordOffset,
  required String rowKind,
  required int row,
  int? gaussianId,
  required String attribute,
  required String component,
  required String Function() inputs,
}) {
  if (value.isFinite && value >= -fourdgsF32Max && value <= fourdgsF32Max) {
    return value;
  }
  final identity =
      gaussianId == null ? '' : ' (gaussian_id ${gaussianId.toUnsigned(32)})';
  throw FourdgsMalformedFile(
    'the $record record opcode at byte $recordOffset, $rowKind row $row'
    '$identity, reconstructs attribute $attribute component $component from '
    '${inputs()} as $value; expected a finite binary32 value '
    'in [-$fourdgsF32Max, $fourdgsF32Max]',
    refusalCode: refusalDecodedF32Overflow,
  );
}
