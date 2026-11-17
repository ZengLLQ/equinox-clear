// Copyright (c) ZengLLQ
// SPDX-License-Identifier: MIT

#[test_only]
module equinox_clear::fixed_point_tests {
    use equinox_clear::fixed_point;

    const WAD: u128 = 1_000_000_000_000_000_000;

    #[test]
    fun test_mul_div_directed_rounding() {
        // (10 * 1) / 3 -> floor = 3, ceil = 4
        assert!(fixed_point::mul_div_down(10, 1, 3) == 3, 1);
        assert!(fixed_point::mul_div_up(10, 1, 3) == 4, 2);
        assert!(fixed_point::mul_div_nearest(10, 1, 3) == 3, 3);
        assert!(fixed_point::mul_div_nearest(11, 1, 3) == 4, 4);

        // Zero numerator safely returns 0 on round up
        assert!(fixed_point::mul_div_up(0, 123, 7) == 0, 5);
    }

    #[test]
    fun test_wad_and_ray_conversions() {
        let a = 2 * WAD + (WAD / 2); // 2.5 WAD
        let b = 4 * WAD;             // 4.0 WAD
        assert!(fixed_point::mul_wad_down(a, b) == 10 * WAD, 1);
        assert!(fixed_point::div_wad_down(10 * WAD, b) == a, 2);

        let r = fixed_point::wad_to_ray(a);
        assert!(r == 2_500_000_000_000_000_000_000_000_000, 3);
        assert!(fixed_point::ray_to_wad(r) == a, 4);
    }

    #[test]
    fun test_sqrt_and_pow() {
        assert!(fixed_point::sqrt_u256(0) == 0, 1);
        assert!(fixed_point::sqrt_u256(1) == 1, 2);
        assert!(fixed_point::sqrt_u256(144) == 12, 3);
        assert!(fixed_point::sqrt_u256(150) == 12, 4);

        // sqrt(4.0 WAD) == 2.0 WAD
        assert!(fixed_point::sqrt_wad(4 * WAD) == 2 * WAD, 5);
        // sqrt(2.0 WAD) approx 1.414213562373095048 WAD
        let s2 = fixed_point::sqrt_wad(2 * WAD);
        assert!(fixed_point::abs_diff_u128(s2, 1_414_213_562_373_095_048) <= 2, 6);

        // (1.5)^3 = 3.375
        let base = WAD + WAD / 2;
        assert!(fixed_point::pow_wad(base, 3) == 3_375_000_000_000_000_000, 7);
    }

    #[test]
    fun test_exp_and_ln_accuracy() {
        // exp(0) = 1.0
        assert!(fixed_point::exp_wad(0) == WAD, 1);
        // exp(1.0) approx 2.718281828459045235
        let e1 = fixed_point::exp_wad(WAD);
        assert!(fixed_point::abs_diff_u128(e1, 2_718_281_828_459_045_235) < 10_000, 2);

        // ln(1.0) = 0
        assert!(fixed_point::ln_wad(WAD) == 0, 3);
        // ln(e) approx 1.0
        let ln_e = fixed_point::ln_wad(e1);
        assert!(fixed_point::abs_diff_u128(ln_e, WAD) < 10_000, 4);

        // ln(exp(5.0)) approx 5.0
        let e5 = fixed_point::exp_wad(5 * WAD);
        let ln_e5 = fixed_point::ln_wad(e5);
        assert!(fixed_point::abs_diff_u128(ln_e5, 5 * WAD) < 100_000, 5);
    }

    #[test]
    fun test_bps_and_deviation() {
        assert!(fixed_point::bps_mul_down(1_000_000, 250) == 25_000, 1);
        assert!(fixed_point::bps_mul_up(101, 50) == 1, 2);
        // 105 vs 100 -> 500 bps
        assert!(fixed_point::deviation_bps(105 * WAD, 100 * WAD, 100 * WAD) == 500, 3);
    }

    #[test]
    #[expected_failure(abort_code = 1001, location = equinox_clear::fixed_point)]
    fun test_div_by_zero_aborts() {
        fixed_point::mul_div_down(10, 20, 0);
    }
}
