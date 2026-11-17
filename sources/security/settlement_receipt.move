// Copyright (c) ZengLLQ
// SPDX-License-Identifier: MIT

/// # Linear Hot-Potato Batch Settlement Receipt
///
/// Enforces atomic, conservation-preserving batch execution via Move's linear
/// type system. `SettlementBatchReceipt` possesses **no abilities** (`copy`,
/// `drop`, `store`, and `key` are all omitted).
///
/// Consequently, any transaction that initiates a batch settlement via
/// `create_receipt` **must** route all matched CoW rings and residual AMM taps
/// and explicitly consume the receipt in `consume_receipt` within the exact
/// same transaction, proving:
/// - Zero residual asset imbalance (`total_debited == total_credited` per asset)
/// - At least one intent was cleared (or explicit empty-batch seal)
/// - Minimum claimed solver surplus threshold was achieved
module equinox_clear::settlement_receipt {
    use std::vector;

    // =========================================================================
    // Error Constants
    // =========================================================================

    /// Solver failed to deliver the minimum surplus promised in their winning bid
    const ERR_SURPLUS_BELOW_BID: u64 = 2201;
    /// Asset conservation violated: residual net delta is non-zero
    const ERR_UNBALANCED_ASSET_DELTA: u64 = 2202;
    /// Batch ID mismatch on receipt operation
    const ERR_BATCH_MISMATCH: u64 = 2203;

    // =========================================================================
    // Linear Hot-Potato Struct (Zero Abilities)
    // =========================================================================

    /// Tracked asset-level net flow inside a single atomic settlement transaction.
    struct AssetDelta has copy, drop, store {
        asset_id: u64,
        /// Amount drawn from user escrows / AMM pools into batch clearing
        debited_in: u128,
        /// Amount credited back to users / AMM pools / treasury
        credited_out: u128
    }

    /// Hot-potato token binding the entire lifecycle of an atomic batch settlement.
    struct SettlementBatchReceipt {
        batch_id: u64,
        solver: address,
        min_required_surplus_usd: u128,
        accumulated_surplus_usd: u128,
        accumulated_fees_usd: u128,
        matched_intents: u64,
        ring_count: u64,
        amm_taps: u64,
        asset_deltas: vector<AssetDelta>
    }

    // =========================================================================
    // Creation, Recording & Consumption
    // =========================================================================

    public fun create_receipt(
        batch_id: u64,
        solver: address,
        min_required_surplus_usd: u128
    ): SettlementBatchReceipt {
        SettlementBatchReceipt {
            batch_id,
            solver,
            min_required_surplus_usd,
            accumulated_surplus_usd: 0,
            accumulated_fees_usd: 0,
            matched_intents: 0,
            ring_count: 0,
            amm_taps: 0,
            asset_deltas: vector::empty<AssetDelta>()
        }
    }

    public fun batch_id(receipt: &SettlementBatchReceipt): u64 {
        receipt.batch_id
    }

    public fun solver(receipt: &SettlementBatchReceipt): address {
        receipt.solver
    }

    public fun matched_intents(receipt: &SettlementBatchReceipt): u64 {
        receipt.matched_intents
    }

    public fun accumulated_surplus_usd(receipt: &SettlementBatchReceipt): u128 {
        receipt.accumulated_surplus_usd
    }

    /// Records a debit (input into the clearing batch) for `asset_id`.
    public fun record_debit(receipt: &mut SettlementBatchReceipt, asset_id: u64, amount: u128) {
        if (amount == 0) {
            return
        };
        let idx = find_or_insert_asset(&mut receipt.asset_deltas, asset_id);
        let entry = vector::borrow_mut(&mut receipt.asset_deltas, idx);
        entry.debited_in = entry.debited_in + amount;
    }

    /// Records a credit (output from the clearing batch) for `asset_id`.
    public fun record_credit(receipt: &mut SettlementBatchReceipt, asset_id: u64, amount: u128) {
        if (amount == 0) {
            return
        };
        let idx = find_or_insert_asset(&mut receipt.asset_deltas, asset_id);
        let entry = vector::borrow_mut(&mut receipt.asset_deltas, idx);
        entry.credited_out = entry.credited_out + amount;
    }

    public fun record_cow_ring(
        receipt: &mut SettlementBatchReceipt,
        batch_id: u64,
        intents_filled: u64,
        surplus_usd: u128,
        fees_usd: u128
    ) {
        assert!(receipt.batch_id == batch_id, ERR_BATCH_MISMATCH);
        receipt.ring_count = receipt.ring_count + 1;
        receipt.matched_intents = receipt.matched_intents + intents_filled;
        receipt.accumulated_surplus_usd = receipt.accumulated_surplus_usd + surplus_usd;
        receipt.accumulated_fees_usd = receipt.accumulated_fees_usd + fees_usd;
    }

    public fun record_amm_tap(
        receipt: &mut SettlementBatchReceipt,
        batch_id: u64,
        intents_filled: u64,
        surplus_usd: u128,
        fees_usd: u128
    ) {
        assert!(receipt.batch_id == batch_id, ERR_BATCH_MISMATCH);
        receipt.amm_taps = receipt.amm_taps + 1;
        receipt.matched_intents = receipt.matched_intents + intents_filled;
        receipt.accumulated_surplus_usd = receipt.accumulated_surplus_usd + surplus_usd;
        receipt.accumulated_fees_usd = receipt.accumulated_fees_usd + fees_usd;
    }

    /// Destructures and burns the hot-potato receipt after verifying:
    /// 1. Every asset has exact conservation (`debited_in == credited_out`).
    /// 2. Delivered trader surplus meets or exceeds the winning bid's commitment.
    ///
    /// Returns `(batch_id, solver, matched_intents, ring_count, amm_taps, total_surplus_usd, total_fees_usd)`.
    public fun consume_receipt(
        receipt: SettlementBatchReceipt
    ): (u64, address, u64, u64, u64, u128, u128) {
        let SettlementBatchReceipt {
            batch_id,
            solver,
            min_required_surplus_usd,
            accumulated_surplus_usd,
            accumulated_fees_usd,
            matched_intents,
            ring_count,
            amm_taps,
            asset_deltas
        } = receipt;

        assert!(accumulated_surplus_usd >= min_required_surplus_usd, ERR_SURPLUS_BELOW_BID);

        let len = vector::length(&asset_deltas);
        let i = 0;
        while (i < len) {
            let delta = vector::borrow(&asset_deltas, i);
            assert!(delta.debited_in == delta.credited_out, ERR_UNBALANCED_ASSET_DELTA);
            i = i + 1;
        };

        (
            batch_id,
            solver,
            matched_intents,
            ring_count,
            amm_taps,
            accumulated_surplus_usd,
            accumulated_fees_usd
        )
    }

    // =========================================================================
    // Internal Helpers
    // =========================================================================

    fun find_or_insert_asset(deltas: &mut vector<AssetDelta>, asset_id: u64): u64 {
        let len = vector::length(deltas);
        let i = 0;
        while (i < len) {
            if (vector::borrow(deltas, i).asset_id == asset_id) {
                return i
            };
            i = i + 1;
        };
        vector::push_back(deltas, AssetDelta {
            asset_id,
            debited_in: 0,
            credited_out: 0
        });
        len
    }
}
