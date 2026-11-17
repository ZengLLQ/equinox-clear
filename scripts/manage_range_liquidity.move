// Copyright (c) ZengLLQ
// SPDX-License-Identifier: MIT

script {
    use equinox_clear::batch_router;
    use equinox_clear::range_pool;

    /// Deposits dual assets, mints a concentrated range LP position, and
    /// collects accrued dynamic swap fees.
    fun manage_range_liquidity_script(
        lp: &signer,
        pool_id: u64,
        asset_a: u64,
        asset_b: u64,
        amount_a: u128,
        amount_b: u128,
        lower_tick: u64,
        upper_tick: u64
    ) {
        let pos_id = batch_router::deposit_and_mint_range_position(
            lp,
            pool_id,
            asset_a,
            asset_b,
            amount_a,
            amount_b,
            lower_tick,
            upper_tick
        );
        range_pool::collect_position_fees(lp, pos_id);
    }
}
