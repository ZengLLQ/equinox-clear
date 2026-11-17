// Copyright (c) ZengLLQ
// SPDX-License-Identifier: MIT

#[test_only]
module equinox_clear::signed_delta_tests {
    use equinox_clear::signed_delta;

    #[test]
    fun test_signed_add_sub_cancel() {
        let p = signed_delta::from_u128(250);
        let n = signed_delta::neg_from_u128(400);
        let sum = signed_delta::add(&p, &n);
        assert!(signed_delta::is_negative(&sum), 1);
        assert!(signed_delta::abs(&sum) == 150, 2);

        let back = signed_delta::add(&sum, &signed_delta::from_u128(150));
        assert!(signed_delta::is_zero(&back), 3);
        assert!(!signed_delta::is_negative(&back), 4);
    }

    #[test]
    fun test_signed_mul_and_ordering() {
        let a = signed_delta::neg_from_u128(20);
        let b = signed_delta::neg_from_u128(5);
        let prod = signed_delta::mul(&a, &b);
        assert!(signed_delta::is_positive(&prod), 1);
        assert!(signed_delta::unwrap_unsigned(&prod) == 100, 2);

        assert!(signed_delta::lt(&a, &b), 3); // -20 < -5
        assert!(signed_delta::gt(&b, &a), 4); // -5 > -20
    }

    #[test]
    #[expected_failure(abort_code = 1102, location = equinox_clear::signed_delta)]
    fun test_unwrap_negative_aborts() {
        let neg = signed_delta::neg_from_u128(42);
        signed_delta::unwrap_unsigned(&neg);
    }
}
