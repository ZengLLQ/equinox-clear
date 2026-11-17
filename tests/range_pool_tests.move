// Copyright (c) ZengLLQ
// SPDX-License-Identifier: MIT

#[test_only]
module equinox_clear::range_pool_tests {
    use equinox_clear::escrow_ledger;
    use equinox_clear::range_pool;
    use equinox_clear::test_helpers;

    #[test]
    fun test_concentrated_liquidity_swap_and_fee_collection() {
        let (deployer, now) = test_helpers::setup_protocol();
        let lp = test_helpers::create_signer(@0x1B1);
        let wad = test_helpers::wad();

        // Pool 1: asset 1 / asset 2 initialized at 1.0 WAD with 100,000 each
        let pool_id = test_helpers::setup_range_pool_with_liquidity(
            &deployer,
            &lp,
            1,
            2,
            100_000 * wad,
            100_000 * wad,
            wad
        );

        let (quoted_out, fee_bps) = range_pool::quote_exact_in(pool_id, true, 10_000 * wad);
        assert!(fee_bps == 30, 1);
        assert!(quoted_out > 9_000 * wad && quoted_out < 10_000 * wad, 2);

        // Execute large swap to induce tick jump and verify dynamic volatility fee increase
        let (out1, fee1, dyn1, _) = range_pool::swap_exact_in_for_batch(
            pool_id,
            true,
            10_000 * wad,
            quoted_out,
            now + 10
        );
        assert!(out1 == quoted_out, 3);
        assert!(fee1 > 0 && dyn1 == 30, 4);

        // Next swap immediately observes elevated dynamic fee from EMA tick volatility
        let (_, dyn2) = range_pool::quote_exact_in(pool_id, false, 1_000 * wad);
        assert!(dyn2 > 30, 5);

        // LP harvests accumulated fee_a
        let (owed_a, owed_b) = range_pool::collect_position_fees(&lp, 1);
        assert!(owed_a > 0 && owed_b == 0, 6);
        let (lp_avail_a, _) = escrow_ledger::balance_of(@0x1B1, 1);
        assert!(lp_avail_a == owed_a, 7);
    }
}
