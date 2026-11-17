// Copyright (c) ZengLLQ
// SPDX-License-Identifier: MIT

/// # Signed 128-Bit Fixed-Point Delta Arithmetic
///
/// Represents signed magnitudes `I128` for net batch imbalance deltas,
/// concentrated tick liquidity net changes, and signed solver deviation metrics
/// without risking unsigned underflow. Zero is strictly canonicalized with
/// `is_neg = false`.
module equinox_clear::signed_delta {

    // =========================================================================
    // Error Constants
    // =========================================================================

    /// Addition or subtraction exceeded u128 magnitude bounds
    const ERR_SIGNED_OVERFLOW: u64 = 1101;
    /// Cannot convert negative signed delta into unsigned magnitude directly
    const ERR_NEGATIVE_TO_UNSIGNED: u64 = 1102;

    const MAX_U128: u128 = 340282366920938463463374607431768211455;

    // =========================================================================
    // Types
    // =========================================================================

    /// Sign-magnitude signed 128-bit integer with canonical zero (`mag == 0 => !is_neg`).
    struct I128 has copy, drop, store {
        mag: u128,
        is_neg: bool
    }

    // =========================================================================
    // Constructors & Inspection
    // =========================================================================

    public fun zero(): I128 {
        I128 { mag: 0, is_neg: false }
    }

    public fun from_u128(val: u128): I128 {
        I128 { mag: val, is_neg: false }
    }

    public fun neg_from_u128(val: u128): I128 {
        if (val == 0) {
            zero()
        } else {
            I128 { mag: val, is_neg: true }
        }
    }

    public fun from_parts(mag: u128, is_neg: bool): I128 {
        if (mag == 0) {
            zero()
        } else {
            I128 { mag, is_neg }
        }
    }

    public fun is_zero(self: &I128): bool {
        self.mag == 0
    }

    public fun is_negative(self: &I128): bool {
        self.is_neg && self.mag > 0
    }

    public fun is_positive(self: &I128): bool {
        !self.is_neg && self.mag > 0
    }

    public fun abs(self: &I128): u128 {
        self.mag
    }

    public fun unwrap_unsigned(self: &I128): u128 {
        assert!(!is_negative(self), ERR_NEGATIVE_TO_UNSIGNED);
        self.mag
    }

    public fun neg(self: &I128): I128 {
        if (self.mag == 0) {
            zero()
        } else {
            I128 { mag: self.mag, is_neg: !self.is_neg }
        }
    }

    // =========================================================================
    // Arithmetic Operations
    // =========================================================================

    public fun add(a: &I128, b: &I128): I128 {
        if (a.mag == 0) {
            return *b
        };
        if (b.mag == 0) {
            return *a
        };

        if (a.is_neg == b.is_neg) {
            assert!(a.mag <= MAX_U128 - b.mag, ERR_SIGNED_OVERFLOW);
            I128 { mag: a.mag + b.mag, is_neg: a.is_neg }
        } else if (a.mag >= b.mag) {
            from_parts(a.mag - b.mag, a.is_neg)
        } else {
            from_parts(b.mag - a.mag, b.is_neg)
        }
    }

    public fun sub(a: &I128, b: &I128): I128 {
        let neg_b = neg(b);
        add(a, &neg_b)
    }

    public fun mul_u128(a: &I128, scalar: u128): I128 {
        if (a.mag == 0 || scalar == 0) {
            return zero()
        };
        let prod = (a.mag as u256) * (scalar as u256);
        assert!(prod <= (MAX_U128 as u256), ERR_SIGNED_OVERFLOW);
        I128 { mag: (prod as u128), is_neg: a.is_neg }
    }

    public fun mul(a: &I128, b: &I128): I128 {
        if (a.mag == 0 || b.mag == 0) {
            return zero()
        };
        let prod = (a.mag as u256) * (b.mag as u256);
        assert!(prod <= (MAX_U128 as u256), ERR_SIGNED_OVERFLOW);
        I128 { mag: (prod as u128), is_neg: a.is_neg != b.is_neg }
    }

    /// Returns `-1` (represented via 0), `0` (1), or `+1` (2):
    /// Specifically returns `true` if `a < b`.
    public fun lt(a: &I128, b: &I128): bool {
        if (a.is_neg && !b.is_neg) {
            a.mag > 0 || b.mag > 0
        } else if (!a.is_neg && b.is_neg) {
            false
        } else if (a.is_neg && b.is_neg) {
            a.mag > b.mag
        } else {
            a.mag < b.mag
        }
    }

    public fun eq(a: &I128, b: &I128): bool {
        a.mag == b.mag && (a.mag == 0 || a.is_neg == b.is_neg)
    }

    public fun lte(a: &I128, b: &I128): bool {
        lt(a, b) || eq(a, b)
    }

    public fun gt(a: &I128, b: &I128): bool {
        !lte(a, b)
    }
}
