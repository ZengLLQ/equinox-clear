// Copyright (c) ZengLLQ
// SPDX-License-Identifier: MIT

/// # Periphery Batch Router & Protocol Bootstrap Entrypoints
///
/// Provides high-level user-facing entrypoints and atomic multi-step helpers
/// coordinating `capabilities`, `circuit_breaker`, `timelock`, `treasury`,
/// `price_oracle`, `solver_registry`, `escrow_ledger`, `intent_book`,
/// `range_pool`, and `batch_auction`.
module equinox_clear::batch_router {
    use equinox_clear::batch_auction;
    use equinox_clear::capabilities;
    use equinox_clear::circuit_breaker;
    use equinox_clear::escrow_ledger;
    use equinox_clear::intent_book;
    use equinox_clear::price_oracle;
    use equinox_clear::range_pool;
    use equinox_clear::solver_registry;
    use equinox_clear::timelock;
    use equinox_clear::treasury;

    // =========================================================================
    // Protocol Bootstrap
    // =========================================================================

    /// Initializes every EquinoxClear subsystem atomically under the deployer account.
    public entry fun initialize_protocol(
        deployer: &signer,
        now_sec: u64,
        bond_asset_id: u64,
        min_solver_bond: u128,
        slash_bps: u64,
        surplus_fee_bps: u64,
        oracle_band_bps: u64,
        window_duration_sec: u64,
        window_volume_cap_usd: u128
    ) {
        capabilities::initialize(deployer);
        circuit_breaker::initialize(deployer, window_duration_sec, window_volume_cap_usd, now_sec);
        timelock::initialize(deployer, 3_600, surplus_fee_bps, min_solver_bond, oracle_band_bps);
        treasury::initialize(deployer, 5_000, 3_000, 2_000);
        price_oracle::initialize(deployer);
        solver_registry::initialize(deployer, bond_asset_id, min_solver_bond, slash_bps);
        escrow_ledger::initialize(deployer);
        intent_book::initialize(deployer);
        range_pool::initialize(deployer);
        batch_auction::initialize(deployer, 60, 60, 30, 60);
    }

    // =========================================================================
    // Atomic Trader & LP Multicall Helpers
    // =========================================================================

    /// Deposits `amount` of `asset_id` and immediately commits a sealed intent hash.
    public fun deposit_and_commit_intent(
        trader: &signer,
        asset_id: u64,
        deposit_amount: u128,
        commitment_hash: vector<u8>,
        expiry_sec: u64,
        now_sec: u64
    ): u64 {
        if (deposit_amount > 0) {
            escrow_ledger::deposit(trader, asset_id, deposit_amount);
        };
        intent_book::commit_intent(trader, commitment_hash, expiry_sec, now_sec)
    }

    /// Cancels an active intent and immediately withdraws the unlocked collateral.
    public fun cancel_and_withdraw(
        trader: &signer,
        intent_id: u64,
        sell_asset: u64,
        now_sec: u64
    ): u128 {
        let unlocked = intent_book::cancel_intent(trader, intent_id, now_sec);
        if (unlocked > 0) {
            escrow_ledger::withdraw(trader, sell_asset, unlocked);
        };
        unlocked
    }

    /// Deposits both assets and mints a concentrated range liquidity position atomically.
    public fun deposit_and_mint_range_position(
        lp: &signer,
        pool_id: u64,
        asset_a: u64,
        asset_b: u64,
        amount_a: u128,
        amount_b: u128,
        lower_tick: u64,
        upper_tick: u64
    ): u64 {
        escrow_ledger::deposit(lp, asset_a, amount_a);
        escrow_ledger::deposit(lp, asset_b, amount_b);
        range_pool::mint_position(lp, pool_id, lower_tick, upper_tick, amount_a, amount_b)
    }

    // =========================================================================
    // Atomic One-Shot 2-Way CoW Batch Settlement Helper
    // =========================================================================

    /// Convenience helper allowing a winning solver to settle a single 2-way CoW
    /// match atomically in one call while enforcing the hot-potato receipt invariant.
    public fun settle_pairwise_cow_batch(
        solver: &signer,
        batch_id: u64,
        intent_a: u64,
        intent_b: u64,
        fill_a_sell: u128,
        fill_b_sell: u128,
        oracle_pair_a: u64,
        oracle_pair_b: u64,
        surplus_a_usd: u128,
        surplus_b_usd: u128,
        notional_volume_usd: u128,
        now_sec: u64
    ) {
        let receipt = batch_auction::begin_batch_settlement(solver, batch_id, now_sec);

        let intents = vector[intent_a, intent_b];
        let sells = vector[fill_a_sell, fill_b_sell];
        let buys = vector[fill_b_sell, fill_a_sell];
        let pairs = vector[oracle_pair_a, oracle_pair_b];
        let surpluses = vector[surplus_a_usd, surplus_b_usd];

        batch_auction::execute_cow_ring_in_batch(
            &mut receipt,
            intents,
            sells,
            buys,
            pairs,
            surpluses,
            now_sec
        );

        batch_auction::finalize_batch_settlement(receipt, notional_volume_usd, false, now_sec);
    }

    // =========================================================================
    // View Lenses
    // =========================================================================

    #[view]
    public fun protocol_snapshot(batch_id: u64): (u64, u64, u128, u8, address, u128, u64) {
        let (cur_id, settled_count, total_surplus) = batch_auction::protocol_stats();
        let (status, winner, win_bid, _, settled_surplus, _) = batch_auction::batch_summary(batch_id);
        (cur_id, settled_count, total_surplus, status, winner, win_bid + settled_surplus, settled_count)
    }
}
