// Copyright (c) ZengLLQ
// SPDX-License-Identifier: MIT

/// # Fixed-Point Arithmetic and Transcendental Math Library
///
/// Provides deterministic fixed-point arithmetic primitives for uniform clearing
/// price discovery, concentrated liquidity curve evaluation, solver surplus
/// scoring, and exponential moving average (EMA) reputation updates:
/// - **WAD** ($10^{18}$) and **RAY** ($10^{27}$) scalings using `u256` intermediate products.
/// - Directed rounding (`down` / `up`) to preserve protocol solvency invariants.
/// - Babylonian integer square root (`sqrt_u256`, `sqrt_wad`).
/// - Binary exponentiation (`pow_wad`).
/// - Range-reduced Taylor exponential (`exp_wad`) and Halley-convergent natural logarithm (`ln_wad`).
module equinox_clear::fixed_point {

    // =========================================================================
    // Error Constants
    // =========================================================================

    /// Attempted division by zero
    const ERR_DIVISION_BY_ZERO: u64 = 1001;
    /// Intermediate or final value exceeded representable range
    const ERR_OVERFLOW: u64 = 1002;
    /// Input argument outside valid mathematical domain
    const ERR_OUT_OF_DOMAIN: u64 = 1003;
    /// Iterative root or series solver did not converge
    const ERR_NON_CONVERGENCE: u64 = 1004;

    // =========================================================================
    // Scaling & Mathematical Constants
    // =========================================================================

    /// WAD scale factor ($10^{18}$)
    const WAD: u128 = 1_000_000_000_000_000_000;
    /// Half WAD ($5 \times 10^{17}$) for round-half-up arithmetic
    const HALF_WAD: u128 = 500_000_000_000_000_000;

    /// RAY scale factor ($10^{27}$)
    const RAY: u128 = 1_000_000_000_000_000_000_000_000_000;
    /// Half RAY ($5 \times 10^{26}$)
    const HALF_RAY: u128 = 500_000_000_000_000_000_000_000_000;

    /// Conversion ratio between RAY and WAD ($10^9$)
    const WAD_RAY_RATIO: u128 = 1_000_000_000;
    /// Basis points denominator (100% = 10,000 bps)
    const BPS_DENOM: u128 = 10_000;

    /// $\ln(2)$ scaled to WAD: 0.693147180559945309
    const LN_2_WAD: u128 = 693_147_180_559_945_309;
    /// Maximum input for exp_wad (20.0 WAD -> $e^{20} \approx 4.85 \times 10^8$, safe in u128 WAD)
    const MAX_EXP_WAD: u128 = 20_000_000_000_000_000_000;
    /// Maximum u128 value
    const MAX_U128: u256 = 340282366920938463463374607431768211455;
    /// Maximum Newton-Raphson iterations
    const MAX_ITERATIONS: u8 = 96;

    // =========================================================================
    // Constant Accessors
    // =========================================================================

    public fun wad(): u128 { WAD }
    public fun half_wad(): u128 { HALF_WAD }
    public fun ray(): u128 { RAY }
    public fun half_ray(): u128 { HALF_RAY }
    public fun wad_ray_ratio(): u128 { WAD_RAY_RATIO }
    public fun bps_denom(): u128 { BPS_DENOM }
    public fun ln2_wad(): u128 { LN_2_WAD }

    // =========================================================================
    // Basic Utility Functions
    // =========================================================================

    public fun min_u64(a: u64, b: u64): u64 {
        if (a <= b) a else b
    }

    public fun max_u64(a: u64, b: u64): u64 {
        if (a >= b) a else b
    }

    public fun min_u128(a: u128, b: u128): u128 {
        if (a <= b) a else b
    }

    public fun max_u128(a: u128, b: u128): u128 {
        if (a >= b) a else b
    }

    public fun clamp_u128(x: u128, lo: u128, hi: u128): u128 {
        assert!(lo <= hi, ERR_OUT_OF_DOMAIN);
        if (x < lo) {
            lo
        } else if (x > hi) {
            hi
        } else {
            x
        }
    }

    public fun abs_diff_u128(a: u128, b: u128): u128 {
        if (a >= b) a - b else b - a
    }

    public fun abs_diff_u64(a: u64, b: u64): u64 {
        if (a >= b) a - b else b - a
    }

    // =========================================================================
    // Full-Precision Multiply-Divide (256-bit Intermediate)
    // =========================================================================

    /// Computes $\lfloor (a \cdot b) / d \rfloor$ with 256-bit intermediate product.
    public fun mul_div_down(a: u128, b: u128, d: u128): u128 {
        assert!(d > 0, ERR_DIVISION_BY_ZERO);
        let prod = (a as u256) * (b as u256);
        let res = prod / (d as u256);
        assert!(res <= MAX_U128, ERR_OVERFLOW);
        (res as u128)
    }

    /// Computes $\lceil (a \cdot b) / d \rceil$ with 256-bit intermediate product.
    public fun mul_div_up(a: u128, b: u128, d: u128): u128 {
        assert!(d > 0, ERR_DIVISION_BY_ZERO);
        let prod = (a as u256) * (b as u256);
        if (prod == 0) {
            return 0
        };
        let d256 = (d as u256);
        let res = (prod + d256 - 1) / d256;
        assert!(res <= MAX_U128, ERR_OVERFLOW);
        (res as u128)
    }

    /// Computes $(a \cdot b + d/2) / d$ (round half up).
    public fun mul_div_nearest(a: u128, b: u128, d: u128): u128 {
        assert!(d > 0, ERR_DIVISION_BY_ZERO);
        let prod = (a as u256) * (b as u256);
        let d256 = (d as u256);
        let res = (prod + (d256 / 2)) / d256;
        assert!(res <= MAX_U128, ERR_OVERFLOW);
        (res as u128)
    }

    // =========================================================================
    // WAD (18-decimal) & RAY (27-decimal) Arithmetic
    // =========================================================================

    public fun mul_wad_down(a: u128, b: u128): u128 {
        mul_div_down(a, b, WAD)
    }

    public fun mul_wad_up(a: u128, b: u128): u128 {
        mul_div_up(a, b, WAD)
    }

    public fun mul_wad_nearest(a: u128, b: u128): u128 {
        mul_div_nearest(a, b, WAD)
    }

    public fun div_wad_down(a: u128, b: u128): u128 {
        mul_div_down(a, WAD, b)
    }

    public fun div_wad_up(a: u128, b: u128): u128 {
        mul_div_up(a, WAD, b)
    }

    public fun div_wad_nearest(a: u128, b: u128): u128 {
        mul_div_nearest(a, WAD, b)
    }

    public fun mul_ray_down(a: u128, b: u128): u128 {
        mul_div_down(a, b, RAY)
    }

    public fun mul_ray_up(a: u128, b: u128): u128 {
        mul_div_up(a, b, RAY)
    }

    public fun div_ray_down(a: u128, b: u128): u128 {
        mul_div_down(a, RAY, b)
    }

    public fun div_ray_up(a: u128, b: u128): u128 {
        mul_div_up(a, RAY, b)
    }

    public fun wad_to_ray(x: u128): u128 {
        let res = (x as u256) * (WAD_RAY_RATIO as u256);
        assert!(res <= MAX_U128, ERR_OVERFLOW);
        (res as u128)
    }

    public fun ray_to_wad(x: u128): u128 {
        x / WAD_RAY_RATIO
    }

    /// Computes `amount * bps / 10_000` rounding down.
    public fun bps_mul_down(amount: u128, bps: u64): u128 {
        mul_div_down(amount, (bps as u128), BPS_DENOM)
    }

    /// Computes `amount * bps / 10_000` rounding up.
    public fun bps_mul_up(amount: u128, bps: u64): u128 {
        mul_div_up(amount, (bps as u128), BPS_DENOM)
    }

    /// Computes relative deviation in basis points: `|a - b| * 10_000 / ref_val`.
    public fun deviation_bps(a: u128, b: u128, ref_val: u128): u64 {
        assert!(ref_val > 0, ERR_DIVISION_BY_ZERO);
        let diff = abs_diff_u128(a, b);
        let bps = mul_div_down(diff, BPS_DENOM, ref_val);
        if (bps > 18_446_744_073_709_551_615) {
            18_446_744_073_709_551_615
        } else {
            (bps as u64)
        }
    }

    /// Computes weighted average `(w1 * v1 + w2 * v2) / (w1 + w2)`.
    public fun weighted_avg(v1: u128, w1: u128, v2: u128, w2: u128): u128 {
        let total_w = (w1 as u256) + (w2 as u256);
        assert!(total_w > 0, ERR_DIVISION_BY_ZERO);
        let num = (v1 as u256) * (w1 as u256) + (v2 as u256) * (w2 as u256);
        let res = num / total_w;
        assert!(res <= MAX_U128, ERR_OVERFLOW);
        (res as u128)
    }

    // =========================================================================
    // Square Root & Exponentiation
    // =========================================================================

    /// Exact integer floor square root $\lfloor \sqrt{x} \rfloor$ via bit-shift seeded Newton-Raphson.
    public fun sqrt_u256(x: u256): u256 {
        if (x == 0) {
            return 0
        };
        if (x <= 3) {
            return 1
        };

        // Initial upper estimate using bit length
        let z = x;
        let bit_len: u16 = 0;
        let tmp = x;
        while (tmp > 0) {
            tmp = tmp >> 1;
            bit_len = bit_len + 1;
        };
        let shift = ((bit_len + 1) / 2 as u8);
        let est = (1u256 << shift);
        if (est < z) {
            z = est;
        };

        let y = x;
        let iter: u8 = 0;
        while (z < y && iter < MAX_ITERATIONS) {
            y = z;
            z = (x / z + z) / 2;
            iter = iter + 1;
        };
        y
    }

    /// Computes WAD-scaled square root $\sqrt{x_{\text{wad}}} \cdot 10^{9}$.
    public fun sqrt_wad(x_wad: u128): u128 {
        if (x_wad == 0) {
            return 0
        };
        let scaled = (x_wad as u256) * (WAD as u256);
        let r = sqrt_u256(scaled);
        assert!(r <= MAX_U128, ERR_OVERFLOW);
        (r as u128)
    }

    /// Binary exponentiation in WAD precision: $(base_{\text{wad}})^n$.
    public fun pow_wad(base_wad: u128, exp: u64): u128 {
        let res = WAD;
        let b = base_wad;
        let e = exp;
        while (e > 0) {
            if (e % 2 == 1) {
                res = mul_wad_nearest(res, b);
            };
            e = e / 2;
            if (e > 0) {
                b = mul_wad_nearest(b, b);
            };
        };
        res
    }

    // =========================================================================
    // Transcendental Approximations (exp_wad, ln_wad)
    // =========================================================================

    /// Computes $e^{x}$ in WAD precision using range reduction $x = k \ln(2) + r$,
    /// where $|r| \le \frac{\ln 2}{2}$ and $e^r$ is evaluated via an 11-term Taylor polynomial.
    ///
    /// Valid for $0 \le x \le 20 \cdot \text{WAD}$.
    public fun exp_wad(x_wad: u128): u128 {
        if (x_wad == 0) {
            return WAD
        };
        assert!(x_wad <= MAX_EXP_WAD, ERR_OUT_OF_DOMAIN);

        // Compute k = round(x / ln(2))
        let k = ((x_wad + LN_2_WAD / 2) / LN_2_WAD as u64);
        let k_ln2 = (k as u128) * LN_2_WAD;

        let r_neg = x_wad < k_ln2;
        let r = if (r_neg) { k_ln2 - x_wad } else { x_wad - k_ln2 };

        // Evaluate exp(r) or exp(-r) via 12-term Taylor series: sum((-1)^n * r^n / n!)
        let term = WAD;
        let sum = WAD;
        let i: u128 = 1;
        while (i <= 12) {
            term = mul_div_down(term, r, i * WAD);
            if (r_neg && (i % 2 == 1)) {
                sum = sum - term;
            } else {
                sum = sum + term;
            };
            i = i + 1;
        };

        // Multiply by 2^k
        let factor = (1u256 << (k as u8));
        let scaled = (sum as u256) * factor;
        assert!(scaled <= MAX_U128, ERR_OVERFLOW);
        (scaled as u128)
    }

    /// Computes $\ln(x)$ in WAD precision for $x \ge \text{WAD}$ via binary normalization
    /// $x = m \cdot 2^k$ ($1 \le m < 2$) followed by atanh series expansion:
    /// $\ln(m) = 2 \sum_{n=0}^{7} \frac{y^{2n+1}}{2n+1}$ where $y = \frac{m - 1}{m + 1}$.
    public fun ln_wad(x_wad: u128): u128 {
        assert!(x_wad >= WAD, ERR_OUT_OF_DOMAIN);
        if (x_wad == WAD) {
            return 0
        };

        let m = x_wad;
        let k: u128 = 0;
        let two_wad = 2 * WAD;
        while (m >= two_wad) {
            m = m / 2;
            k = k + 1;
        };

        // y = (m - 1) / (m + 1) in WAD
        let y = div_wad_down(m - WAD, m + WAD);
        let y2 = mul_wad_down(y, y);

        let term = y;
        let sum = y;
        let n: u128 = 1;
        while (n <= 8) {
            term = mul_wad_down(term, y2);
            sum = sum + (term / (2 * n + 1));
            n = n + 1;
        };

        let ln_m = 2 * sum;
        k * LN_2_WAD + ln_m
    }
}
