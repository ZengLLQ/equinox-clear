// Copyright (c) ZengLLQ
// SPDX-License-Identifier: MIT

#[test_only]
module equinox_clear::intent_book_tests {
    use equinox_clear::escrow_ledger;
    use equinox_clear::intent_book;
    use equinox_clear::merkle_verifier;
    use equinox_clear::test_helpers;

    #[test]
    fun test_commit_reveal_partial_fill_and_cancel() {
        let (_deployer, now) = test_helpers::setup_protocol();
        let alice = test_helpers::create_signer(@0xA1);
        let wad = test_helpers::wad();

        // Alice sells 100 asset_1 for >= 50 asset_2 (partial fills allowed)
        let iid = test_helpers::commit_and_reveal(
            &alice,
            1,
            2,
            100 * wad,
            50 * wad,
            true,
            500, // max 5% fee on surplus
            now + 1000,
            b"alice-salt",
            now
        );

        let (avail1, locked1) = escrow_ledger::balance_of(@0xA1, 1);
        assert!(avail1 == 0 && locked1 == 100 * wad, 1);

        // Partial fill 40% (40 asset_1) delivering 24 asset_2 (pro-rata min is 20 -> surplus = 4 -> fee 5% = 0.2)
        let (_, _, _, surplus, fee) = intent_book::apply_fill(
            iid,
            1,
            40 * wad,
            24 * wad,
            500,
            now + 50
        );
        assert!(surplus == 4 * wad, 2);
        assert!(fee == 200_000_000_000_000_000, 3); // 0.2 WAD

        // Cancel remaining 60 asset_1 -> unlocked back to Alice available balance
        let unlocked = intent_book::cancel_intent(&alice, iid, now + 60);
        assert!(unlocked == 60 * wad, 4);
        let (avail_after, locked_after) = escrow_ledger::balance_of(@0xA1, 1);
        assert!(avail_after == 60 * wad && locked_after == 0, 5);
    }

    #[test]
    #[expected_failure(abort_code = 4105, location = equinox_clear::intent_book)]
    fun test_reveal_tampered_preimage_aborts() {
        let (_deployer, now) = test_helpers::setup_protocol();
        let bob = test_helpers::create_signer(@0xB0B);
        escrow_ledger::deposit(&bob, 1, 1000);

        let h = merkle_verifier::compute_intent_commitment(
            @0xB0B, 1, 2, 1000, 900, true, 500, now + 500, b"secret"
        );
        let cid = intent_book::commit_intent(&bob, h, now + 500, now);
        // Attempt reveal with altered min_buy_amount
        intent_book::reveal_intent(&bob, cid, 1, 2, 1000, 800, true, 500, b"secret", now + 10);
    }

    #[test]
    #[expected_failure(abort_code = 4112, location = equinox_clear::intent_book)]
    fun test_fill_below_limit_price_aborts() {
        let (_deployer, now) = test_helpers::setup_protocol();
        let carol = test_helpers::create_signer(@0xCA90);
        let wad = test_helpers::wad();
        let iid = test_helpers::commit_and_reveal(
            &carol, 1, 2, 100 * wad, 80 * wad, false, 500, now + 500, b"c", now
        );
        // 79 WAD < 80 WAD limit price
        intent_book::apply_fill(iid, 1, 100 * wad, 79 * wad, 500, now + 20);
    }
}
