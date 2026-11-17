// Copyright (c) ZengLLQ
// SPDX-License-Identifier: MIT

/// # Frequent Batch Auction & Solver Competition Clearinghouse
///
/// Orchestrates discrete-time frequent batch auctions (`batch_id = 1, 2, ...`)
/// across four deterministic epoch phases:
/// 1. **Commit Phase** (`[start, commit_end)`): Traders submit sealed SHA3-256 intent commitments.
/// 2. **Reveal Phase** (`[commit_end, reveal_end)`): Traders reveal intents and lock escrow.
/// 3. **Solver Bidding Phase** (`[reveal_end, bid_end)`): Bonded solvers compete by
///    submitting surplus-maximizing execution bids; highest score wins exclusive
///    settlement rights.
/// 4. **Settlement Phase** (`[bid_end, settle_deadline]`): Winning solver opens a linear
///    `SettlementBatchReceipt` hot potato, clears CoW rings + residual range-pool
///    taps, and finalizes the batch. If the winner defaults past `settle_deadline`,
///    anyone may slash the defaulting solver and settle in permissionless fallback mode!
module equinox_clear::batch_auction {
    use std::signer;
    use aptos_std::table::{Self, Table};
    use equinox_clear::capabilities;
    use equinox_clear::circuit_breaker;
    use equinox_clear::cow_ring_matcher::{Self, BatchUcpTable};
    use equinox_clear::events;
    use equinox_clear::settlement_receipt::{Self, SettlementBatchReceipt};
    use equinox_clear::solver_registry;

    // =========================================================================
    // Error Constants
    // =========================================================================

    /// Clearinghouse already initialized
    const ERR_ALREADY_INITIALIZED: u64 = 6101;
    /// Invalid epoch phase duration configuration
    const ERR_INVALID_EPOCH_CONFIG: u64 = 6102;
    /// Batch ID not found
    const ERR_BATCH_NOT_FOUND: u64 = 6103;
    /// Operation not permitted in current batch phase or timestamp
    const ERR_WRONG_BATCH_PHASE: u64 = 6104;
    /// Caller is not the winning solver for this batch
    const ERR_NOT_WINNING_SOLVER: u64 = 6105;
    /// No winning bid submitted for this batch
    const ERR_NO_SOLVER_BID: u64 = 6106;
    /// Batch already settled
    const ERR_BATCH_ALREADY_SETTLED: u64 = 6107;
    /// Settlement deadline has not expired yet for fallback slashing
    const ERR_DEADLINE_NOT_EXPIRED: u64 = 6108;
    /// Cannot start a new batch before current batch concludes
    const ERR_ACTIVE_BATCH_IN_PROGRESS: u64 = 6109;

    const STATUS_OPEN: u8 = 0;
    const STATUS_SETTLED: u8 = 1;
    const STATUS_FALLBACK_SETTLED: u8 = 2;

    // =========================================================================
    // Types & Storage
    // =========================================================================

    struct EpochConfig has copy, drop, store {
        commit_duration_sec: u64,
        reveal_duration_sec: u64,
        bid_duration_sec: u64,
        settle_duration_sec: u64
    }

    struct BatchEpoch has store {
        batch_id: u64,
        start_sec: u64,
        commit_end_sec: u64,
        reveal_end_sec: u64,
        bid_end_sec: u64,
        settle_deadline_sec: u64,
        winning_solver: address,
        winning_bid_surplus_usd: u128,
        winning_expected_fills: u64,
        bid_count: u64,
        winner_slashed: bool,
        settled_surplus_usd: u128,
        settled_fees_usd: u128,
        settled_intents: u64,
        status: u8,
        ucp_table: BatchUcpTable
    }

    struct ClearinghouseState has key {
        config: EpochConfig,
        current_batch_id: u64,
        batches: Table<u64, BatchEpoch>,
        total_batches_settled: u64,
        total_surplus_delivered_usd: u128
    }

    // =========================================================================
    // Initialization & Epoch Transitions
    // =========================================================================

    public fun initialize(
        deployer: &signer,
        commit_duration_sec: u64,
        reveal_duration_sec: u64,
        bid_duration_sec: u64,
        settle_duration_sec: u64
    ) {
        assert!(!exists<ClearinghouseState>(@equinox_clear), ERR_ALREADY_INITIALIZED);
        assert!(
            commit_duration_sec > 0 &&
            reveal_duration_sec > 0 &&
            bid_duration_sec > 0 &&
            settle_duration_sec > 0,
            ERR_INVALID_EPOCH_CONFIG
        );

        move_to(deployer, ClearinghouseState {
            config: EpochConfig {
                commit_duration_sec,
                reveal_duration_sec,
                bid_duration_sec,
                settle_duration_sec
            },
            current_batch_id: 0,
            batches: table::new<u64, BatchEpoch>(),
            total_batches_settled: 0,
            total_surplus_delivered_usd: 0
        });
    }

    public fun update_epoch_config(
        caller: &signer,
        commit_duration_sec: u64,
        reveal_duration_sec: u64,
        bid_duration_sec: u64,
        settle_duration_sec: u64
    ) acquires ClearinghouseState {
        capabilities::assert_governance_or_admin(signer::address_of(caller));
        assert!(
            commit_duration_sec > 0 &&
            reveal_duration_sec > 0 &&
            bid_duration_sec > 0 &&
            settle_duration_sec > 0,
            ERR_INVALID_EPOCH_CONFIG
        );
        let state = borrow_global_mut<ClearinghouseState>(@equinox_clear);
        state.config = EpochConfig {
            commit_duration_sec,
            reveal_duration_sec,
            bid_duration_sec,
            settle_duration_sec
        };
    }

    /// Starts the next batch auction epoch once the prior batch is settled or expired.
    public fun start_next_batch(now_sec: u64): u64 acquires ClearinghouseState {
        circuit_breaker::assert_not_globally_paused();
        let state = borrow_global_mut<ClearinghouseState>(@equinox_clear);
        if (state.current_batch_id > 0) {
            let prev = table::borrow(&state.batches, state.current_batch_id);
            assert!(
                prev.status != STATUS_OPEN || now_sec > prev.settle_deadline_sec,
                ERR_ACTIVE_BATCH_IN_PROGRESS
            );
        };

        let next_id = state.current_batch_id + 1;
        state.current_batch_id = next_id;

        let c_end = now_sec + state.config.commit_duration_sec;
        let r_end = c_end + state.config.reveal_duration_sec;
        let b_end = r_end + state.config.bid_duration_sec;
        let s_end = b_end + state.config.settle_duration_sec;

        table::add(&mut state.batches, next_id, BatchEpoch {
            batch_id: next_id,
            start_sec: now_sec,
            commit_end_sec: c_end,
            reveal_end_sec: r_end,
            bid_end_sec: b_end,
            settle_deadline_sec: s_end,
            winning_solver: @0x0,
            winning_bid_surplus_usd: 0,
            winning_expected_fills: 0,
            bid_count: 0,
            winner_slashed: false,
            settled_surplus_usd: 0,
            settled_fees_usd: 0,
            settled_intents: 0,
            status: STATUS_OPEN,
            ucp_table: cow_ring_matcher::new_ucp_table()
        });

        events::emit_batch_epoch_started(next_id, c_end, r_end, b_end, s_end);
        next_id
    }

    // =========================================================================
    // Solver Bid Competition
    // =========================================================================

    /// Bonded solvers submit competing execution bids during `[reveal_end, bid_end)`.
    /// Highest proposed trader surplus wins (ties broken by higher expected fills).
    public fun submit_solver_bid(
        solver: &signer,
        batch_id: u64,
        proposed_surplus_usd: u128,
        expected_fill_count: u64,
        now_sec: u64
    ) acquires ClearinghouseState {
        circuit_breaker::assert_not_globally_paused();
        let solver_addr = signer::address_of(solver);
        solver_registry::assert_eligible_solver(solver_addr, now_sec);

        let state = borrow_global_mut<ClearinghouseState>(@equinox_clear);
        assert!(table::contains(&state.batches, batch_id), ERR_BATCH_NOT_FOUND);
        let batch = table::borrow_mut(&mut state.batches, batch_id);

        assert!(batch.status == STATUS_OPEN, ERR_BATCH_ALREADY_SETTLED);
        assert!(now_sec >= batch.reveal_end_sec && now_sec < batch.bid_end_sec, ERR_WRONG_BATCH_PHASE);

        batch.bid_count = batch.bid_count + 1;
        let is_better = proposed_surplus_usd > batch.winning_bid_surplus_usd ||
            (proposed_surplus_usd == batch.winning_bid_surplus_usd && expected_fill_count > batch.winning_expected_fills) ||
            batch.winning_solver == @0x0;

        if (is_better) {
            batch.winning_solver = solver_addr;
            batch.winning_bid_surplus_usd = proposed_surplus_usd;
            batch.winning_expected_fills = expected_fill_count;
        };

        events::emit_solver_bid_submitted(batch_id, solver_addr, proposed_surplus_usd, expected_fill_count);
    }

    // =========================================================================
    // Hot-Potato Atomic Batch Settlement
    // =========================================================================

    /// Initiates exclusive settlement for the winning solver during `[bid_end, settle_deadline]`,
    /// returning a linear `SettlementBatchReceipt` hot potato.
    public fun begin_batch_settlement(
        solver: &signer,
        batch_id: u64,
        now_sec: u64
    ): SettlementBatchReceipt acquires ClearinghouseState {
        circuit_breaker::assert_not_globally_paused();
        let solver_addr = signer::address_of(solver);
        solver_registry::assert_eligible_solver(solver_addr, now_sec);

        let state = borrow_global_mut<ClearinghouseState>(@equinox_clear);
        assert!(table::contains(&state.batches, batch_id), ERR_BATCH_NOT_FOUND);
        let batch = table::borrow_mut(&mut state.batches, batch_id);

        assert!(batch.status == STATUS_OPEN, ERR_BATCH_ALREADY_SETTLED);
        assert!(now_sec >= batch.bid_end_sec && now_sec <= batch.settle_deadline_sec, ERR_WRONG_BATCH_PHASE);
        assert!(batch.winning_solver != @0x0, ERR_NO_SOLVER_BID);
        assert!(batch.winning_solver == solver_addr, ERR_NOT_WINNING_SOLVER);

        solver_registry::record_batch_won(solver_addr);
        settlement_receipt::create_receipt(batch_id, solver_addr, batch.winning_bid_surplus_usd)
    }

    /// Initiates permissionless fallback settlement after `settle_deadline` expires
    /// without settlement. Automatically slashes the defaulting winning solver if any.
    public fun begin_fallback_settlement(
        fallback_solver: &signer,
        batch_id: u64,
        now_sec: u64
    ): SettlementBatchReceipt acquires ClearinghouseState {
        circuit_breaker::assert_not_globally_paused();
        let solver_addr = signer::address_of(fallback_solver);
        solver_registry::assert_eligible_solver(solver_addr, now_sec);

        let state = borrow_global_mut<ClearinghouseState>(@equinox_clear);
        assert!(table::contains(&state.batches, batch_id), ERR_BATCH_NOT_FOUND);
        let batch = table::borrow_mut(&mut state.batches, batch_id);

        assert!(batch.status == STATUS_OPEN, ERR_BATCH_ALREADY_SETTLED);
        assert!(now_sec > batch.settle_deadline_sec, ERR_DEADLINE_NOT_EXPIRED);

        if (batch.winning_solver != @0x0 && !batch.winner_slashed) {
            batch.winner_slashed = true;
            solver_registry::slash_solver(
                batch.winning_solver,
                solver_registry::slash_reason_missed_settlement(),
                now_sec
            );
        };

        // Fallback mode sets minimum surplus requirement to 0 so stranded intents can always clear
        settlement_receipt::create_receipt(batch_id, solver_addr, 0)
    }

    /// Clears a cyclic CoW ring inside the active batch and updates the batch UCP table.
    public fun execute_cow_ring_in_batch(
        receipt: &mut SettlementBatchReceipt,
        intent_ids: vector<u64>,
        fill_sells: vector<u128>,
        gross_buys: vector<u128>,
        oracle_pair_ids: vector<u64>,
        surplus_usd_estimates: vector<u128>,
        now_sec: u64
    ): (u128, u128) acquires ClearinghouseState {
        let batch_id = settlement_receipt::batch_id(receipt);
        let state = borrow_global_mut<ClearinghouseState>(@equinox_clear);
        assert!(table::contains(&state.batches, batch_id), ERR_BATCH_NOT_FOUND);
        let batch = table::borrow_mut(&mut state.batches, batch_id);
        assert!(batch.status == STATUS_OPEN, ERR_BATCH_ALREADY_SETTLED);

        cow_ring_matcher::settle_cow_ring(
            receipt,
            &mut batch.ucp_table,
            intent_ids,
            fill_sells,
            gross_buys,
            oracle_pair_ids,
            surplus_usd_estimates,
            now_sec
        )
    }

    /// Routes an unmatched or residual intent via concentrated range pool fallback.
    public fun execute_amm_fallback_in_batch(
        receipt: &mut SettlementBatchReceipt,
        intent_id: u64,
        pool_id: u64,
        fill_sell: u128,
        min_amount_out: u128,
        surplus_usd_estimate: u128,
        now_sec: u64
    ): (u128, u128) acquires ClearinghouseState {
        let batch_id = settlement_receipt::batch_id(receipt);
        let state = borrow_global_mut<ClearinghouseState>(@equinox_clear);
        assert!(table::contains(&state.batches, batch_id), ERR_BATCH_NOT_FOUND);
        let batch = table::borrow_mut(&mut state.batches, batch_id);
        assert!(batch.status == STATUS_OPEN, ERR_BATCH_ALREADY_SETTLED);

        cow_ring_matcher::settle_amm_fallback(
            receipt,
            &mut batch.ucp_table,
            intent_id,
            pool_id,
            fill_sell,
            min_amount_out,
            surplus_usd_estimate,
            now_sec
        )
    }

    /// Consumes the linear `SettlementBatchReceipt` hot potato, verifies sliding-window
    /// volume rate limits, updates solver reputation, and marks the batch settled.
    public fun finalize_batch_settlement(
        receipt: SettlementBatchReceipt,
        notional_volume_usd: u128,
        is_fallback: bool,
        now_sec: u64
    ) acquires ClearinghouseState {
        let (
            batch_id,
            solver_addr,
            matched_intents,
            ring_count,
            amm_taps,
            total_surplus_usd,
            total_fees_usd
        ) = settlement_receipt::consume_receipt(receipt);

        circuit_breaker::record_and_check_volume(notional_volume_usd, now_sec);

        let state = borrow_global_mut<ClearinghouseState>(@equinox_clear);
        assert!(table::contains(&state.batches, batch_id), ERR_BATCH_NOT_FOUND);
        let batch = table::borrow_mut(&mut state.batches, batch_id);
        assert!(batch.status == STATUS_OPEN, ERR_BATCH_ALREADY_SETTLED);

        batch.status = if (is_fallback) { STATUS_FALLBACK_SETTLED } else { STATUS_SETTLED };
        batch.settled_surplus_usd = total_surplus_usd;
        batch.settled_fees_usd = total_fees_usd;
        batch.settled_intents = matched_intents;

        state.total_batches_settled = state.total_batches_settled + 1;
        state.total_surplus_delivered_usd = state.total_surplus_delivered_usd + total_surplus_usd;

        solver_registry::record_settlement_success(solver_addr, total_surplus_usd);

        events::emit_batch_settled(
            batch_id,
            solver_addr,
            matched_intents,
            ring_count,
            amm_taps,
            total_surplus_usd,
            total_fees_usd,
            now_sec
        );
    }

    // =========================================================================
    // Views
    // =========================================================================

    #[view]
    public fun batch_summary(batch_id: u64): (u8, address, u128, u64, u128, u64) acquires ClearinghouseState {
        let state = borrow_global<ClearinghouseState>(@equinox_clear);
        assert!(table::contains(&state.batches, batch_id), ERR_BATCH_NOT_FOUND);
        let b = table::borrow(&state.batches, batch_id);
        (
            b.status,
            b.winning_solver,
            b.winning_bid_surplus_usd,
            b.bid_count,
            b.settled_surplus_usd,
            b.settled_intents
        )
    }

    #[view]
    public fun batch_deadlines(batch_id: u64): (u64, u64, u64, u64, u64) acquires ClearinghouseState {
        let state = borrow_global<ClearinghouseState>(@equinox_clear);
        assert!(table::contains(&state.batches, batch_id), ERR_BATCH_NOT_FOUND);
        let b = table::borrow(&state.batches, batch_id);
        (
            b.start_sec,
            b.commit_end_sec,
            b.reveal_end_sec,
            b.bid_end_sec,
            b.settle_deadline_sec
        )
    }

    #[view]
    public fun protocol_stats(): (u64, u64, u128) acquires ClearinghouseState {
        let state = borrow_global<ClearinghouseState>(@equinox_clear);
        (
            state.current_batch_id,
            state.total_batches_settled,
            state.total_surplus_delivered_usd
        )
    }

    public fun status_open(): u8 { STATUS_OPEN }
    public fun status_settled(): u8 { STATUS_SETTLED }
    public fun status_fallback_settled(): u8 { STATUS_FALLBACK_SETTLED }
}
