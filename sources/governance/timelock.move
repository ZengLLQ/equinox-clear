// Copyright (c) ZengLLQ
// SPDX-License-Identifier: MIT

/// # Governance Parameter Timelock Queue
///
/// Enforces a mandatory waiting period (`MIN_DELAY_SEC = 3600s`, `MAX_DELAY_SEC = 604800s`)
/// and bounded execution grace window (`GRACE_PERIOD_SEC = 86400s`) before sensitive
/// protocol parameters (surplus fee BPS, solver minimum bond, oracle deviation bands,
/// or batch phase durations) can take effect.
module equinox_clear::timelock {
    use std::signer;
    use aptos_std::table::{Self, Table};
    use equinox_clear::capabilities;
    use equinox_clear::events;

    // =========================================================================
    // Error Constants
    // =========================================================================

    /// Delay is outside [MIN_DELAY_SEC, MAX_DELAY_SEC]
    const ERR_INVALID_DELAY: u64 = 2301;
    /// Timelock action ID does not exist
    const ERR_ACTION_NOT_FOUND: u64 = 2302;
    /// Action ETA has not yet elapsed
    const ERR_ACTION_NOT_READY: u64 = 2303;
    /// Action grace period expired before execution
    const ERR_ACTION_EXPIRED: u64 = 2304;
    /// Action was already executed or cancelled
    const ERR_ACTION_ALREADY_FINALIZED: u64 = 2305;
    /// Timelock already initialized
    const ERR_ALREADY_INITIALIZED: u64 = 2306;
    /// Parameter value outside safe protocol bounds
    const ERR_PARAM_OUT_OF_BOUNDS: u64 = 2307;

    // =========================================================================
    // Constants & Action Kinds
    // =========================================================================

    const MIN_DELAY_SEC: u64 = 3_600;
    const MAX_DELAY_SEC: u64 = 604_800;
    const GRACE_PERIOD_SEC: u64 = 86_400;

    const ACTION_UPDATE_SURPLUS_FEE_BPS: u8 = 1;
    const ACTION_UPDATE_MIN_SOLVER_BOND: u8 = 2;
    const ACTION_UPDATE_ORACLE_BAND_BPS: u8 = 3;
    const ACTION_UPDATE_TREASURY_SPLITS: u8 = 4;

    const STATUS_QUEUED: u8 = 0;
    const STATUS_EXECUTED: u8 = 1;
    const STATUS_CANCELLED: u8 = 2;

    // =========================================================================
    // Types & State
    // =========================================================================

    struct QueuedAction has copy, drop, store {
        action_id: u64,
        action_kind: u8,
        target_param: u64,
        new_value: u128,
        eta_sec: u64,
        status: u8
    }

    struct TimelockState has key {
        delay_sec: u64,
        next_action_id: u64,
        actions: Table<u64, QueuedAction>,
        /// Active governed parameters mirrored for downstream modules
        surplus_fee_bps: u64,
        min_solver_bond: u128,
        oracle_max_deviation_bps: u64
    }

    // =========================================================================
    // Initialization & Governance Queueing
    // =========================================================================

    public fun initialize(
        deployer: &signer,
        delay_sec: u64,
        initial_surplus_fee_bps: u64,
        initial_min_solver_bond: u128,
        initial_oracle_band_bps: u64
    ) {
        assert!(!exists<TimelockState>(@equinox_clear), ERR_ALREADY_INITIALIZED);
        assert!(delay_sec >= MIN_DELAY_SEC && delay_sec <= MAX_DELAY_SEC, ERR_INVALID_DELAY);
        assert!(initial_surplus_fee_bps <= 2_500, ERR_PARAM_OUT_OF_BOUNDS);
        assert!(initial_oracle_band_bps <= 2_000, ERR_PARAM_OUT_OF_BOUNDS);

        move_to(deployer, TimelockState {
            delay_sec,
            next_action_id: 1,
            actions: table::new<u64, QueuedAction>(),
            surplus_fee_bps: initial_surplus_fee_bps,
            min_solver_bond: initial_min_solver_bond,
            oracle_max_deviation_bps: initial_oracle_band_bps
        });
    }

    public fun queue_action(
        caller: &signer,
        action_kind: u8,
        target_param: u64,
        new_value: u128,
        now_sec: u64
    ): u64 acquires TimelockState {
        capabilities::assert_governance_or_admin(signer::address_of(caller));
        validate_action_bounds(action_kind, new_value);

        let state = borrow_global_mut<TimelockState>(@equinox_clear);
        let action_id = state.next_action_id;
        state.next_action_id = action_id + 1;
        let eta_sec = now_sec + state.delay_sec;

        table::add(&mut state.actions, action_id, QueuedAction {
            action_id,
            action_kind,
            target_param,
            new_value,
            eta_sec,
            status: STATUS_QUEUED
        });

        events::emit_timelock_queued(action_id, action_kind, target_param, new_value, eta_sec);
        action_id
    }

    public fun execute_action(caller: &signer, action_id: u64, now_sec: u64) acquires TimelockState {
        let caller_addr = signer::address_of(caller);
        capabilities::assert_governance_or_admin(caller_addr);

        let state = borrow_global_mut<TimelockState>(@equinox_clear);
        assert!(table::contains(&state.actions, action_id), ERR_ACTION_NOT_FOUND);

        let action = table::borrow_mut(&mut state.actions, action_id);
        assert!(action.status == STATUS_QUEUED, ERR_ACTION_ALREADY_FINALIZED);
        assert!(now_sec >= action.eta_sec, ERR_ACTION_NOT_READY);
        assert!(now_sec <= action.eta_sec + GRACE_PERIOD_SEC, ERR_ACTION_EXPIRED);

        action.status = STATUS_EXECUTED;
        let kind = action.action_kind;
        let val = action.new_value;

        if (kind == ACTION_UPDATE_SURPLUS_FEE_BPS) {
            state.surplus_fee_bps = (val as u64);
        } else if (kind == ACTION_UPDATE_MIN_SOLVER_BOND) {
            state.min_solver_bond = val;
        } else if (kind == ACTION_UPDATE_ORACLE_BAND_BPS) {
            state.oracle_max_deviation_bps = (val as u64);
        };

        events::emit_timelock_executed(action_id, caller_addr, now_sec);
    }

    public fun cancel_action(caller: &signer, action_id: u64) acquires TimelockState {
        capabilities::assert_guardian_or_admin(signer::address_of(caller));
        let state = borrow_global_mut<TimelockState>(@equinox_clear);
        assert!(table::contains(&state.actions, action_id), ERR_ACTION_NOT_FOUND);
        let action = table::borrow_mut(&mut state.actions, action_id);
        assert!(action.status == STATUS_QUEUED, ERR_ACTION_ALREADY_FINALIZED);
        action.status = STATUS_CANCELLED;
    }

    public fun update_delay(caller: &signer, new_delay_sec: u64) acquires TimelockState {
        capabilities::assert_admin(signer::address_of(caller));
        assert!(new_delay_sec >= MIN_DELAY_SEC && new_delay_sec <= MAX_DELAY_SEC, ERR_INVALID_DELAY);
        borrow_global_mut<TimelockState>(@equinox_clear).delay_sec = new_delay_sec;
    }

    // =========================================================================
    // Views & Parameter Readers
    // =========================================================================

    #[view]
    public fun surplus_fee_bps(): u64 acquires TimelockState {
        borrow_global<TimelockState>(@equinox_clear).surplus_fee_bps
    }

    #[view]
    public fun min_solver_bond(): u128 acquires TimelockState {
        borrow_global<TimelockState>(@equinox_clear).min_solver_bond
    }

    #[view]
    public fun oracle_max_deviation_bps(): u64 acquires TimelockState {
        borrow_global<TimelockState>(@equinox_clear).oracle_max_deviation_bps
    }

    #[view]
    public fun action_status(action_id: u64): (u8, u64, u128) acquires TimelockState {
        let state = borrow_global<TimelockState>(@equinox_clear);
        assert!(table::contains(&state.actions, action_id), ERR_ACTION_NOT_FOUND);
        let a = table::borrow(&state.actions, action_id);
        (a.status, a.eta_sec, a.new_value)
    }

    public fun action_kind_surplus_fee(): u8 { ACTION_UPDATE_SURPLUS_FEE_BPS }
    public fun action_kind_min_bond(): u8 { ACTION_UPDATE_MIN_SOLVER_BOND }
    public fun action_kind_oracle_band(): u8 { ACTION_UPDATE_ORACLE_BAND_BPS }
    public fun status_queued(): u8 { STATUS_QUEUED }
    public fun status_executed(): u8 { STATUS_EXECUTED }
    public fun status_cancelled(): u8 { STATUS_CANCELLED }

    fun validate_action_bounds(kind: u8, val: u128) {
        if (kind == ACTION_UPDATE_SURPLUS_FEE_BPS) {
            assert!(val <= 2_500, ERR_PARAM_OUT_OF_BOUNDS);
        } else if (kind == ACTION_UPDATE_MIN_SOLVER_BOND) {
            assert!(val > 0, ERR_PARAM_OUT_OF_BOUNDS);
        } else if (kind == ACTION_UPDATE_ORACLE_BAND_BPS) {
            assert!(val > 0 && val <= 2_000, ERR_PARAM_OUT_OF_BOUNDS);
        } else {
            assert!(kind == ACTION_UPDATE_TREASURY_SPLITS, ERR_PARAM_OUT_OF_BOUNDS);
        };
    }
}
