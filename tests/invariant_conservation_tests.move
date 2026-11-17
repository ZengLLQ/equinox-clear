// Copyright (c) ZengLLQ
// SPDX-License-Identifier: MIT

#[test_only]
module equinox_clear::invariant_conservation_tests {
    use equinox_clear::batch_auction;
    use equinox_clear::batch_router;
    use equinox_clear::escrow_ledger;
    use equinox_clear::intent_book;
    use equinox_clear::test_helpers;
    use equinox_clear::treasury;

    #[test]
    fun test_multi_batch_conservation_invariant_across_mixed_flows() {
        let (deployer, t0) = test_helpers::setup_protocol();
        let wad = test_helpers::wad();

        let lp = test_helpers::create_signer(@0x1B1);
        let pool_12 = test_helpers::setup_range_pool_with_liquidity(
            &deployer, &lp, 1, 2, 50_000 * wad, 50_000 * wad, wad
        );
        test_helpers::setup_oracle_pair(&deployer, 1, 2, 1, wad, t0);

        let solver = test_helpers::onboard_solver(@0x501, 5_000 * wad, t0);
        let u1 = test_helpers::create_signer(@0x101);
        let u2 = test_helpers::create_signer(@0x102);
        let u3 = test_helpers::create_signer(@0x103);

        // Run 4 sequential batch epochs mixing CoW rings, partial fills, cancellations, and AMM fallback
        let epoch: u64 = 0;
        while (epoch < 4) {
            let base_t = t0 + epoch * 300;
            let amt = ((epoch + 1) as u128) * 100 * wad;
            let min_out = (amt * 90) / 100;

            let i1 = test_helpers::commit_and_reveal(
                &u1, 1, 2, amt, min_out, true, 500, base_t + 2000, b"u1", base_t
            );
            let i2 = test_helpers::commit_and_reveal(
                &u2, 2, 1, amt, min_out, true, 500, base_t + 2000, b"u2", base_t
            );
            let i3 = test_helpers::commit_and_reveal(
                &u3, 1, 2, 50 * wad, 40 * wad, false, 500, base_t + 2000, b"u3", base_t
            );

            let bid = batch_auction::start_next_batch(base_t);
            batch_auction::submit_solver_bid(&solver, bid, 10 * wad, 3, base_t + 130);

            let receipt = batch_auction::begin_batch_settlement(&solver, bid, base_t + 160);
            // Partial 80% fill on CoW pair i1 <-> i2
            let fill_amt = (amt * 80) / 100;
            batch_auction::execute_cow_ring_in_batch(
                &mut receipt,
                vector[i1, i2],
                vector[fill_amt, fill_amt],
                vector[fill_amt, fill_amt],
                vector[0, 0],
                vector[5 * wad, 5 * wad],
                base_t + 160
            );
            // Route i3 via concentrated range pool fallback
            batch_auction::execute_amm_fallback_in_batch(
                &mut receipt,
                i3,
                pool_12,
                50 * wad,
                40 * wad,
                2 * wad,
                base_t + 160
            );
            batch_auction::finalize_batch_settlement(receipt, amt * 2, false, base_t + 160);

            // Cancel remaining 20% of i1 and i2 and verify conservation after every single epoch
            batch_router::cancel_and_withdraw(&u1, i1, 1, base_t + 180);
            intent_book::cancel_intent(&u2, i2, base_t + 180);

            assert!(escrow_ledger::verify_conservation(1), 100 + epoch);
            assert!(escrow_ledger::verify_conservation(2), 200 + epoch);
            assert!(intent_book::active_intent_count() == 0, 300 + epoch);

            epoch = epoch + 1;
        };

        // Confirm cumulative fees in escrow ledger match treasury totals
        let (_, _, _, _, fees1) = escrow_ledger::asset_totals(1);
        let (_, _, _, _, fees2) = escrow_ledger::asset_totals(2);
        assert!(fees1 == treasury::total_asset_treasury(1), 401);
        assert!(fees2 == treasury::total_asset_treasury(2), 402);
        assert!(fees1 > 0 && fees2 > 0, 403);
    }
}
