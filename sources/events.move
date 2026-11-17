// Copyright (c) ZengLLQ
// SPDX-License-Identifier: MIT

/// # Protocol Event Registry
///
/// Emits structured Move 2 module events across every lifecycle transition:
/// - Commit-reveal intent lifecycle (`commit`, `reveal`, `cancel`, `fill`)
/// - Solver onboarding, bidding, slashing, and reputation updates
/// - CoW ring clearing, uniform clearing price discovery, and range pool swaps
/// - Oracle updates, circuit breaker trips, governance timelocks, and treasury flows
module equinox_clear::events {
    use aptos_framework::event;

    // =========================================================================
    // Intent & Escrow Events
    // =========================================================================

    #[event]
    struct IntentCommittedEvent has drop, store {
        commitment_id: u64,
        trader: address,
        commitment_hash: vector<u8>,
        expiry_sec: u64,
        committed_at: u64
    }

    #[event]
    struct IntentRevealedEvent has drop, store {
        intent_id: u64,
        commitment_id: u64,
        trader: address,
        sell_asset: u64,
        buy_asset: u64,
        sell_amount: u128,
        min_buy_amount: u128,
        partial_fill_allowed: bool,
        max_fee_bps: u64
    }

    #[event]
    struct IntentCancelledEvent has drop, store {
        intent_id: u64,
        trader: address,
        refunded_sell_amount: u128,
        cancelled_at: u64
    }

    #[event]
    struct IntentFilledEvent has drop, store {
        batch_id: u64,
        intent_id: u64,
        trader: address,
        sell_asset: u64,
        buy_asset: u64,
        filled_sell: u128,
        filled_buy: u128,
        fee_paid: u128
    }

    // =========================================================================
    // Batch Auction & CoW Ring Clearing Events
    // =========================================================================

    #[event]
    struct BatchEpochStartedEvent has drop, store {
        batch_id: u64,
        commit_end_sec: u64,
        reveal_end_sec: u64,
        bid_end_sec: u64,
        settle_deadline_sec: u64
    }

    #[event]
    struct SolverBidSubmittedEvent has drop, store {
        batch_id: u64,
        solver: address,
        proposed_surplus_usd: u128,
        expected_fill_count: u64
    }

    #[event]
    struct CowRingClearedEvent has drop, store {
        batch_id: u64,
        hop_count: u64,
        total_surplus_usd: u128,
        solver: address
    }

    #[event]
    struct BatchSettledEvent has drop, store {
        batch_id: u64,
        solver: address,
        matched_intents: u64,
        ring_count: u64,
        amm_taps: u64,
        total_surplus_usd: u128,
        protocol_fees_usd: u128,
        settled_at: u64
    }

    // =========================================================================
    // Concentrated Range Pool Events
    // =========================================================================

    #[event]
    struct RangePoolCreatedEvent has drop, store {
        pool_id: u64,
        asset_a: u64,
        asset_b: u64,
        base_fee_bps: u64,
        initial_price_wad: u128
    }

    #[event]
    struct RangePositionMintedEvent has drop, store {
        pool_id: u64,
        position_id: u64,
        owner: address,
        lower_tick: u64,
        upper_tick: u64,
        liquidity: u128
    }

    #[event]
    struct RangePoolSwapEvent has drop, store {
        pool_id: u64,
        zero_for_one: bool,
        amount_in: u128,
        amount_out: u128,
        dynamic_fee_bps: u64,
        new_price_wad: u128
    }

    // =========================================================================
    // Solver, Oracle, Security & Governance Events
    // =========================================================================

    #[event]
    struct SolverRegisteredEvent has drop, store {
        solver: address,
        bond_amount: u128,
        registered_at: u64
    }

    #[event]
    struct SolverSlashedEvent has drop, store {
        solver: address,
        slash_amount: u128,
        reason_code: u64,
        jailed_until_sec: u64
    }

    #[event]
    struct OraclePriceUpdatedEvent has drop, store {
        pair_id: u64,
        median_price_wad: u128,
        twap_price_wad: u128,
        confidence_bps: u64,
        updated_at: u64
    }

    #[event]
    struct CircuitBreakerTrippedEvent has drop, store {
        scope_id: u64,
        reason_code: u64,
        tripped_by: address,
        tripped_at: u64
    }

    #[event]
    struct TimelockActionQueuedEvent has drop, store {
        action_id: u64,
        action_kind: u8,
        target_param: u64,
        new_value: u128,
        eta_sec: u64
    }

    #[event]
    struct TimelockActionExecutedEvent has drop, store {
        action_id: u64,
        executed_by: address,
        executed_at: u64
    }

    #[event]
    struct TreasuryCollectedEvent has drop, store {
        asset_id: u64,
        total_amount: u128,
        reserve_share: u128,
        solver_rebate_share: u128,
        lp_incentive_share: u128
    }

    // =========================================================================
    // Event Emitters
    // =========================================================================

    public fun emit_intent_committed(
        commitment_id: u64,
        trader: address,
        commitment_hash: vector<u8>,
        expiry_sec: u64,
        committed_at: u64
    ) {
        event::emit(IntentCommittedEvent {
            commitment_id,
            trader,
            commitment_hash,
            expiry_sec,
            committed_at
        });
    }

    public fun emit_intent_revealed(
        intent_id: u64,
        commitment_id: u64,
        trader: address,
        sell_asset: u64,
        buy_asset: u64,
        sell_amount: u128,
        min_buy_amount: u128,
        partial_fill_allowed: bool,
        max_fee_bps: u64
    ) {
        event::emit(IntentRevealedEvent {
            intent_id,
            commitment_id,
            trader,
            sell_asset,
            buy_asset,
            sell_amount,
            min_buy_amount,
            partial_fill_allowed,
            max_fee_bps
        });
    }

    public fun emit_intent_cancelled(
        intent_id: u64,
        trader: address,
        refunded_sell_amount: u128,
        cancelled_at: u64
    ) {
        event::emit(IntentCancelledEvent {
            intent_id,
            trader,
            refunded_sell_amount,
            cancelled_at
        });
    }

    public fun emit_intent_filled(
        batch_id: u64,
        intent_id: u64,
        trader: address,
        sell_asset: u64,
        buy_asset: u64,
        filled_sell: u128,
        filled_buy: u128,
        fee_paid: u128
    ) {
        event::emit(IntentFilledEvent {
            batch_id,
            intent_id,
            trader,
            sell_asset,
            buy_asset,
            filled_sell,
            filled_buy,
            fee_paid
        });
    }

    public fun emit_batch_epoch_started(
        batch_id: u64,
        commit_end_sec: u64,
        reveal_end_sec: u64,
        bid_end_sec: u64,
        settle_deadline_sec: u64
    ) {
        event::emit(BatchEpochStartedEvent {
            batch_id,
            commit_end_sec,
            reveal_end_sec,
            bid_end_sec,
            settle_deadline_sec
        });
    }

    public fun emit_solver_bid_submitted(
        batch_id: u64,
        solver: address,
        proposed_surplus_usd: u128,
        expected_fill_count: u64
    ) {
        event::emit(SolverBidSubmittedEvent {
            batch_id,
            solver,
            proposed_surplus_usd,
            expected_fill_count
        });
    }

    public fun emit_cow_ring_cleared(
        batch_id: u64,
        hop_count: u64,
        total_surplus_usd: u128,
        solver: address
    ) {
        event::emit(CowRingClearedEvent {
            batch_id,
            hop_count,
            total_surplus_usd,
            solver
        });
    }

    public fun emit_batch_settled(
        batch_id: u64,
        solver: address,
        matched_intents: u64,
        ring_count: u64,
        amm_taps: u64,
        total_surplus_usd: u128,
        protocol_fees_usd: u128,
        settled_at: u64
    ) {
        event::emit(BatchSettledEvent {
            batch_id,
            solver,
            matched_intents,
            ring_count,
            amm_taps,
            total_surplus_usd,
            protocol_fees_usd,
            settled_at
        });
    }

    public fun emit_range_pool_created(
        pool_id: u64,
        asset_a: u64,
        asset_b: u64,
        base_fee_bps: u64,
        initial_price_wad: u128
    ) {
        event::emit(RangePoolCreatedEvent {
            pool_id,
            asset_a,
            asset_b,
            base_fee_bps,
            initial_price_wad
        });
    }

    public fun emit_range_position_minted(
        pool_id: u64,
        position_id: u64,
        owner: address,
        lower_tick: u64,
        upper_tick: u64,
        liquidity: u128
    ) {
        event::emit(RangePositionMintedEvent {
            pool_id,
            position_id,
            owner,
            lower_tick,
            upper_tick,
            liquidity
        });
    }

    public fun emit_range_pool_swap(
        pool_id: u64,
        zero_for_one: bool,
        amount_in: u128,
        amount_out: u128,
        dynamic_fee_bps: u64,
        new_price_wad: u128
    ) {
        event::emit(RangePoolSwapEvent {
            pool_id,
            zero_for_one,
            amount_in,
            amount_out,
            dynamic_fee_bps,
            new_price_wad
        });
    }

    public fun emit_solver_registered(
        solver: address,
        bond_amount: u128,
        registered_at: u64
    ) {
        event::emit(SolverRegisteredEvent {
            solver,
            bond_amount,
            registered_at
        });
    }

    public fun emit_solver_slashed(
        solver: address,
        slash_amount: u128,
        reason_code: u64,
        jailed_until_sec: u64
    ) {
        event::emit(SolverSlashedEvent {
            solver,
            slash_amount,
            reason_code,
            jailed_until_sec
        });
    }

    public fun emit_oracle_price_updated(
        pair_id: u64,
        median_price_wad: u128,
        twap_price_wad: u128,
        confidence_bps: u64,
        updated_at: u64
    ) {
        event::emit(OraclePriceUpdatedEvent {
            pair_id,
            median_price_wad,
            twap_price_wad,
            confidence_bps,
            updated_at
        });
    }

    public fun emit_circuit_breaker_tripped(
        scope_id: u64,
        reason_code: u64,
        tripped_by: address,
        tripped_at: u64
    ) {
        event::emit(CircuitBreakerTrippedEvent {
            scope_id,
            reason_code,
            tripped_by,
            tripped_at
        });
    }

    public fun emit_timelock_queued(
        action_id: u64,
        action_kind: u8,
        target_param: u64,
        new_value: u128,
        eta_sec: u64
    ) {
        event::emit(TimelockActionQueuedEvent {
            action_id,
            action_kind,
            target_param,
            new_value,
            eta_sec
        });
    }

    public fun emit_timelock_executed(
        action_id: u64,
        executed_by: address,
        executed_at: u64
    ) {
        event::emit(TimelockActionExecutedEvent {
            action_id,
            executed_by,
            executed_at
        });
    }

    public fun emit_treasury_collected(
        asset_id: u64,
        total_amount: u128,
        reserve_share: u128,
        solver_rebate_share: u128,
        lp_incentive_share: u128
    ) {
        event::emit(TreasuryCollectedEvent {
            asset_id,
            total_amount,
            reserve_share,
            solver_rebate_share,
            lp_incentive_share
        });
    }
}
