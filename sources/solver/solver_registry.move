// Copyright (c) ZengLLQ
// SPDX-License-Identifier: MIT

/// # Bonded Solver Registry, Reputation EMA & Deterministic Slashing
///
/// Manages permissionless yet collateral-backed solvers competing to clear
/// batch auctions:
/// - **Collateral Bonding**: Solvers stake a minimum bond (`min_bond_amount`)
///   held in escrow; unbonding requires passing a cooldown window.
/// - **EMA Reputation Scoring**: Tracks delivery reliability & surplus efficiency
///   using a WAD-scaled exponential moving average ($\alpha = 0.2$).
/// - **Deterministic Slashing & Jailing**: Penalizes solvers that miss settlement
///   deadlines after winning a batch or violate clearing price bands, routing
///   seized collateral to the Protocol Treasury.
module equinox_clear::solver_registry {
    use std::signer;
    use aptos_std::table::{Self, Table};
    use equinox_clear::capabilities;
    use equinox_clear::events;
    use equinox_clear::fixed_point;
    use equinox_clear::treasury;

    // =========================================================================
    // Error Constants
    // =========================================================================

    /// Solver already registered
    const ERR_SOLVER_ALREADY_REGISTERED: u64 = 3101;
    /// Solver is not registered
    const ERR_SOLVER_NOT_FOUND: u64 = 3102;
    /// Solver bond is below minimum protocol requirement
    const ERR_INSUFFICIENT_BOND: u64 = 3103;
    /// Solver is currently jailed or inactive
    const ERR_SOLVER_JAILED_OR_INACTIVE: u64 = 3104;
    /// Unbonding cooldown period has not elapsed
    const ERR_UNBOND_COOLDOWN_ACTIVE: u64 = 3105;
    /// Registry already initialized
    const ERR_ALREADY_INITIALIZED: u64 = 3106;

    // Reason codes for slashing
    const SLASH_REASON_MISSED_SETTLEMENT: u64 = 1;
    const SLASH_REASON_PRICE_BAND_BREACH: u64 = 2;
    const SLASH_REASON_INVALID_PROOF: u64 = 3;

    /// Initial reputation = 0.50 in WAD
    const INITIAL_REPUTATION_WAD: u128 = 500_000_000_000_000_000;
    /// EMA smoothing factor alpha = 0.20 in WAD
    const EMA_ALPHA_WAD: u128 = 200_000_000_000_000_000;
    /// Default jail cooldown (1 hour)
    const JAIL_DURATION_SEC: u64 = 3_600;
    /// Bond withdrawal cooldown (24 hours)
    const UNBOND_COOLDOWN_SEC: u64 = 86_400;

    // =========================================================================
    // Types
    // =========================================================================

    struct SolverProfile has copy, drop, store {
        solver: address,
        bond_amount: u128,
        reputation_wad: u128,
        batches_won: u64,
        batches_settled: u64,
        slash_count: u64,
        lifetime_surplus_usd: u128,
        jailed_until_sec: u64,
        unbond_requested_at: u64,
        active: bool
    }

    struct SolverRegistryState has key {
        bond_asset_id: u64,
        min_bond_amount: u128,
        slash_bps: u64,
        total_bonded: u128,
        active_solver_count: u64,
        solvers: Table<address, SolverProfile>
    }

    // =========================================================================
    // Initialization & Solver Onboarding
    // =========================================================================

    public fun initialize(
        deployer: &signer,
        bond_asset_id: u64,
        min_bond_amount: u128,
        slash_bps: u64
    ) {
        assert!(!exists<SolverRegistryState>(@equinox_clear), ERR_ALREADY_INITIALIZED);
        assert!(min_bond_amount > 0 && slash_bps > 0 && slash_bps <= 10_000, ERR_INSUFFICIENT_BOND);

        move_to(deployer, SolverRegistryState {
            bond_asset_id,
            min_bond_amount,
            slash_bps,
            total_bonded: 0,
            active_solver_count: 0,
            solvers: table::new<address, SolverProfile>()
        });
    }

    public fun register_solver(
        solver_signer: &signer,
        bond_amount: u128,
        now_sec: u64
    ) acquires SolverRegistryState {
        let solver_addr = signer::address_of(solver_signer);
        let state = borrow_global_mut<SolverRegistryState>(@equinox_clear);
        assert!(!table::contains(&state.solvers, solver_addr), ERR_SOLVER_ALREADY_REGISTERED);
        assert!(bond_amount >= state.min_bond_amount, ERR_INSUFFICIENT_BOND);

        table::add(&mut state.solvers, solver_addr, SolverProfile {
            solver: solver_addr,
            bond_amount,
            reputation_wad: INITIAL_REPUTATION_WAD,
            batches_won: 0,
            batches_settled: 0,
            slash_count: 0,
            lifetime_surplus_usd: 0,
            jailed_until_sec: 0,
            unbond_requested_at: 0,
            active: true
        });
        state.total_bonded = state.total_bonded + bond_amount;
        state.active_solver_count = state.active_solver_count + 1;

        events::emit_solver_registered(solver_addr, bond_amount, now_sec);
    }

    public fun top_up_bond(solver_signer: &signer, additional_bond: u128) acquires SolverRegistryState {
        let solver_addr = signer::address_of(solver_signer);
        let state = borrow_global_mut<SolverRegistryState>(@equinox_clear);
        assert!(table::contains(&state.solvers, solver_addr), ERR_SOLVER_NOT_FOUND);
        let profile = table::borrow_mut(&mut state.solvers, solver_addr);
        profile.bond_amount = profile.bond_amount + additional_bond;
        profile.unbond_requested_at = 0;
        if (!profile.active && profile.bond_amount >= state.min_bond_amount) {
            profile.active = true;
            state.active_solver_count = state.active_solver_count + 1;
        };
        state.total_bonded = state.total_bonded + additional_bond;
    }

    public fun request_unbond(solver_signer: &signer, now_sec: u64) acquires SolverRegistryState {
        let solver_addr = signer::address_of(solver_signer);
        let state = borrow_global_mut<SolverRegistryState>(@equinox_clear);
        assert!(table::contains(&state.solvers, solver_addr), ERR_SOLVER_NOT_FOUND);
        let profile = table::borrow_mut(&mut state.solvers, solver_addr);
        if (profile.active) {
            profile.active = false;
            state.active_solver_count = state.active_solver_count - 1;
        };
        profile.unbond_requested_at = now_sec;
    }

    public fun complete_unbond(solver_signer: &signer, now_sec: u64): u128 acquires SolverRegistryState {
        let solver_addr = signer::address_of(solver_signer);
        let state = borrow_global_mut<SolverRegistryState>(@equinox_clear);
        assert!(table::contains(&state.solvers, solver_addr), ERR_SOLVER_NOT_FOUND);
        let profile = table::borrow_mut(&mut state.solvers, solver_addr);
        assert!(profile.unbond_requested_at > 0, ERR_UNBOND_COOLDOWN_ACTIVE);
        assert!(now_sec >= profile.unbond_requested_at + UNBOND_COOLDOWN_SEC, ERR_UNBOND_COOLDOWN_ACTIVE);
        assert!(now_sec >= profile.jailed_until_sec, ERR_SOLVER_JAILED_OR_INACTIVE);

        let withdrawn = profile.bond_amount;
        profile.bond_amount = 0;
        state.total_bonded = state.total_bonded - withdrawn;
        withdrawn
    }

    // =========================================================================
    // Bidding Eligibility, Reputation & Slashing
    // =========================================================================

    public fun assert_eligible_solver(solver: address, now_sec: u64) acquires SolverRegistryState {
        let state = borrow_global<SolverRegistryState>(@equinox_clear);
        assert!(table::contains(&state.solvers, solver), ERR_SOLVER_NOT_FOUND);
        let profile = table::borrow(&state.solvers, solver);
        assert!(profile.active, ERR_SOLVER_JAILED_OR_INACTIVE);
        assert!(now_sec >= profile.jailed_until_sec, ERR_SOLVER_JAILED_OR_INACTIVE);
        assert!(profile.bond_amount >= state.min_bond_amount, ERR_INSUFFICIENT_BOND);
    }

    public fun record_batch_won(solver: address) acquires SolverRegistryState {
        let state = borrow_global_mut<SolverRegistryState>(@equinox_clear);
        assert!(table::contains(&state.solvers, solver), ERR_SOLVER_NOT_FOUND);
        let profile = table::borrow_mut(&mut state.solvers, solver);
        profile.batches_won = profile.batches_won + 1;
    }

    /// Updates solver EMA reputation toward 1.0 WAD upon timely batch settlement.
    public fun record_settlement_success(
        solver: address,
        surplus_delivered_usd: u128
    ) acquires SolverRegistryState {
        let state = borrow_global_mut<SolverRegistryState>(@equinox_clear);
        assert!(table::contains(&state.solvers, solver), ERR_SOLVER_NOT_FOUND);
        let profile = table::borrow_mut(&mut state.solvers, solver);

        profile.batches_settled = profile.batches_settled + 1;
        profile.lifetime_surplus_usd = profile.lifetime_surplus_usd + surplus_delivered_usd;

        // EMA: rep_new = (1 - alpha) * rep_old + alpha * 1.0
        let wad = fixed_point::wad();
        let one_minus_alpha = wad - EMA_ALPHA_WAD;
        let kept = fixed_point::mul_wad_down(profile.reputation_wad, one_minus_alpha);
        profile.reputation_wad = fixed_point::min_u128(wad, kept + EMA_ALPHA_WAD);
    }

    /// Slashes a solver's bond, decays reputation by 50%, jails the solver,
    /// and forwards seized collateral to the protocol treasury.
    public fun slash_solver(
        solver: address,
        reason_code: u64,
        now_sec: u64
    ): u128 acquires SolverRegistryState {
        let state = borrow_global_mut<SolverRegistryState>(@equinox_clear);
        assert!(table::contains(&state.solvers, solver), ERR_SOLVER_NOT_FOUND);
        let profile = table::borrow_mut(&mut state.solvers, solver);

        let penalty = fixed_point::bps_mul_up(profile.bond_amount, state.slash_bps);
        let actual_slash = fixed_point::min_u128(profile.bond_amount, penalty);

        profile.bond_amount = profile.bond_amount - actual_slash;
        state.total_bonded = state.total_bonded - actual_slash;
        profile.slash_count = profile.slash_count + 1;
        profile.reputation_wad = profile.reputation_wad / 2;
        profile.jailed_until_sec = now_sec + JAIL_DURATION_SEC;

        if (profile.active && profile.bond_amount < state.min_bond_amount) {
            profile.active = false;
            state.active_solver_count = state.active_solver_count - 1;
        };

        let bond_asset = state.bond_asset_id;
        events::emit_solver_slashed(solver, actual_slash, reason_code, profile.jailed_until_sec);
        treasury::collect_fee(bond_asset, actual_slash);
        actual_slash
    }

    public fun governance_sync_min_bond(caller: &signer, new_min_bond: u128) acquires SolverRegistryState {
        capabilities::assert_governance_or_admin(signer::address_of(caller));
        assert!(new_min_bond > 0, ERR_INSUFFICIENT_BOND);
        borrow_global_mut<SolverRegistryState>(@equinox_clear).min_bond_amount = new_min_bond;
    }

    // =========================================================================
    // Views & Reason Accessors
    // =========================================================================

    #[view]
    public fun solver_info(solver: address): (u128, u128, u64, u64, u64, bool) acquires SolverRegistryState {
        let state = borrow_global<SolverRegistryState>(@equinox_clear);
        assert!(table::contains(&state.solvers, solver), ERR_SOLVER_NOT_FOUND);
        let p = table::borrow(&state.solvers, solver);
        (
            p.bond_amount,
            p.reputation_wad,
            p.batches_won,
            p.batches_settled,
            p.slash_count,
            p.active
        )
    }

    #[view]
    public fun total_bonded(): u128 acquires SolverRegistryState {
        borrow_global<SolverRegistryState>(@equinox_clear).total_bonded
    }

    #[view]
    public fun active_solver_count(): u64 acquires SolverRegistryState {
        borrow_global<SolverRegistryState>(@equinox_clear).active_solver_count
    }

    public fun slash_reason_missed_settlement(): u64 { SLASH_REASON_MISSED_SETTLEMENT }
    public fun slash_reason_price_band_breach(): u64 { SLASH_REASON_PRICE_BAND_BREACH }
    public fun slash_reason_invalid_proof(): u64 { SLASH_REASON_INVALID_PROOF }
}
