// Copyright (c) ZengLLQ
// SPDX-License-Identifier: MIT

/// # Commit-Reveal Intent Book & Limit-Price Order Ledger
///
/// Manages MEV-shielded trading intents through a two-phase Commit-Reveal flow:
/// 1. **Commit**: Traders submit a 32-byte SHA3-256 hash (`commitment_hash`) hiding
///    pair, size, limit price, and fee tolerance during the batch commit phase.
/// 2. **Reveal**: During the reveal phase, traders reveal intent parameters + salt;
///    the module verifies hash equality, locks `sell_amount` in `escrow_ledger`,
///    and indexes the implied limit tick in the pair's `TickBitmap`.
/// 3. **Fill / Cancel**: Solvers fill active intents respecting exact cross-multiplied
///    limit ratios:
///    $$\text{fill\_buy} \cdot \text{sell\_amount} \ge \text{min\_buy\_amount} \cdot \text{fill\_sell}$$
///    Unfilled or expired orders can always be cancelled by the owner even if the
///    protocol is paused.
module equinox_clear::intent_book {
    use std::signer;
    use std::vector;
    use aptos_std::table::{Self, Table};
    use equinox_clear::escrow_ledger;
    use equinox_clear::events;
    use equinox_clear::fixed_point;
    use equinox_clear::merkle_verifier;
    use equinox_clear::tick_bitmap::{Self, TickBitmap};

    // =========================================================================
    // Error Constants
    // =========================================================================

    /// Commitment hash length must be 32 bytes
    const ERR_INVALID_COMMITMENT_HASH: u64 = 4101;
    /// Commitment ID not found
    const ERR_COMMITMENT_NOT_FOUND: u64 = 4102;
    /// Commitment already revealed or expired
    const ERR_COMMITMENT_UNAVAILABLE: u64 = 4103;
    /// Caller is not the owner of this commitment or intent
    const ERR_NOT_INTENT_OWNER: u64 = 4104;
    /// Revealed preimage does not match stored SHA3-256 commitment
    const ERR_COMMITMENT_MISMATCH: u64 = 4105;
    /// Intent parameters invalid (zero amounts, same asset, or expired)
    const ERR_INVALID_INTENT_PARAMS: u64 = 4106;
    /// Intent ID not found
    const ERR_INTENT_NOT_FOUND: u64 = 4107;
    /// Intent is not active (already filled or cancelled)
    const ERR_INTENT_NOT_ACTIVE: u64 = 4108;
    /// Intent expired before fill attempt
    const ERR_INTENT_EXPIRED: u64 = 4109;
    /// Partial fill attempted on an all-or-nothing (fill-or-kill) intent
    const ERR_PARTIAL_FILL_FORBIDDEN: u64 = 4110;
    /// Fill amount exceeds remaining sell balance
    const ERR_FILL_EXCEEDS_REMAINING: u64 = 4111;
    /// Fill exchange rate violates trader's minimum limit price
    const ERR_LIMIT_PRICE_VIOLATED: u64 = 4112;
    /// Protocol fee exceeds trader's max_fee_bps cap
    const ERR_MAX_FEE_EXCEEDED: u64 = 4113;
    /// Intent book already initialized
    const ERR_ALREADY_INITIALIZED: u64 = 4114;

    const STATUS_COMMITTED: u8 = 0;
    const STATUS_REVEALED: u8 = 1;
    const STATUS_ACTIVE: u8 = 1;
    const STATUS_PARTIAL: u8 = 2;
    const STATUS_FILLED: u8 = 3;
    const STATUS_CANCELLED: u8 = 4;

    // =========================================================================
    // Types & Storage
    // =========================================================================

    struct CommitmentRecord has copy, drop, store {
        commitment_id: u64,
        trader: address,
        commitment_hash: vector<u8>,
        expiry_sec: u64,
        committed_at: u64,
        revealed: bool
    }

    struct IntentOrder has copy, drop, store {
        intent_id: u64,
        commitment_id: u64,
        trader: address,
        sell_asset: u64,
        buy_asset: u64,
        sell_amount: u128,
        min_buy_amount: u128,
        filled_sell: u128,
        filled_buy: u128,
        limit_price_wad: u128,
        limit_tick: u64,
        partial_fill_allowed: bool,
        max_fee_bps: u64,
        expiry_sec: u64,
        status: u8
    }

    struct PairKey has copy, drop, store {
        sell_asset: u64,
        buy_asset: u64
    }

    struct IntentBookState has key {
        next_commitment_id: u64,
        next_intent_id: u64,
        commitments: Table<u64, CommitmentRecord>,
        intents: Table<u64, IntentOrder>,
        pair_bitmaps: Table<PairKey, TickBitmap>,
        active_intent_count: u64
    }

    // =========================================================================
    // Initialization
    // =========================================================================

    public fun initialize(deployer: &signer) {
        assert!(!exists<IntentBookState>(@equinox_clear), ERR_ALREADY_INITIALIZED);
        move_to(deployer, IntentBookState {
            next_commitment_id: 1,
            next_intent_id: 1,
            commitments: table::new<u64, CommitmentRecord>(),
            intents: table::new<u64, IntentOrder>(),
            pair_bitmaps: table::new<PairKey, TickBitmap>(),
            active_intent_count: 0
        });
    }

    // =========================================================================
    // Phase 1 & 2: Commit -> Reveal
    // =========================================================================

    public fun commit_intent(
        trader: &signer,
        commitment_hash: vector<u8>,
        expiry_sec: u64,
        now_sec: u64
    ): u64 acquires IntentBookState {
        assert!(vector::length(&commitment_hash) == 32, ERR_INVALID_COMMITMENT_HASH);
        assert!(expiry_sec > now_sec, ERR_INVALID_INTENT_PARAMS);

        let trader_addr = signer::address_of(trader);
        let state = borrow_global_mut<IntentBookState>(@equinox_clear);
        let commitment_id = state.next_commitment_id;
        state.next_commitment_id = commitment_id + 1;

        table::add(&mut state.commitments, commitment_id, CommitmentRecord {
            commitment_id,
            trader: trader_addr,
            commitment_hash,
            expiry_sec,
            committed_at: now_sec,
            revealed: false
        });

        events::emit_intent_committed(
            commitment_id,
            trader_addr,
            commitment_hash,
            expiry_sec,
            now_sec
        );
        commitment_id
    }

    public fun reveal_intent(
        trader: &signer,
        commitment_id: u64,
        sell_asset: u64,
        buy_asset: u64,
        sell_amount: u128,
        min_buy_amount: u128,
        partial_fill_allowed: bool,
        max_fee_bps: u64,
        salt: vector<u8>,
        now_sec: u64
    ): u64 acquires IntentBookState {
        let trader_addr = signer::address_of(trader);
        assert!(sell_asset != buy_asset, ERR_INVALID_INTENT_PARAMS);
        assert!(sell_amount > 0 && min_buy_amount > 0, ERR_INVALID_INTENT_PARAMS);
        assert!(max_fee_bps <= 2_500, ERR_INVALID_INTENT_PARAMS);

        let state = borrow_global_mut<IntentBookState>(@equinox_clear);
        assert!(table::contains(&state.commitments, commitment_id), ERR_COMMITMENT_NOT_FOUND);
        let comm = table::borrow_mut(&mut state.commitments, commitment_id);
        assert!(comm.trader == trader_addr, ERR_NOT_INTENT_OWNER);
        assert!(!comm.revealed, ERR_COMMITMENT_UNAVAILABLE);
        assert!(now_sec <= comm.expiry_sec, ERR_INTENT_EXPIRED);

        let expected_hash = merkle_verifier::compute_intent_commitment(
            trader_addr,
            sell_asset,
            buy_asset,
            sell_amount,
            min_buy_amount,
            partial_fill_allowed,
            max_fee_bps,
            comm.expiry_sec,
            salt
        );
        assert!(expected_hash == comm.commitment_hash, ERR_COMMITMENT_MISMATCH);
        comm.revealed = true;

        // Lock sell_amount in escrow ledger
        escrow_ledger::lock_for_intent(trader_addr, sell_asset, sell_amount);

        // Compute limit price in WAD and clamp to bitmap tick domain
        let limit_price_wad = fixed_point::div_wad_up(min_buy_amount, sell_amount);
        let clamped_price = fixed_point::clamp_u128(
            limit_price_wad,
            tick_bitmap::tick_to_price_wad(0),
            tick_bitmap::tick_to_price_wad(8192)
        );
        let limit_tick = tick_bitmap::price_wad_to_tick(clamped_price);

        let pkey = PairKey { sell_asset, buy_asset };
        if (!table::contains(&state.pair_bitmaps, pkey)) {
            table::add(&mut state.pair_bitmaps, pkey, tick_bitmap::new());
        };
        let bm = table::borrow_mut(&mut state.pair_bitmaps, pkey);
        tick_bitmap::set_tick(bm, limit_tick);

        let intent_id = state.next_intent_id;
        state.next_intent_id = intent_id + 1;
        let expiry_sec = comm.expiry_sec;

        table::add(&mut state.intents, intent_id, IntentOrder {
            intent_id,
            commitment_id,
            trader: trader_addr,
            sell_asset,
            buy_asset,
            sell_amount,
            min_buy_amount,
            filled_sell: 0,
            filled_buy: 0,
            limit_price_wad,
            limit_tick,
            partial_fill_allowed,
            max_fee_bps,
            expiry_sec,
            status: STATUS_ACTIVE
        });
        state.active_intent_count = state.active_intent_count + 1;

        events::emit_intent_revealed(
            intent_id,
            commitment_id,
            trader_addr,
            sell_asset,
            buy_asset,
            sell_amount,
            min_buy_amount,
            partial_fill_allowed,
            max_fee_bps
        );
        intent_id
    }

    // =========================================================================
    // Cancellation & Fill Execution
    // =========================================================================

    /// Cancels an active or partially-filled intent and returns remaining locked
    /// collateral to the trader's available balance. Always permitted even under pause.
    public fun cancel_intent(trader: &signer, intent_id: u64, now_sec: u64): u128 acquires IntentBookState {
        let trader_addr = signer::address_of(trader);
        let state = borrow_global_mut<IntentBookState>(@equinox_clear);
        assert!(table::contains(&state.intents, intent_id), ERR_INTENT_NOT_FOUND);
        let order = table::borrow_mut(&mut state.intents, intent_id);
        assert!(order.trader == trader_addr, ERR_NOT_INTENT_OWNER);
        assert!(order.status == STATUS_ACTIVE || order.status == STATUS_PARTIAL, ERR_INTENT_NOT_ACTIVE);

        let remaining = order.sell_amount - order.filled_sell;
        order.status = STATUS_CANCELLED;
        state.active_intent_count = state.active_intent_count - 1;

        if (remaining > 0) {
            escrow_ledger::unlock_from_intent(trader_addr, order.sell_asset, remaining);
        };

        events::emit_intent_cancelled(intent_id, trader_addr, remaining, now_sec);
        remaining
    }

    /// Executes a fill against `intent_id`, validating expiry, partial-fill rule,
    /// cross-multiplied limit price, and fee cap. Debits `fill_sell` from trader
    /// escrow into the batch and credits `net_buy = fill_buy - fee` to trader.
    ///
    /// Returns `(sell_asset, buy_asset, trader, surplus_buy_units, fee_paid)`.
    public fun apply_fill(
        intent_id: u64,
        batch_id: u64,
        fill_sell: u128,
        gross_buy: u128,
        protocol_fee_bps: u64,
        now_sec: u64
    ): (u64, u64, address, u128, u128) acquires IntentBookState {
        assert!(fill_sell > 0 && gross_buy > 0, ERR_INVALID_INTENT_PARAMS);

        let state = borrow_global_mut<IntentBookState>(@equinox_clear);
        assert!(table::contains(&state.intents, intent_id), ERR_INTENT_NOT_FOUND);
        let order = table::borrow_mut(&mut state.intents, intent_id);

        assert!(order.status == STATUS_ACTIVE || order.status == STATUS_PARTIAL, ERR_INTENT_NOT_ACTIVE);
        assert!(now_sec <= order.expiry_sec, ERR_INTENT_EXPIRED);
        assert!(protocol_fee_bps <= order.max_fee_bps, ERR_MAX_FEE_EXCEEDED);

        let remaining = order.sell_amount - order.filled_sell;
        assert!(fill_sell <= remaining, ERR_FILL_EXCEEDS_REMAINING);
        if (!order.partial_fill_allowed) {
            assert!(fill_sell == order.sell_amount, ERR_PARTIAL_FILL_FORBIDDEN);
        };

        // Pro-rata minimum buy required: ceil(min_buy_amount * fill_sell / sell_amount)
        let pro_rata_min_buy = fixed_point::mul_div_up(
            order.min_buy_amount,
            fill_sell,
            order.sell_amount
        );
        assert!(gross_buy >= pro_rata_min_buy, ERR_LIMIT_PRICE_VIOLATED);

        let surplus_buy = gross_buy - pro_rata_min_buy;
        // Protocol fee charged strictly on positive trader surplus (never eats into limit price!)
        let fee_paid = fixed_point::bps_mul_down(surplus_buy, protocol_fee_bps);
        let net_buy = gross_buy - fee_paid;

        // Re-verify net_buy satisfies cross-multiplied limit price invariant
        let lhs = (net_buy as u256) * (order.sell_amount as u256);
        let rhs = (order.min_buy_amount as u256) * (fill_sell as u256);
        assert!(lhs >= rhs, ERR_LIMIT_PRICE_VIOLATED);

        order.filled_sell = order.filled_sell + fill_sell;
        order.filled_buy = order.filled_buy + net_buy;
        if (order.filled_sell == order.sell_amount) {
            order.status = STATUS_FILLED;
            state.active_intent_count = state.active_intent_count - 1;
        } else {
            order.status = STATUS_PARTIAL;
        };

        escrow_ledger::debit_locked_to_batch(order.trader, order.sell_asset, fill_sell);
        escrow_ledger::credit_available_from_batch(order.trader, order.buy_asset, net_buy);
        if (fee_paid > 0) {
            escrow_ledger::credit_protocol_fee_from_batch(order.buy_asset, fee_paid);
        };

        events::emit_intent_filled(
            batch_id,
            intent_id,
            order.trader,
            order.sell_asset,
            order.buy_asset,
            fill_sell,
            net_buy,
            fee_paid
        );

        (order.sell_asset, order.buy_asset, order.trader, surplus_buy, fee_paid)
    }

    // =========================================================================
    // Views
    // =========================================================================

    #[view]
    public fun get_intent(intent_id: u64): (address, u64, u64, u128, u128, u128, u128, u8) acquires IntentBookState {
        let state = borrow_global<IntentBookState>(@equinox_clear);
        assert!(table::contains(&state.intents, intent_id), ERR_INTENT_NOT_FOUND);
        let o = table::borrow(&state.intents, intent_id);
        (
            o.trader,
            o.sell_asset,
            o.buy_asset,
            o.sell_amount,
            o.min_buy_amount,
            o.filled_sell,
            o.filled_buy,
            o.status
        )
    }

    #[view]
    public fun is_tick_active_for_pair(sell_asset: u64, buy_asset: u64, tick: u64): bool acquires IntentBookState {
        let state = borrow_global<IntentBookState>(@equinox_clear);
        let key = PairKey { sell_asset, buy_asset };
        if (!table::contains(&state.pair_bitmaps, key)) {
            return false
        };
        tick_bitmap::is_initialized(table::borrow(&state.pair_bitmaps, key), tick)
    }

    #[view]
    public fun active_intent_count(): u64 acquires IntentBookState {
        borrow_global<IntentBookState>(@equinox_clear).active_intent_count
    }

    public fun status_active(): u8 { STATUS_ACTIVE }
    public fun status_partial(): u8 { STATUS_PARTIAL }
    public fun status_filled(): u8 { STATUS_FILLED }
    public fun status_cancelled(): u8 { STATUS_CANCELLED }
}
