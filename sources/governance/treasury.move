// Copyright (c) ZengLLQ
// SPDX-License-Identifier: MIT

/// # Protocol Fee Treasury & Tri-Bucket Revenue Distributor
///
/// Collects batch surplus protocol fees and solver slashing proceeds across
/// arbitrary asset IDs and deterministically routes every collected unit into
/// three accounting buckets summing to `10,000` BPS:
/// 1. **Protocol Reserve**: Core insurance and runway fund
/// 2. **Solver Rebate Pool**: Gas/rebate incentives for high-surplus solvers
/// 3. **LP Incentive Bucket**: Rewards distributed to concentrated range LPs
module equinox_clear::treasury {
    use std::signer;
    use aptos_std::table::{Self, Table};
    use equinox_clear::capabilities;
    use equinox_clear::events;
    use equinox_clear::fixed_point;

    // =========================================================================
    // Error Constants
    // =========================================================================

    /// Revenue split BPS values do not sum to exactly 10,000
    const ERR_INVALID_SPLIT_SUM: u64 = 2401;
    /// Insufficient balance in target treasury bucket for withdrawal
    const ERR_INSUFFICIENT_TREASURY_BALANCE: u64 = 2402;
    /// Treasury already initialized
    const ERR_ALREADY_INITIALIZED: u64 = 2403;

    const BPS_FULL: u64 = 10_000;

    // =========================================================================
    // State Resource
    // =========================================================================

    struct AssetRevenue has copy, drop, store {
        reserve_balance: u128,
        solver_rebate_balance: u128,
        lp_incentive_balance: u128,
        lifetime_collected: u128
    }

    struct TreasuryState has key {
        reserve_bps: u64,
        solver_rebate_bps: u64,
        lp_incentive_bps: u64,
        balances: Table<u64, AssetRevenue>
    }

    // =========================================================================
    // Initialization & Configuration
    // =========================================================================

    public fun initialize(
        deployer: &signer,
        reserve_bps: u64,
        solver_rebate_bps: u64,
        lp_incentive_bps: u64
    ) {
        assert!(!exists<TreasuryState>(@equinox_clear), ERR_ALREADY_INITIALIZED);
        assert!(reserve_bps + solver_rebate_bps + lp_incentive_bps == BPS_FULL, ERR_INVALID_SPLIT_SUM);

        move_to(deployer, TreasuryState {
            reserve_bps,
            solver_rebate_bps,
            lp_incentive_bps,
            balances: table::new<u64, AssetRevenue>()
        });
    }

    public fun update_splits(
        caller: &signer,
        reserve_bps: u64,
        solver_rebate_bps: u64,
        lp_incentive_bps: u64
    ) acquires TreasuryState {
        capabilities::assert_governance_or_admin(signer::address_of(caller));
        assert!(reserve_bps + solver_rebate_bps + lp_incentive_bps == BPS_FULL, ERR_INVALID_SPLIT_SUM);
        let state = borrow_global_mut<TreasuryState>(@equinox_clear);
        state.reserve_bps = reserve_bps;
        state.solver_rebate_bps = solver_rebate_bps;
        state.lp_incentive_bps = lp_incentive_bps;
    }

    // =========================================================================
    // Fee Collection & Claiming
    // =========================================================================

    /// Splits `amount` cleanly across Reserve, Solver Rebate, and LP Incentive
    /// buckets with remainder assigned to Reserve so `r + s + l == amount` exactly.
    public fun collect_fee(asset_id: u64, amount: u128) acquires TreasuryState {
        if (amount == 0) {
            return
        };
        let state = borrow_global_mut<TreasuryState>(@equinox_clear);
        let solver_share = fixed_point::bps_mul_down(amount, state.solver_rebate_bps);
        let lp_share = fixed_point::bps_mul_down(amount, state.lp_incentive_bps);
        let reserve_share = amount - solver_share - lp_share;

        if (!table::contains(&state.balances, asset_id)) {
            table::add(&mut state.balances, asset_id, AssetRevenue {
                reserve_balance: 0,
                solver_rebate_balance: 0,
                lp_incentive_balance: 0,
                lifetime_collected: 0
            });
        };

        let rev = table::borrow_mut(&mut state.balances, asset_id);
        rev.reserve_balance = rev.reserve_balance + reserve_share;
        rev.solver_rebate_balance = rev.solver_rebate_balance + solver_share;
        rev.lp_incentive_balance = rev.lp_incentive_balance + lp_share;
        rev.lifetime_collected = rev.lifetime_collected + amount;

        events::emit_treasury_collected(asset_id, amount, reserve_share, solver_share, lp_share);
    }

    /// Withdraws from the Protocol Reserve bucket under Admin authorization.
    public fun withdraw_reserve(
        caller: &signer,
        asset_id: u64,
        amount: u128
    ): u128 acquires TreasuryState {
        capabilities::assert_admin(signer::address_of(caller));
        let state = borrow_global_mut<TreasuryState>(@equinox_clear);
        assert!(table::contains(&state.balances, asset_id), ERR_INSUFFICIENT_TREASURY_BALANCE);
        let rev = table::borrow_mut(&mut state.balances, asset_id);
        assert!(rev.reserve_balance >= amount, ERR_INSUFFICIENT_TREASURY_BALANCE);
        rev.reserve_balance = rev.reserve_balance - amount;
        amount
    }

    /// Consumes solver rebate balance for rewarding high-performing batch solvers.
    public fun disburse_solver_rebate(asset_id: u64, max_amount: u128): u128 acquires TreasuryState {
        let state = borrow_global_mut<TreasuryState>(@equinox_clear);
        if (!table::contains(&state.balances, asset_id)) {
            return 0
        };
        let rev = table::borrow_mut(&mut state.balances, asset_id);
        let payout = fixed_point::min_u128(rev.solver_rebate_balance, max_amount);
        rev.solver_rebate_balance = rev.solver_rebate_balance - payout;
        payout
    }

    // =========================================================================
    // Views
    // =========================================================================

    #[view]
    public fun asset_balances(asset_id: u64): (u128, u128, u128, u128) acquires TreasuryState {
        let state = borrow_global<TreasuryState>(@equinox_clear);
        if (!table::contains(&state.balances, asset_id)) {
            return (0, 0, 0, 0)
        };
        let rev = table::borrow(&state.balances, asset_id);
        (
            rev.reserve_balance,
            rev.solver_rebate_balance,
            rev.lp_incentive_balance,
            rev.lifetime_collected
        )
    }

    #[view]
    public fun total_asset_treasury(asset_id: u64): u128 acquires TreasuryState {
        let (r, s, l, _) = asset_balances(asset_id);
        r + s + l
    }
}
