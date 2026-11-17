// Copyright (c) ZengLLQ
// SPDX-License-Identifier: MIT

/// # Emergency Circuit Breaker & Sliding-Window Volume Rate Limiter
///
/// Protects protocol solvency during anomalous market conditions via:
/// 1. Global emergency pause (blocks new settlements and range pool swaps while
///    always permitting user intent cancellations & escrow withdrawals).
/// 2. Per-pair freeze switches (`pair_id`).
/// 3. Sliding-window batch notional volume caps that automatically trip the
///    breaker if cumulative settled USD volume exceeds `window_volume_cap_usd`
///    within `window_duration_sec`.
module equinox_clear::circuit_breaker {
    use std::signer;
    use aptos_std::table::{Self, Table};
    use equinox_clear::capabilities;
    use equinox_clear::events;

    // =========================================================================
    // Error Constants
    // =========================================================================

    /// Protocol is globally paused for settlement/swaps
    const ERR_PROTOCOL_PAUSED: u64 = 2101;
    /// Specific asset pair is frozen by circuit breaker
    const ERR_PAIR_PAUSED: u64 = 2102;
    /// Batch notional volume exceeded sliding-window rate limit
    const ERR_VOLUME_LIMIT_EXCEEDED: u64 = 2103;
    /// Circuit breaker already initialized
    const ERR_ALREADY_INITIALIZED: u64 = 2104;
    /// Invalid volume cap or window duration configuration
    const ERR_INVALID_CONFIG: u64 = 2105;

    // Reason codes for emitted events
    const REASON_MANUAL_GUARDIAN_TRIP: u64 = 1;
    const REASON_VOLUME_SPIKE: u64 = 2;
    const REASON_ORACLE_DEVIATION: u64 = 3;

    // =========================================================================
    // State Resource
    // =========================================================================

    struct BreakerState has key {
        global_paused: bool,
        pair_paused: Table<u64, bool>,
        window_duration_sec: u64,
        window_start_sec: u64,
        window_volume_usd: u128,
        window_volume_cap_usd: u128,
        trip_count: u64
    }

    // =========================================================================
    // Initialization & Configuration
    // =========================================================================

    public fun initialize(
        deployer: &signer,
        window_duration_sec: u64,
        window_volume_cap_usd: u128,
        now_sec: u64
    ) {
        assert!(!exists<BreakerState>(@equinox_clear), ERR_ALREADY_INITIALIZED);
        assert!(window_duration_sec > 0 && window_volume_cap_usd > 0, ERR_INVALID_CONFIG);

        move_to(deployer, BreakerState {
            global_paused: false,
            pair_paused: table::new<u64, bool>(),
            window_duration_sec,
            window_start_sec: now_sec,
            window_volume_usd: 0,
            window_volume_cap_usd,
            trip_count: 0
        });
    }

    /// Guardian or Admin can trigger an immediate global pause.
    public fun trip_global_pause(caller: &signer, now_sec: u64) acquires BreakerState {
        let caller_addr = signer::address_of(caller);
        capabilities::assert_guardian_or_admin(caller_addr);
        let state = borrow_global_mut<BreakerState>(@equinox_clear);
        state.global_paused = true;
        state.trip_count = state.trip_count + 1;
        events::emit_circuit_breaker_tripped(0, REASON_MANUAL_GUARDIAN_TRIP, caller_addr, now_sec);
    }

    /// Only Admin may lift a global pause after incident investigation.
    public fun lift_global_pause(caller: &signer) acquires BreakerState {
        capabilities::assert_admin(signer::address_of(caller));
        let state = borrow_global_mut<BreakerState>(@equinox_clear);
        state.global_paused = false;
    }

    /// Guardian or Admin can freeze a specific market pair.
    public fun set_pair_pause(
        caller: &signer,
        pair_id: u64,
        paused: bool,
        now_sec: u64
    ) acquires BreakerState {
        let caller_addr = signer::address_of(caller);
        if (paused) {
            capabilities::assert_guardian_or_admin(caller_addr);
        } else {
            capabilities::assert_admin(caller_addr);
        };
        let state = borrow_global_mut<BreakerState>(@equinox_clear);
        if (table::contains(&state.pair_paused, pair_id)) {
            let r = table::borrow_mut(&mut state.pair_paused, pair_id);
            *r = paused;
        } else {
            table::add(&mut state.pair_paused, pair_id, paused);
        };
        if (paused) {
            state.trip_count = state.trip_count + 1;
            events::emit_circuit_breaker_tripped(pair_id, REASON_MANUAL_GUARDIAN_TRIP, caller_addr, now_sec);
        };
    }

    public fun update_volume_limit(
        caller: &signer,
        window_duration_sec: u64,
        window_volume_cap_usd: u128
    ) acquires BreakerState {
        capabilities::assert_governance_or_admin(signer::address_of(caller));
        assert!(window_duration_sec > 0 && window_volume_cap_usd > 0, ERR_INVALID_CONFIG);
        let state = borrow_global_mut<BreakerState>(@equinox_clear);
        state.window_duration_sec = window_duration_sec;
        state.window_volume_cap_usd = window_volume_cap_usd;
    }

    // =========================================================================
    // Runtime Guards & Volume Accounting
    // =========================================================================

    public fun assert_not_globally_paused() acquires BreakerState {
        let state = borrow_global<BreakerState>(@equinox_clear);
        assert!(!state.global_paused, ERR_PROTOCOL_PAUSED);
    }

    public fun assert_pair_active(pair_id: u64) acquires BreakerState {
        let state = borrow_global<BreakerState>(@equinox_clear);
        assert!(!state.global_paused, ERR_PROTOCOL_PAUSED);
        if (table::contains(&state.pair_paused, pair_id)) {
            assert!(!*table::borrow(&state.pair_paused, pair_id), ERR_PAIR_PAUSED);
        };
    }

    /// Records settled notional USD volume in the current sliding window.
    /// Aborts if the volume cap would be exceeded.
    public fun record_and_check_volume(notional_usd: u128, now_sec: u64) acquires BreakerState {
        let state = borrow_global_mut<BreakerState>(@equinox_clear);
        assert!(!state.global_paused, ERR_PROTOCOL_PAUSED);

        if (now_sec >= state.window_start_sec + state.window_duration_sec) {
            state.window_start_sec = now_sec;
            state.window_volume_usd = 0;
        };

        let next_vol = state.window_volume_usd + notional_usd;
        assert!(next_vol <= state.window_volume_cap_usd, ERR_VOLUME_LIMIT_EXCEEDED);
        state.window_volume_usd = next_vol;
    }

    /// Records an oracle deviation breach notice (called by clearinghouse or guardian).
    public fun trip_on_oracle_deviation(pair_id: u64, reporter: address, now_sec: u64) acquires BreakerState {
        let state = borrow_global_mut<BreakerState>(@equinox_clear);
        if (table::contains(&state.pair_paused, pair_id)) {
            let r = table::borrow_mut(&mut state.pair_paused, pair_id);
            *r = true;
        } else {
            table::add(&mut state.pair_paused, pair_id, true);
        };
        state.trip_count = state.trip_count + 1;
        events::emit_circuit_breaker_tripped(pair_id, REASON_ORACLE_DEVIATION, reporter, now_sec);
    }

    // =========================================================================
    // Views
    // =========================================================================

    #[view]
    public fun is_globally_paused(): bool acquires BreakerState {
        borrow_global<BreakerState>(@equinox_clear).global_paused
    }

    #[view]
    public fun is_pair_paused(pair_id: u64): bool acquires BreakerState {
        let state = borrow_global<BreakerState>(@equinox_clear);
        if (state.global_paused) {
            return true
        };
        if (table::contains(&state.pair_paused, pair_id)) {
            *table::borrow(&state.pair_paused, pair_id)
        } else {
            false
        }
    }

    #[view]
    public fun window_volume_usd(): u128 acquires BreakerState {
        borrow_global<BreakerState>(@equinox_clear).window_volume_usd
    }

    #[view]
    public fun trip_count(): u64 acquires BreakerState {
        borrow_global<BreakerState>(@equinox_clear).trip_count
    }
}
