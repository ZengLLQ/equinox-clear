// Copyright (c) ZengLLQ
// SPDX-License-Identifier: MIT

#[test_only]
module equinox_clear::cow_ring_tests {
    use equinox_clear::batch_auction;
    use equinox_clear::escrow_ledger;
    use equinox_clear::intent_book;
    use equinox_clear::test_helpers;

    #[test]
    fun test_three_way_cyclic_cow_ring_settlement() {
        let (deployer, now) = test_helpers::setup_protocol();
        let wad = test_helpers::wad();

        // Register oracle pairs: pair 1 (2->1 at 100), pair 2 (3->2 at 0.5)
        test_helpers::setup_oracle_pair(&deployer, 1, 2, 1, 100 * wad, now);
        test_helpers::setup_oracle_pair(&deployer, 2, 3, 2, wad / 2, now);

        let alice = test_helpers::create_signer(@0xA1);
        let bob = test_helpers::create_signer(@0xB2);
        let carol = test_helpers::create_signer(@0xC3);
        let solver = test_helpers::onboard_solver(@0x501, 2_000 * wad, now);

        // 3-way cyclic wants:
        // Alice: sells 1000 asset_1 -> wants >= 9.5 asset_2
        // Bob:   sells 10   asset_2 -> wants >= 19 asset_3
        // Carol: sells 20   asset_3 -> wants >= 980 asset_1
        let i1 = test_helpers::commit_and_reveal(
            &alice, 1, 2, 1000 * wad, 9 * wad + wad / 2, false, 500, now + 1000, b"a", now
        );
        let i2 = test_helpers::commit_and_reveal(
            &bob, 2, 3, 10 * wad, 19 * wad, false, 500, now + 1000, b"b", now
        );
        let i3 = test_helpers::commit_and_reveal(
            &carol, 3, 1, 20 * wad, 980 * wad, false, 500, now + 1000, b"c", now
        );

        let batch_id = batch_auction::start_next_batch(now);
        batch_auction::submit_solver_bid(&solver, batch_id, 100 * wad, 3, now + 130);

        let receipt = batch_auction::begin_batch_settlement(&solver, batch_id, now + 160);
        // Clear 3-hop ring: 1000 asset_1 -> 10 asset_2 -> 20 asset_3 -> 1000 asset_1
        batch_auction::execute_cow_ring_in_batch(
            &mut receipt,
            vector[i1, i2, i3],
            vector[1000 * wad, 10 * wad, 20 * wad],
            vector[10 * wad, 20 * wad, 1000 * wad],
            vector[0, 0, 0],
            vector[50 * wad, 25 * wad, 25 * wad],
            now + 160
        );
        batch_auction::finalize_batch_settlement(receipt, 3_000 * wad, false, now + 160);

        // Verify all 3 intents filled and asset conservation holds across assets 1, 2, 3
        let (_, _, _, _, _, _, _, st1) = intent_book::get_intent(i1);
        let (_, _, _, _, _, _, _, st2) = intent_book::get_intent(i2);
        let (_, _, _, _, _, _, _, st3) = intent_book::get_intent(i3);
        assert!(st1 == intent_book::status_filled(), 1);
        assert!(st2 == intent_book::status_filled(), 2);
        assert!(st3 == intent_book::status_filled(), 3);

        assert!(escrow_ledger::verify_conservation(1), 4);
        assert!(escrow_ledger::verify_conservation(2), 5);
        assert!(escrow_ledger::verify_conservation(3), 6);
    }

    #[test]
    #[expected_failure(abort_code = 6004, location = equinox_clear::cow_ring_matcher)]
    fun test_ucp_invariance_rejects_discriminatory_rates_in_same_batch() {
        let (_deployer, now) = test_helpers::setup_protocol();
        let wad = test_helpers::wad();
        let a1 = test_helpers::create_signer(@0xA1);
        let a2 = test_helpers::create_signer(@0xA2);
        let b1 = test_helpers::create_signer(@0xB1);
        let b2 = test_helpers::create_signer(@0xB2);
        let solver = test_helpers::onboard_solver(@0x501, 2_000 * wad, now);

        // Two identical direction pairs (1->2) vs (2->1)
        let i_a1 = test_helpers::commit_and_reveal(&a1, 1, 2, 100 * wad, 90 * wad, false, 500, now + 1000, b"1", now);
        let i_b1 = test_helpers::commit_and_reveal(&b1, 2, 1, 100 * wad, 90 * wad, false, 500, now + 1000, b"2", now);
        let i_a2 = test_helpers::commit_and_reveal(&a2, 1, 2, 100 * wad, 90 * wad, false, 500, now + 1000, b"3", now);
        let i_b2 = test_helpers::commit_and_reveal(&b2, 2, 1, 120 * wad, 90 * wad, false, 500, now + 1000, b"4", now);

        let batch_id = batch_auction::start_next_batch(now);
        batch_auction::submit_solver_bid(&solver, batch_id, 10 * wad, 4, now + 130);
        let receipt = batch_auction::begin_batch_settlement(&solver, batch_id, now + 160);

        // First pair clears 1->2 at 1.0 WAD
        batch_auction::execute_cow_ring_in_batch(
            &mut receipt,
            vector[i_a1, i_b1],
            vector[100 * wad, 100 * wad],
            vector[100 * wad, 100 * wad],
            vector[0, 0],
            vector[5 * wad, 5 * wad],
            now + 160
        );
        // Second pair attempts to clear 1->2 at 1.2 WAD in SAME batch -> aborts UCP invariance!
        batch_auction::execute_cow_ring_in_batch(
            &mut receipt,
            vector[i_a2, i_b2],
            vector[100 * wad, 120 * wad],
            vector[120 * wad, 100 * wad],
            vector[0, 0],
            vector[5 * wad, 5 * wad],
            now + 160
        );
        batch_auction::finalize_batch_settlement(receipt, 400 * wad, false, now + 160);
    }
}
