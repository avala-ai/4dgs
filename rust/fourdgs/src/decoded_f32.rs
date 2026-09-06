// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! Checks the format's binary32 decoded-state range before Rust narrows a value.

use crate::error::{refusal, RefusalKind};
use crate::{Error, Result};

/// Reconstruct one linear grid lane without asking binary64 to evaluate `0 * infinity`.
///
/// Declared steps are finite, but a per-gaussian effective step can exceed binary64 while its
/// zero bin still denotes exactly the finite origin. The format constrains the completed result,
/// not that wider intermediate.
#[inline]
pub(crate) fn linear(bin: i64, step: f64, origin: f64) -> f64 {
    (if bin == 0 { 0.0 } else { bin as f64 * step }) + origin
}

/// Refuse a completed attribute reconstruction that cannot inhabit its declared `f32` lane.
///
/// `context` is deliberately lazy: valid rows take this branch for every floating component,
/// and should not allocate a diagnostic they will never use.
#[inline]
pub(crate) fn ensure(value: f64, context: impl FnOnce() -> String) -> Result<()> {
    const F32_MAX: f64 = f32::MAX as f64;
    if value.is_finite() && (-F32_MAX..=F32_MAX).contains(&value) {
        return Ok(());
    }
    Err(Error::refused(
        refusal::DECODED_F32_OVERFLOW,
        RefusalKind::Malformed,
        format!(
            "{} reconstructs {value}; expected a finite binary32 value in [{}, {}]",
            context(),
            -F32_MAX,
            F32_MAX
        ),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_the_closed_f32_range_and_underflow() {
        for value in [
            -(f32::MAX as f64),
            -0.0,
            0.0,
            f64::from(f32::MIN_POSITIVE) / 2.0,
            f32::MAX as f64,
        ] {
            ensure(value, || "test lane".into()).unwrap();
        }
    }

    #[test]
    fn zero_bin_remains_zero_when_an_effective_step_exceeds_binary64() {
        assert_eq!(linear(0, f64::INFINITY, 0.0), 0.0);
        assert_eq!(linear(0, f64::INFINITY, 4.0), 4.0);
        assert_eq!(linear(1, f64::INFINITY, 0.0), f64::INFINITY);
    }

    #[test]
    fn names_nonfinite_and_out_of_range_results() {
        for value in [
            f64::NAN,
            f64::NEG_INFINITY,
            f64::INFINITY,
            -(f32::MAX as f64) * 2.0,
            (f32::MAX as f64) * 2.0,
        ] {
            let error = ensure(value, || {
                "row 3 attribute scale component x from bin 100 and step 1".into()
            })
            .unwrap_err();
            assert_eq!(error.refusal_code(), Some(refusal::DECODED_F32_OVERFLOW));
            assert!(error.to_string().contains("row 3"), "{error}");
            assert!(error.to_string().contains("finite binary32"), "{error}");
        }
    }
}
