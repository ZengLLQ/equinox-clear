// Copyright (c) ZengLLQ
// SPDX-License-Identifier: MIT

/// # Isolated Multi-Asset Escrow & Conservation Ledger
///
/// Tracks per-asset balances across user available funds, intent-locked escrows,
/// concentrated range pool liquidity, and protocol fees with a strict global
/// conservation invariant for every `asset_id`:
/// $$\text{total\_reserves} = \text{total\_available} + \text{total\_locked} + \text{total\_amm\_reserves} + \text{total\_fees}$$
module equinox_clear::escrow_ledger {
    use std::signer;
    use aptos_std::table::{Self, Table};
    use equinox_clear::capabilities;

    // =========================================================================
    // Error Constants
    // =========================================================================

    /// Asset ID is not registered in the escrow ledger
    const ERR_ASSET_NOT_REGISTERED: u64 = 4001;
    /// Asset ID already registered
    const ERR_ASSET_ALREADY_REGISTERED: u64 = 4002;
    /// Insufficient available balance for withdrawal or lock
    const ERR_INSUFFICIENT_AVAILABLE: u64 = 4003;
    /// Insufficient locked escrow balance for release or settlement
    const ERR_INSUFFICIENT_LOCKED: u64 = 4004;
    /// Deposit or transfer amount must be strictly positive
    const ERR_ZERO_AMOUNT: u64 = 4005;
    /// Escrow ledger already initialized
    const ERR_ALREADY_INITIALIZED: u64 = 4006;
    /// Insufficient AMM pool reserve for output transfer
    const ERR_INSUFFICIENT_AMM_RESERVE: u64 = 4007;

    // =========================================================================
    // Types & Storage
    // =========================================================================

    struct UserAssetKey has copy, drop, store {
        user: address,
        asset_id: u64
    }

    struct UserBalance has copy, drop, store {
        available: u128,
        locked: u128
    }

    struct AssetSupply has copy, drop, store {
        asset_id: u64,
        decimals: u8,
        total_reserves: u128,
        total_available: u128,
        total_locked: u128,
        total_amm_reserves: u128,
        total_fees: u128
    }

    struct EscrowLedgerState has key {
        assets: Table<u64, AssetSupply>,
        user_balances: Table<UserAssetKey, UserBalance>,
        registered_asset_count: u64
    }

    // =========================================================================
    // Initialization & Asset Registration
    // =========================================================================

    public fun initialize(deployer: &signer) {
        assert!(!exists<EscrowLedgerState>(@equinox_clear), ERR_ALREADY_INITIALIZED);
        move_to(deployer, EscrowLedgerState {
            assets: table::new<u64, AssetSupply>(),
            user_balances: table::new<UserAssetKey, UserBalance>(),
            registered_asset_count: 0
        });
    }

    public fun register_asset(caller: &signer, asset_id: u64, decimals: u8) acquires EscrowLedgerState {
        capabilities::assert_admin(signer::address_of(caller));
        let state = borrow_global_mut<EscrowLedgerState>(@equinox_clear);
        assert!(!table::contains(&state.assets, asset_id), ERR_ASSET_ALREADY_REGISTERED);
        table::add(&mut state.assets, asset_id, AssetSupply {
            asset_id,
            decimals,
            total_reserves: 0,
            total_available: 0,
            total_locked: 0,
            total_amm_reserves: 0,
            total_fees: 0
        });
        state.registered_asset_count = state.registered_asset_count + 1;
    }

    // =========================================================================
    // User Deposit / Withdraw (Available Balance)
    // =========================================================================

    public fun deposit(user: &signer, asset_id: u64, amount: u128) acquires EscrowLedgerState {
        deposit_for(signer::address_of(user), asset_id, amount);
    }

    public fun deposit_for(user_addr: address, asset_id: u64, amount: u128) acquires EscrowLedgerState {
        assert!(amount > 0, ERR_ZERO_AMOUNT);
        let state = borrow_global_mut<EscrowLedgerState>(@equinox_clear);
        assert!(table::contains(&state.assets, asset_id), ERR_ASSET_NOT_REGISTERED);

        let supply = table::borrow_mut(&mut state.assets, asset_id);
        supply.total_reserves = supply.total_reserves + amount;
        supply.total_available = supply.total_available + amount;

        let bal = borrow_or_create_balance_mut(&mut state.user_balances, user_addr, asset_id);
        bal.available = bal.available + amount;
    }

    public fun withdraw(user: &signer, asset_id: u64, amount: u128) acquires EscrowLedgerState {
        assert!(amount > 0, ERR_ZERO_AMOUNT);
        let user_addr = signer::address_of(user);
        let state = borrow_global_mut<EscrowLedgerState>(@equinox_clear);
        assert!(table::contains(&state.assets, asset_id), ERR_ASSET_NOT_REGISTERED);

        let bal = borrow_or_create_balance_mut(&mut state.user_balances, user_addr, asset_id);
        assert!(bal.available >= amount, ERR_INSUFFICIENT_AVAILABLE);
        bal.available = bal.available - amount;

        let supply = table::borrow_mut(&mut state.assets, asset_id);
        supply.total_available = supply.total_available - amount;
        supply.total_reserves = supply.total_reserves - amount;
    }

    // =========================================================================
    // Intent Escrow Locking & Settlement Primitives
    // =========================================================================

    /// Moves `amount` from user's `available` balance into `locked` intent escrow.
    public fun lock_for_intent(user_addr: address, asset_id: u64, amount: u128) acquires EscrowLedgerState {
        assert!(amount > 0, ERR_ZERO_AMOUNT);
        let state = borrow_global_mut<EscrowLedgerState>(@equinox_clear);
        assert!(table::contains(&state.assets, asset_id), ERR_ASSET_NOT_REGISTERED);

        let bal = borrow_or_create_balance_mut(&mut state.user_balances, user_addr, asset_id);
        assert!(bal.available >= amount, ERR_INSUFFICIENT_AVAILABLE);
        bal.available = bal.available - amount;
        bal.locked = bal.locked + amount;

        let supply = table::borrow_mut(&mut state.assets, asset_id);
        supply.total_available = supply.total_available - amount;
        supply.total_locked = supply.total_locked + amount;
    }

    /// Unlocks `amount` back to user's `available` balance upon intent cancellation/expiry.
    public fun unlock_from_intent(user_addr: address, asset_id: u64, amount: u128) acquires EscrowLedgerState {
        if (amount == 0) {
            return
        };
        let state = borrow_global_mut<EscrowLedgerState>(@equinox_clear);
        assert!(table::contains(&state.assets, asset_id), ERR_ASSET_NOT_REGISTERED);

        let bal = borrow_or_create_balance_mut(&mut state.user_balances, user_addr, asset_id);
        assert!(bal.locked >= amount, ERR_INSUFFICIENT_LOCKED);
        bal.locked = bal.locked - amount;
        bal.available = bal.available + amount;

        let supply = table::borrow_mut(&mut state.assets, asset_id);
        supply.total_locked = supply.total_locked - amount;
        supply.total_available = supply.total_available + amount;
    }

    /// Debits `amount` out of a user's `locked` escrow into the active settlement batch.
    public fun debit_locked_to_batch(user_addr: address, asset_id: u64, amount: u128) acquires EscrowLedgerState {
        assert!(amount > 0, ERR_ZERO_AMOUNT);
        let state = borrow_global_mut<EscrowLedgerState>(@equinox_clear);
        assert!(table::contains(&state.assets, asset_id), ERR_ASSET_NOT_REGISTERED);

        let bal = borrow_or_create_balance_mut(&mut state.user_balances, user_addr, asset_id);
        assert!(bal.locked >= amount, ERR_INSUFFICIENT_LOCKED);
        bal.locked = bal.locked - amount;

        let supply = table::borrow_mut(&mut state.assets, asset_id);
        supply.total_locked = supply.total_locked - amount;
    }

    /// Credits `amount` from the active settlement batch into a user's `available` balance.
    public fun credit_available_from_batch(user_addr: address, asset_id: u64, amount: u128) acquires EscrowLedgerState {
        if (amount == 0) {
            return
        };
        let state = borrow_global_mut<EscrowLedgerState>(@equinox_clear);
        assert!(table::contains(&state.assets, asset_id), ERR_ASSET_NOT_REGISTERED);

        let bal = borrow_or_create_balance_mut(&mut state.user_balances, user_addr, asset_id);
        bal.available = bal.available + amount;

        let supply = table::borrow_mut(&mut state.assets, asset_id);
        supply.total_available = supply.total_available + amount;
    }

    /// Moves `amount` from settlement batch into protocol fee reserves for `asset_id`.
    public fun credit_protocol_fee_from_batch(asset_id: u64, amount: u128) acquires EscrowLedgerState {
        if (amount == 0) {
            return
        };
        let state = borrow_global_mut<EscrowLedgerState>(@equinox_clear);
        assert!(table::contains(&state.assets, asset_id), ERR_ASSET_NOT_REGISTERED);
        let supply = table::borrow_mut(&mut state.assets, asset_id);
        supply.total_fees = supply.total_fees + amount;
    }

    // =========================================================================
    // AMM Pool Reserve Accounting
    // =========================================================================

    /// Transfers `amount` from LP's `available` balance into `total_amm_reserves`.
    public fun move_available_to_amm(lp_addr: address, asset_id: u64, amount: u128) acquires EscrowLedgerState {
        if (amount == 0) {
            return
        };
        let state = borrow_global_mut<EscrowLedgerState>(@equinox_clear);
        assert!(table::contains(&state.assets, asset_id), ERR_ASSET_NOT_REGISTERED);

        let bal = borrow_or_create_balance_mut(&mut state.user_balances, lp_addr, asset_id);
        assert!(bal.available >= amount, ERR_INSUFFICIENT_AVAILABLE);
        bal.available = bal.available - amount;

        let supply = table::borrow_mut(&mut state.assets, asset_id);
        supply.total_available = supply.total_available - amount;
        supply.total_amm_reserves = supply.total_amm_reserves + amount;
    }

    /// Transfers `amount` from `total_amm_reserves` back to LP's `available` balance.
    public fun move_amm_to_available(lp_addr: address, asset_id: u64, amount: u128) acquires EscrowLedgerState {
        if (amount == 0) {
            return
        };
        let state = borrow_global_mut<EscrowLedgerState>(@equinox_clear);
        assert!(table::contains(&state.assets, asset_id), ERR_ASSET_NOT_REGISTERED);

        let supply = table::borrow_mut(&mut state.assets, asset_id);
        assert!(supply.total_amm_reserves >= amount, ERR_INSUFFICIENT_AMM_RESERVE);
        supply.total_amm_reserves = supply.total_amm_reserves - amount;
        supply.total_available = supply.total_available + amount;

        let bal = borrow_or_create_balance_mut(&mut state.user_balances, lp_addr, asset_id);
        bal.available = bal.available + amount;
    }

    /// Credits AMM reserves when a batch routes input into the range pool.
    public fun credit_amm_from_batch(asset_id: u64, amount: u128) acquires EscrowLedgerState {
        if (amount == 0) {
            return
        };
        let state = borrow_global_mut<EscrowLedgerState>(@equinox_clear);
        assert!(table::contains(&state.assets, asset_id), ERR_ASSET_NOT_REGISTERED);
        let supply = table::borrow_mut(&mut state.assets, asset_id);
        supply.total_amm_reserves = supply.total_amm_reserves + amount;
    }

    /// Debits AMM reserves when a batch withdraws swap output from the range pool.
    public fun debit_amm_to_batch(asset_id: u64, amount: u128) acquires EscrowLedgerState {
        if (amount == 0) {
            return
        };
        let state = borrow_global_mut<EscrowLedgerState>(@equinox_clear);
        assert!(table::contains(&state.assets, asset_id), ERR_ASSET_NOT_REGISTERED);
        let supply = table::borrow_mut(&mut state.assets, asset_id);
        assert!(supply.total_amm_reserves >= amount, ERR_INSUFFICIENT_AMM_RESERVE);
        supply.total_amm_reserves = supply.total_amm_reserves - amount;
    }

    // =========================================================================
    // Views & Conservation Invariant Check
    // =========================================================================

    #[view]
    public fun balance_of(user: address, asset_id: u64): (u128, u128) acquires EscrowLedgerState {
        let state = borrow_global<EscrowLedgerState>(@equinox_clear);
        let key = UserAssetKey { user, asset_id };
        if (!table::contains(&state.user_balances, key)) {
            return (0, 0)
        };
        let b = table::borrow(&state.user_balances, key);
        (b.available, b.locked)
    }

    #[view]
    public fun asset_totals(asset_id: u64): (u128, u128, u128, u128, u128) acquires EscrowLedgerState {
        let state = borrow_global<EscrowLedgerState>(@equinox_clear);
        assert!(table::contains(&state.assets, asset_id), ERR_ASSET_NOT_REGISTERED);
        let s = table::borrow(&state.assets, asset_id);
        (s.total_reserves, s.total_available, s.total_locked, s.total_amm_reserves, s.total_fees)
    }

    #[view]
    public fun verify_conservation(asset_id: u64): bool acquires EscrowLedgerState {
        let (reserves, avail, locked, amm, fees) = asset_totals(asset_id);
        reserves == avail + locked + amm + fees
    }

    public fun is_asset_registered(asset_id: u64): bool acquires EscrowLedgerState {
        let state = borrow_global<EscrowLedgerState>(@equinox_clear);
        table::contains(&state.assets, asset_id)
    }

    // =========================================================================
    // Internal Helpers
    // =========================================================================

    fun borrow_or_create_balance_mut(
        tbl: &mut Table<UserAssetKey, UserBalance>,
        user: address,
        asset_id: u64
    ): &mut UserBalance {
        let key = UserAssetKey { user, asset_id };
        if (!table::contains(tbl, key)) {
            table::add(tbl, key, UserBalance { available: 0, locked: 0 });
        };
        table::borrow_mut(tbl, key)
    }
}
