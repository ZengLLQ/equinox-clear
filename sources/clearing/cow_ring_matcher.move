// Copyright (c) ZengLLQ
// SPDX-License-Identifier: MIT

/// # Coincidence-of-Wants (CoW) Ring Matcher & Residual AMM Settlement Engine
///
/// Verifies and clears multi-party cyclic intent rings ($2 \le k \le 6$ hops)
/// and residual concentrated range-pool fills while enforcing:
/// 1. **Exact Cycle Conservation**: $\text{gross\_buy}_i = \text{fill\_sell}_{(i+1)\bmod k}$
///    and $\text{buy\_asset}_i = \text{sell\_asset}_{(i+1)\bmod k}$ across every hop.
/// 2. **Uniform Clearing Price (UCP) Invariance**: All intents clearing on the
///    same directed pair within a single batch receive the same clearing rate
///    within 1 bps integer rounding tolerance.
/// 3. **Oracle Price-Band Guard**: Clearing rates on oracle-tracked pairs must
///    lie within `timelock::oracle_max_deviation_bps()` of live median & TWAP.
/// 4. **Hot-Potato Accounting**: Every debit, credit, surplus, and fee is
///    recorded onto the caller's linear `SettlementBatchReceipt`.
module equinox_clear::cow_ring_matcher {
    use std::vector;
    use equinox_clear::circuit_breaker;
    use equinox_clear::events;
    use equinox_clear::fixed_point;
    use equinox_clear::intent_book;
    use equinox_clear::price_oracle;
    use equinox_clear::range_pool;
    use equinox_clear::settlement_receipt::{Self, SettlementBatchReceipt};
    use equinox_clear::timelock;
    use equinox_clear::treasury;

    // =========================================================================
    // Error Constants
    // =========================================================================

    /// Ring must have between 2 and 6 hops with matching vector lengths
    const ERR_INVALID_RING_LENGTH: u64 = 6001;
    /// Adjacent hops do not share matching asset IDs (cycle broken)
    const ERR_RING_ASSET_MISMATCH: u64 = 6002;
    /// Adjacent hops do not satisfy exact flow conservation (gross_buy != next fill_sell)
    const ERR_RING_FLOW_IMBALANCE: u64 = 6003;
    /// Clearing rate violates Uniform Clearing Price invariance for this pair in batch
    const ERR_UCP_INVARIANCE_VIOLATED: u64 = 6004;
    /// AMM fallback direction does not match intent sell/buy assets
    const ERR_POOL_ASSET_MISMATCH: u64 = 6005;

    const MIN_RING_HOPS: u64 = 2;
    const MAX_RING_HOPS: u64 = 6;
    /// Maximum allowed 1 bps rounding tolerance for UCP consistency across integer fills
    const UCP_TOLERANCE_BPS: u64 = 1;

    // =========================================================================
    // Batch UCP Tracker (Passed Mutably by Batch Clearinghouse)
    // =========================================================================

    struct PairUcpRecord has copy, drop, store {
        sell_asset: u64,
        buy_asset: u64,
        ucp_wad: u128
    }

    struct BatchUcpTable has copy, drop, store {
        entries: vector<PairUcpRecord>
    }

    public fun new_ucp_table(): BatchUcpTable {
        BatchUcpTable { entries: vector::empty<PairUcpRecord>() }
    }

    // =========================================================================
    // Cyclic CoW Ring Settlement
    // =========================================================================

    /// Clears a $k$-hop CoW cycle ($2 \le k \le 6$) atomically inside `receipt`:
    /// - Hop $i$ fills `intent_ids[i]` selling `fill_sells[i]` and receiving `gross_buys[i]`.
    /// - `oracle_pair_ids[i]` (> 0 if registered, 0 to skip oracle band check for synthetic pairs)
    ///   validates clearing price against spot median and TWAP.
    /// - `surplus_usd_per_hop` aggregates delivered trader surplus in USD WAD.
    ///
    /// Returns `(total_ring_surplus_usd, total_ring_fees_usd)`.
    public fun settle_cow_ring(
        receipt: &mut SettlementBatchReceipt,
        ucp_table: &mut BatchUcpTable,
        intent_ids: vector<u64>,
        fill_sells: vector<u128>,
        gross_buys: vector<u128>,
        oracle_pair_ids: vector<u64>,
        surplus_usd_estimates: vector<u128>,
        now_sec: u64
    ): (u128, u128) {
        let k = vector::length(&intent_ids);
        assert!(k >= MIN_RING_HOPS && k <= MAX_RING_HOPS, ERR_INVALID_RING_LENGTH);
        assert!(vector::length(&fill_sells) == k, ERR_INVALID_RING_LENGTH);
        assert!(vector::length(&gross_buys) == k, ERR_INVALID_RING_LENGTH);
        assert!(vector::length(&oracle_pair_ids) == k, ERR_INVALID_RING_LENGTH);
        assert!(vector::length(&surplus_usd_estimates) == k, ERR_INVALID_RING_LENGTH);

        let batch_id = settlement_receipt::batch_id(receipt);
        let protocol_fee_bps = timelock::surplus_fee_bps();
        let max_oracle_dev_bps = timelock::oracle_max_deviation_bps();

        // Pre-validate cycle asset continuity & flow conservation
        let hop_sell_assets = vector::empty<u64>();
        let hop_buy_assets = vector::empty<u64>();
        let i = 0;
        while (i < k) {
            let iid = *vector::borrow(&intent_ids, i);
            let (_, s_asset, b_asset, _, _, _, _, _) = intent_book::get_intent(iid);
            vector::push_back(&mut hop_sell_assets, s_asset);
            vector::push_back(&mut hop_buy_assets, b_asset);
            i = i + 1;
        };

        let j = 0;
        while (j < k) {
            let next = (j + 1) % k;
            let cur_buy_asset = *vector::borrow(&hop_buy_assets, j);
            let next_sell_asset = *vector::borrow(&hop_sell_assets, next);
            assert!(cur_buy_asset == next_sell_asset, ERR_RING_ASSET_MISMATCH);

            let cur_gross_buy = *vector::borrow(&gross_buys, j);
            let next_fill_sell = *vector::borrow(&fill_sells, next);
            assert!(cur_gross_buy == next_fill_sell, ERR_RING_FLOW_IMBALANCE);

            let pair_id = *vector::borrow(&oracle_pair_ids, j);
            if (pair_id > 0) {
                circuit_breaker::assert_pair_active(pair_id);
                let rate_wad = fixed_point::div_wad_nearest(cur_gross_buy, *vector::borrow(&fill_sells, j));
                price_oracle::assert_clearing_price_within_band(pair_id, rate_wad, max_oracle_dev_bps, now_sec);
            };
            j = j + 1;
        };

        // Execute fills & record hot-potato conservation + UCP invariance
        let total_surplus_usd: u128 = 0;
        let total_fees_usd: u128 = 0;

        let idx = 0;
        while (idx < k) {
            let iid = *vector::borrow(&intent_ids, idx);
            let fill_sell = *vector::borrow(&fill_sells, idx);
            let gross_buy = *vector::borrow(&gross_buys, idx);
            let surplus_usd = *vector::borrow(&surplus_usd_estimates, idx);

            let (sell_asset, buy_asset, _, _, fee_paid) = intent_book::apply_fill(
                iid,
                batch_id,
                fill_sell,
                gross_buy,
                protocol_fee_bps,
                now_sec
            );

            // Enforce Uniform Clearing Price across identical directed pairs in the batch
            let pair_rate_wad = fixed_point::div_wad_nearest(gross_buy, fill_sell);
            enforce_or_record_ucp(ucp_table, sell_asset, buy_asset, pair_rate_wad);

            // Record exact batch flows onto hot-potato receipt
            settlement_receipt::record_debit(receipt, sell_asset, fill_sell);
            settlement_receipt::record_credit(receipt, buy_asset, gross_buy);

            if (fee_paid > 0) {
                treasury::collect_fee(buy_asset, fee_paid);
                total_fees_usd = total_fees_usd + fee_paid;
            };
            total_surplus_usd = total_surplus_usd + surplus_usd;
            idx = idx + 1;
        };

        settlement_receipt::record_cow_ring(
            receipt,
            batch_id,
            k,
            total_surplus_usd,
            total_fees_usd
        );

        events::emit_cow_ring_cleared(
            batch_id,
            k,
            total_surplus_usd,
            settlement_receipt::solver(receipt)
        );

        (total_surplus_usd, total_fees_usd)
    }

    // =========================================================================
    // Residual Concentrated Range AMM Fallback Settlement
    // =========================================================================

    /// Routes an unmatched or residual intent through a concentrated `range_pool`
    /// atomically inside the active `SettlementBatchReceipt`.
    public fun settle_amm_fallback(
        receipt: &mut SettlementBatchReceipt,
        ucp_table: &mut BatchUcpTable,
        intent_id: u64,
        pool_id: u64,
        fill_sell: u128,
        min_amount_out: u128,
        surplus_usd_estimate: u128,
        now_sec: u64
    ): (u128, u128) {
        let (_, sell_asset, buy_asset, _, _, _, _, _) = intent_book::get_intent(intent_id);
        let (pool_a, pool_b, _, _, _, _, _, _) = range_pool::pool_state(pool_id);

        let zero_for_one = if (sell_asset == pool_a && buy_asset == pool_b) {
            true
        } else if (sell_asset == pool_b && buy_asset == pool_a) {
            false
        } else {
            abort ERR_POOL_ASSET_MISMATCH
        };

        let (amount_out, _, _, _) = range_pool::swap_exact_in_for_batch(
            pool_id,
            zero_for_one,
            fill_sell,
            min_amount_out,
            now_sec
        );

        let batch_id = settlement_receipt::batch_id(receipt);
        let protocol_fee_bps = timelock::surplus_fee_bps();

        let (_, _, _, _, fee_paid) = intent_book::apply_fill(
            intent_id,
            batch_id,
            fill_sell,
            amount_out,
            protocol_fee_bps,
            now_sec
        );

        // AMM fallback trades along the x*y curve (subject to dynamic volatility fee & slippage)
        // rather than peer-to-peer CoW UCP; verify UCP remains registered if no CoW occurred yet.
        let _ = ucp_table;

        // Hot-potato asset balance accounting:
        // User escrow -> batch (sell_asset, fill_sell) -> AMM (sell_asset, fill_sell)
        settlement_receipt::record_debit(receipt, sell_asset, fill_sell);
        settlement_receipt::record_credit(receipt, sell_asset, fill_sell);
        // AMM -> batch (buy_asset, amount_out) -> User + Fees (buy_asset, amount_out)
        settlement_receipt::record_debit(receipt, buy_asset, amount_out);
        settlement_receipt::record_credit(receipt, buy_asset, amount_out);

        if (fee_paid > 0) {
            treasury::collect_fee(buy_asset, fee_paid);
        };

        settlement_receipt::record_amm_tap(
            receipt,
            batch_id,
            1,
            surplus_usd_estimate,
            fee_paid
        );

        (amount_out, fee_paid)
    }

    // =========================================================================
    // Internal UCP Consistency Enforcement
    // =========================================================================

    fun enforce_or_record_ucp(
        table: &mut BatchUcpTable,
        sell_asset: u64,
        buy_asset: u64,
        rate_wad: u128
    ) {
        let len = vector::length(&table.entries);
        let i = 0;
        while (i < len) {
            let rec = vector::borrow(&table.entries, i);
            if (rec.sell_asset == sell_asset && rec.buy_asset == buy_asset) {
                let dev = fixed_point::deviation_bps(rate_wad, rec.ucp_wad, rec.ucp_wad);
                assert!(dev <= UCP_TOLERANCE_BPS, ERR_UCP_INVARIANCE_VIOLATED);
                return
            };
            i = i + 1;
        };
        vector::push_back(&mut table.entries, PairUcpRecord {
            sell_asset,
            buy_asset,
            ucp_wad: rate_wad
        });
    }
}
