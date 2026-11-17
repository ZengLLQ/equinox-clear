// Copyright (c) ZengLLQ
// SPDX-License-Identifier: MIT

script {
    use equinox_clear::batch_auction;

    /// Executes a 3-way cyclic CoW ring settlement atomically under the
    /// linear hot-potato SettlementBatchReceipt constraint.
    fun settle_cow_batch_script(
        solver: &signer,
        batch_id: u64,
        intent_1: u64,
        intent_2: u64,
        intent_3: u64,
        fill_1: u128,
        fill_2: u128,
        fill_3: u128,
        notional_usd: u128,
        now_sec: u64
    ) {
        let receipt = batch_auction::begin_batch_settlement(solver, batch_id, now_sec);

        batch_auction::execute_cow_ring_in_batch(
            &mut receipt,
            vector[intent_1, intent_2, intent_3],
            vector[fill_1, fill_2, fill_3],
            vector[fill_2, fill_3, fill_1],
            vector[0, 0, 0],
            vector[0, 0, 0],
            now_sec
        );

        batch_auction::finalize_batch_settlement(receipt, notional_usd, false, now_sec);
    }
}
