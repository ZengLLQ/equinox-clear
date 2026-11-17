// Copyright (c) ZengLLQ
// SPDX-License-Identifier: MIT

#[test_only]
module equinox_clear::oracle_tests {
    use equinox_clear::capabilities;
    use equinox_clear::price_oracle;
    use equinox_clear::test_helpers;

    #[test]
    fun test_multi_feeder_median_and_twap() {
        let (deployer, now) = test_helpers::setup_protocol();
        let wad = test_helpers::wad();

        let f2 = test_helpers::create_signer(@0xF2);
        let f3 = test_helpers::create_signer(@0xF3);
        capabilities::set_oracle_feeder(&deployer, @0xF2, true);
        capabilities::set_oracle_feeder(&deployer, @0xF3, true);

        price_oracle::register_pair(&deployer, 1, 2, 1, 3, 600, 300);

        // Submit 3 prices: 100.0, 102.0, 101.0 -> median = 101.0, conf = 200/101 = ~198 bps <= 300
        price_oracle::submit_quote(&deployer, 1, 100 * wad, now);
        price_oracle::submit_quote(&f2, 1, 102 * wad, now + 5);
        price_oracle::submit_quote(&f3, 1, 101 * wad, now + 10);

        let (med, twap, conf, _) = price_oracle::peek_pair(1);
        assert!(med == 101 * wad, 1);
        assert!(twap == 101 * wad, 2);
        assert!(conf <= 200, 3);

        // Second round shifts median to 103 -> TWAP becomes average(101, 103) = 102
        price_oracle::submit_quote(&deployer, 1, 103 * wad, now + 60);
        price_oracle::submit_quote(&f2, 1, 104 * wad, now + 60);
        price_oracle::submit_quote(&f3, 1, 102 * wad, now + 60);

        let (med2, twap2, _, _) = price_oracle::peek_pair(1);
        assert!(med2 == 103 * wad, 4);
        // TWAP ring holds [101, 102, 103, 103] -> exact mean 102.25 WAD
        assert!(twap2 == 102 * wad + (wad / 4), 5);

        // Clearing price 103.5 is within 300 bps (3%) of both 103 and 102
        price_oracle::assert_clearing_price_within_band(1, 103 * wad + wad / 2, 300, now + 65);
    }

    #[test]
    #[expected_failure(abort_code = 3007, location = equinox_clear::price_oracle)]
    fun test_oracle_band_rejects_manipulated_ucp() {
        let (deployer, now) = test_helpers::setup_protocol();
        let wad = test_helpers::wad();
        test_helpers::setup_oracle_pair(&deployer, 1, 2, 1, 100 * wad, now);
        // 110 WAD deviates 1000 bps (> 300 bps)
        price_oracle::assert_clearing_price_within_band(1, 110 * wad, 300, now + 10);
    }

    #[test]
    #[expected_failure(abort_code = 3006, location = equinox_clear::price_oracle)]
    fun test_stale_oracle_aborts() {
        let (deployer, now) = test_helpers::setup_protocol();
        let wad = test_helpers::wad();
        test_helpers::setup_oracle_pair(&deployer, 1, 2, 1, 100 * wad, now);
        // Max staleness is 600s -> now + 1000 fails
        price_oracle::get_validated_prices(1, now + 1000);
    }
}
