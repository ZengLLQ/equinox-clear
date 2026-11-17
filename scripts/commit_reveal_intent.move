// Copyright (c) ZengLLQ
// SPDX-License-Identifier: MIT

script {
    use equinox_clear::batch_router;
    use equinox_clear::intent_book;
    use equinox_clear::merkle_verifier;
    use std::signer;

    /// Demonstrates an atomic trader deposit + sealed intent commit followed
    /// by reveal verification.
    fun commit_reveal_intent_script(
        trader: &signer,
        sell_asset: u64,
        buy_asset: u64,
        sell_amount: u128,
        min_buy_amount: u128,
        expiry_sec: u64,
        now_sec: u64,
        salt: vector<u8>
    ) {
        let trader_addr = signer::address_of(trader);
        let commit_hash = merkle_verifier::compute_intent_commitment(
            trader_addr,
            sell_asset,
            buy_asset,
            sell_amount,
            min_buy_amount,
            true,
            500,
            expiry_sec,
            salt
        );

        let comm_id = batch_router::deposit_and_commit_intent(
            trader,
            sell_asset,
            sell_amount,
            commit_hash,
            expiry_sec,
            now_sec
        );

        intent_book::reveal_intent(
            trader,
            comm_id,
            sell_asset,
            buy_asset,
            sell_amount,
            min_buy_amount,
            true,
            500,
            salt,
            now_sec + 60
        );
    }
}
