// Copyright (c) ZengLLQ
// SPDX-License-Identifier: MIT

#[test_only]
module equinox_clear::batch_auction_lifecycle_tests {
    use equinox_clear::batch_auction;
    use equinox_clear::batch_router;
    use equinox_clear::escrow_ledger;
    use equinox_clear::intent_book;
    use equinox_clear::solver_registry;
    use equinox_clear::test_helpers;

    #[test]
    fun test_solver_competition_and_hybrid_cow_plus_amm_settlement() {
        let (deployer, now) = test_helpers::setup_protocol();
        let wad = test_helpers::wad();

        let lp = test_helpers::create_signer(@0x1B1);
        let pool_id = test_helpers::setup_range_pool_with_liquidity(
            &deployer, &lp, 1, 2, 100_000 * wad, 100_000 * wad, wad
        );

        let solver_low = test_helpers::onboard_solver(@0x501, 2_000 * wad, now);
        let solver_high = test_helpers::onboard_solver(@0x502, 2_000 * wad, now);

        let alice = test_helpers::create_signer(@0xA1);
        let bob = test_helpers::create_signer(@0xB2);
        let carol = test_helpers::create_signer(@0xC3);

        // Alice sells 500 asset_1 for >= 450 asset_2 (CoW match with Bob)
        // Bob sells 500 asset_2 for >= 450 asset_1 (CoW match with Alice)
        // Carol sells 200 asset_1 for >= 180 asset_2 (unmatched CoW -> routed via RangePool)
        let i_a = test_helpers::commit_and_reveal(&alice, 1, 2, 500 * wad, 450 * wad, false, 500, now + 1000, b"a", now);
        let i_b = test_helpers::commit_and_reveal(&bob, 2, 1, 500 * wad, 450 * wad, false, 500, now + 1000, b"b", now);
        let i_c = test_helpers::commit_and_reveal(&carol, 1, 2, 200 * wad, 180 * wad, false, 500, now + 1000, b"c", now);

        let batch_id = batch_auction::start_next_batch(now);

        // Two solvers bid; solver_high bids higher surplus (110 vs 60)
        batch_auction::submit_solver_bid(&solver_low, batch_id, 60 * wad, 3, now + 130);
        batch_auction::submit_solver_bid(&solver_high, batch_id, 110 * wad, 3, now + 140);

        let (_, winner, win_bid, bid_cnt, _, _) = batch_auction::batch_summary(batch_id);
        assert!(winner == @0x502 && win_bid == 110 * wad && bid_cnt == 2, 1);

        // Winner settles both the 2-way CoW ring AND Carol's residual AMM fill in one atomic receipt
        let receipt = batch_auction::begin_batch_settlement(&solver_high, batch_id, now + 160);
        batch_auction::execute_cow_ring_in_batch(
            &mut receipt,
            vector[i_a, i_b],
            vector[500 * wad, 500 * wad],
            vector[500 * wad, 500 * wad],
            vector[0, 0],
            vector[50 * wad, 50 * wad],
            now + 160
        );
        batch_auction::execute_amm_fallback_in_batch(
            &mut receipt,
            i_c,
            pool_id,
            200 * wad,
            180 * wad,
            15 * wad,
            now + 160
        );
        batch_auction::finalize_batch_settlement(receipt, 1_200 * wad, false, now + 160);

        let (status, _, _, _, settled_surplus, settled_intents) = batch_auction::batch_summary(batch_id);
        assert!(status == batch_auction::status_settled(), 2);
        assert!(settled_surplus == 115 * wad && settled_intents == 3, 3);
        assert!(escrow_ledger::verify_conservation(1), 4);
        assert!(escrow_ledger::verify_conservation(2), 5);
        assert!(intent_book::active_intent_count() == 0, 6);
    }

    #[test]
    fun test_defaulting_winner_slashed_and_fallback_recovers_batch() {
        let (_deployer, now) = test_helpers::setup_protocol();
        let wad = test_helpers::wad();

        let solver_bad = test_helpers::onboard_solver(@0xBAD, 2_000 * wad, now);
        let solver_good = test_helpers::onboard_solver(@0x600D, 2_000 * wad, now);

        let alice = test_helpers::create_signer(@0xA1);
        let bob = test_helpers::create_signer(@0xB2);
        let i_a = test_helpers::commit_and_reveal(&alice, 1, 2, 100 * wad, 95 * wad, false, 500, now + 1000, b"a", now);
        let i_b = test_helpers::commit_and_reveal(&bob, 2, 1, 100 * wad, 95 * wad, false, 500, now + 1000, b"b", now);

        let batch_id = batch_auction::start_next_batch(now);
        batch_auction::submit_solver_bid(&solver_bad, batch_id, 10 * wad, 2, now + 130);

        // Winner fails to settle before settle_deadline (now + 210)
        // At now + 220, fallback solver steps in -> slashes solver_bad (10% = 200 WAD) & clears intents
        let receipt = batch_auction::begin_fallback_settlement(&solver_good, batch_id, now + 220);
        batch_auction::execute_cow_ring_in_batch(
            &mut receipt,
            vector[i_a, i_b],
            vector[100 * wad, 100 * wad],
            vector[100 * wad, 100 * wad],
            vector[0, 0],
            vector[5 * wad, 5 * wad],
            now + 220
        );
        batch_auction::finalize_batch_settlement(receipt, 200 * wad, true, now + 220);

        let (bad_bond, _, _, _, slashes, _) = solver_registry::solver_info(@0xBAD);
        assert!(bad_bond == 1_800 * wad && slashes == 1, 1);

        let (status, _, _, _, _, _) = batch_auction::batch_summary(batch_id);
        assert!(status == batch_auction::status_fallback_settled(), 2);

        // Verify snapshot view helper works cleanly
        let (cur_id, settled_cnt, _, _, _, _, _) = batch_router::protocol_snapshot(batch_id);
        assert!(cur_id == 1 && settled_cnt == 1, 3);
    }
}
