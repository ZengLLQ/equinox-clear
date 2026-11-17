// Copyright (c) ZengLLQ
// SPDX-License-Identifier: MIT

script {
    use equinox_clear::batch_router;
    use equinox_clear::escrow_ledger;
    use equinox_clear::price_oracle;
    use equinox_clear::range_pool;

    /// Bootstraps the EquinoxClear protocol, registers core assets, creates an
    /// oracle price pair, and opens the first concentrated fallback pool.
    fun initialize_protocol_script(
        deployer: &signer,
        now_sec: u64,
        min_solver_bond: u128,
        initial_price_wad: u128
    ) {
        batch_router::initialize_protocol(
            deployer,
            now_sec,
            1, // USDC bond asset ID
            min_solver_bond,
            1_000, // 10% slash BPS
            500,   // 5% surplus fee BPS
            300,   // 3% oracle band BPS
            3_600, // 1h sliding volume window
            10_000_000_000_000_000_000_000_000 // 10M USD WAD cap
        );

        escrow_ledger::register_asset(deployer, 1, 6);
        escrow_ledger::register_asset(deployer, 2, 8);
        escrow_ledger::register_asset(deployer, 3, 8);

        price_oracle::register_pair(deployer, 1, 2, 1, 1, 600, 200);
        range_pool::create_pool(deployer, 1, 2, 30, 150, 10, initial_price_wad);
    }
}
