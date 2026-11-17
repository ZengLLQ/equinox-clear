// Copyright (c) ZengLLQ
// SPDX-License-Identifier: MIT

#[test_only]
module equinox_clear::test_helpers {
    use std::signer;
    use aptos_framework::account;
    use equinox_clear::batch_router;
    use equinox_clear::escrow_ledger;
    use equinox_clear::intent_book;
    use equinox_clear::merkle_verifier;
    use equinox_clear::price_oracle;
    use equinox_clear::range_pool;
    use equinox_clear::solver_registry;

    const DEFAULT_NOW: u64 = 1_700_000_000;
    const WAD: u128 = 1_000_000_000_000_000_000;

    public fun default_now(): u64 { DEFAULT_NOW }
    public fun wad(): u128 { WAD }

    public fun create_signer(addr: address): signer {
        account::create_account_for_test(addr)
    }

    public fun setup_protocol(): (signer, u64) {
        let deployer = account::create_account_for_test(@equinox_clear);
        let now = DEFAULT_NOW;
        batch_router::initialize_protocol(
            &deployer,
            now,
            1,                       // USDC bond asset
            1_000 * WAD,             // min solver bond
            1_000,                   // 10% slash BPS
            500,                     // 5% surplus fee BPS
            300,                     // 3% oracle band BPS
            3_600,                   // 1h volume window
            100_000_000 * WAD        // 100M USD cap
        );
        escrow_ledger::register_asset(&deployer, 1, 6);
        escrow_ledger::register_asset(&deployer, 2, 8);
        escrow_ledger::register_asset(&deployer, 3, 8);
        escrow_ledger::register_asset(&deployer, 4, 8);
        (deployer, now)
    }

    public fun setup_oracle_pair(
        deployer: &signer,
        pair_id: u64,
        base_asset: u64,
        quote_asset: u64,
        price_wad: u128,
        now_sec: u64
    ) {
        price_oracle::register_pair(deployer, pair_id, base_asset, quote_asset, 1, 600, 200);
        price_oracle::submit_quote(deployer, pair_id, price_wad, now_sec);
    }

    public fun onboard_solver(addr: address, bond: u128, now_sec: u64): signer {
        let s = account::create_account_for_test(addr);
        solver_registry::register_solver(&s, bond, now_sec);
        s
    }

    public fun commit_and_reveal(
        trader: &signer,
        sell_asset: u64,
        buy_asset: u64,
        sell_amount: u128,
        min_buy_amount: u128,
        partial_fill_allowed: bool,
        max_fee_bps: u64,
        expiry_sec: u64,
        salt: vector<u8>,
        now_sec: u64
    ): u64 {
        let trader_addr = signer::address_of(trader);
        escrow_ledger::deposit(trader, sell_asset, sell_amount);
        let h = merkle_verifier::compute_intent_commitment(
            trader_addr,
            sell_asset,
            buy_asset,
            sell_amount,
            min_buy_amount,
            partial_fill_allowed,
            max_fee_bps,
            expiry_sec,
            salt
        );
        let comm_id = intent_book::commit_intent(trader, h, expiry_sec, now_sec);
        intent_book::reveal_intent(
            trader,
            comm_id,
            sell_asset,
            buy_asset,
            sell_amount,
            min_buy_amount,
            partial_fill_allowed,
            max_fee_bps,
            salt,
            now_sec + 10
        )
    }

    public fun setup_range_pool_with_liquidity(
        deployer: &signer,
        lp: &signer,
        asset_a: u64,
        asset_b: u64,
        amount_a: u128,
        amount_b: u128,
        initial_price_wad: u128
    ): u64 {
        let pool_id = range_pool::create_pool(
            deployer,
            asset_a,
            asset_b,
            30,
            150,
            10,
            initial_price_wad
        );
        batch_router::deposit_and_mint_range_position(
            lp,
            pool_id,
            asset_a,
            asset_b,
            amount_a,
            amount_b,
            3800,
            4400
        );
        pool_id
    }
}
