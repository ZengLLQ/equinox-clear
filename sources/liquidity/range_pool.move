// Copyright (c) ZengLLQ
// SPDX-License-Identifier: MIT

/// # Concentrated Range Fallback AMM Pool with Volatility-Adaptive Dynamic Fees
///
/// Serves as the residual on-chain liquidity backstop when batch CoW matches
/// leave net order imbalance. Features:
/// - **Concentrated Tick Bounds**: LPs provide virtual liquidity $L$ over discrete
///   tick intervals $[t_{\text{lower}}, t_{\text{upper}}]$ mapped via `tick_bitmap`.
/// - **Constant-Product Within Tick / Range**: Evaluates exact swap outputs using
///   $x \cdot y = L^2$ virtual reserve projections and WAD square-root price updates.
/// - **Dynamic Volatility Pulse Fee**: Adjusts swap fees dynamically from
///   `base_fee_bps` up to `max_fee_bps` based on recent EMA tick displacement:
///   $$f_{\text{dyn}} = \min\left(f_{\max},\; f_{\text{base}} + k_{\text{vol}} \cdot \Delta_{\text{ema}}\right)$$
/// - **LP Fee Growth Accounting**: Tracks global fee-per-liquidity accumulators so
///   LPs harvest fees in $O(1)$ time without iterating over swaps.
module equinox_clear::range_pool {
    use std::signer;
    use aptos_std::table::{Self, Table};
    use equinox_clear::capabilities;
    use equinox_clear::circuit_breaker;
    use equinox_clear::escrow_ledger;
    use equinox_clear::events;
    use equinox_clear::fixed_point;
    use equinox_clear::tick_bitmap::{Self, TickBitmap};

    // =========================================================================
    // Error Constants
    // =========================================================================

    /// Pool ID does not exist
    const ERR_POOL_NOT_FOUND: u64 = 5001;
    /// Pool cannot be created with identical assets or invalid fee parameters
    const ERR_INVALID_POOL_PARAMS: u64 = 5002;
    /// Tick range invalid (lower >= upper or out of domain)
    const ERR_INVALID_TICK_RANGE: u64 = 5003;
    /// Zero liquidity or token amounts provided
    const ERR_ZERO_LIQUIDITY: u64 = 5004;
    /// Position ID not found or caller is not owner
    const ERR_POSITION_NOT_FOUND: u64 = 5005;
    /// Swap output fell below min_amount_out slippage guard
    const ERR_SLIPPAGE_EXCEEDED: u64 = 5006;
    /// Insufficient pool liquidity or reserve for swap
    const ERR_INSUFFICIENT_POOL_LIQUIDITY: u64 = 5007;
    /// Range pool registry already initialized
    const ERR_ALREADY_INITIALIZED: u64 = 5008;

    const MAX_TICK: u64 = 8192;
    const VOL_EMA_DECAY_WAD: u128 = 800_000_000_000_000_000; // 0.80

    // =========================================================================
    // Types & State
    // =========================================================================

    struct LpPosition has copy, drop, store {
        position_id: u64,
        pool_id: u64,
        owner: address,
        lower_tick: u64,
        upper_tick: u64,
        liquidity: u128,
        fee_growth_last_a_wad: u128,
        fee_growth_last_b_wad: u128,
        tokens_owed_a: u128,
        tokens_owed_b: u128
    }

    struct PoolState has store {
        pool_id: u64,
        asset_a: u64,
        asset_b: u64,
        base_fee_bps: u64,
        max_fee_bps: u64,
        vol_multiplier_bps: u64,
        current_price_wad: u128,
        sqrt_price_wad: u128,
        current_tick: u64,
        active_liquidity: u128,
        reserve_a: u128,
        reserve_b: u128,
        fee_growth_global_a_wad: u128,
        fee_growth_global_b_wad: u128,
        ema_tick_volatility_wad: u128,
        last_swap_sec: u64,
        tick_map: TickBitmap
    }

    struct RangePoolRegistry has key {
        next_pool_id: u64,
        next_position_id: u64,
        pools: Table<u64, PoolState>,
        positions: Table<u64, LpPosition>
    }

    // =========================================================================
    // Initialization & Pool Creation
    // =========================================================================

    public fun initialize(deployer: &signer) {
        assert!(!exists<RangePoolRegistry>(@equinox_clear), ERR_ALREADY_INITIALIZED);
        move_to(deployer, RangePoolRegistry {
            next_pool_id: 1,
            next_position_id: 1,
            pools: table::new<u64, PoolState>(),
            positions: table::new<u64, LpPosition>()
        });
    }

    public fun create_pool(
        caller: &signer,
        asset_a: u64,
        asset_b: u64,
        base_fee_bps: u64,
        max_fee_bps: u64,
        vol_multiplier_bps: u64,
        initial_price_wad: u128
    ): u64 acquires RangePoolRegistry {
        capabilities::assert_admin(signer::address_of(caller));
        assert!(asset_a != asset_b, ERR_INVALID_POOL_PARAMS);
        assert!(base_fee_bps > 0 && max_fee_bps >= base_fee_bps && max_fee_bps <= 1_000, ERR_INVALID_POOL_PARAMS);
        assert!(initial_price_wad > 0, ERR_INVALID_POOL_PARAMS);

        let reg = borrow_global_mut<RangePoolRegistry>(@equinox_clear);
        let pool_id = reg.next_pool_id;
        reg.next_pool_id = pool_id + 1;

        let clamped_p = fixed_point::clamp_u128(
            initial_price_wad,
            tick_bitmap::tick_to_price_wad(0),
            tick_bitmap::tick_to_price_wad(MAX_TICK)
        );
        let init_tick = tick_bitmap::price_wad_to_tick(clamped_p);
        let sqrt_p = fixed_point::sqrt_wad(initial_price_wad);

        table::add(&mut reg.pools, pool_id, PoolState {
            pool_id,
            asset_a,
            asset_b,
            base_fee_bps,
            max_fee_bps,
            vol_multiplier_bps,
            current_price_wad: initial_price_wad,
            sqrt_price_wad: sqrt_p,
            current_tick: init_tick,
            active_liquidity: 0,
            reserve_a: 0,
            reserve_b: 0,
            fee_growth_global_a_wad: 0,
            fee_growth_global_b_wad: 0,
            ema_tick_volatility_wad: 0,
            last_swap_sec: 0,
            tick_map: tick_bitmap::new()
        });

        events::emit_range_pool_created(pool_id, asset_a, asset_b, base_fee_bps, initial_price_wad);
        pool_id
    }

    // =========================================================================
    // Concentrated Liquidity Provision & Fee Harvesting
    // =========================================================================

    /// Mints a concentrated LP position over `[lower_tick, upper_tick]`.
    /// Deposits `amount_a` and `amount_b` from LP's available escrow balance
    /// into the pool reserves and computes effective liquidity $L$.
    public fun mint_position(
        lp: &signer,
        pool_id: u64,
        lower_tick: u64,
        upper_tick: u64,
        amount_a: u128,
        amount_b: u128
    ): u64 acquires RangePoolRegistry {
        assert!(lower_tick < upper_tick && upper_tick <= MAX_TICK, ERR_INVALID_TICK_RANGE);
        assert!(amount_a > 0 && amount_b > 0, ERR_ZERO_LIQUIDITY);

        let lp_addr = signer::address_of(lp);
        let reg = borrow_global_mut<RangePoolRegistry>(@equinox_clear);
        assert!(table::contains(&reg.pools, pool_id), ERR_POOL_NOT_FOUND);
        let pool = table::borrow_mut(&mut reg.pools, pool_id);

        escrow_ledger::move_available_to_amm(lp_addr, pool.asset_a, amount_a);
        escrow_ledger::move_available_to_amm(lp_addr, pool.asset_b, amount_b);

        // Compute concentrated range liquidity L boosted inversely by range width
        let base_l = (fixed_point::sqrt_u256((amount_a as u256) * (amount_b as u256)) as u128);
        assert!(base_l > 0, ERR_ZERO_LIQUIDITY);
        let width_ticks = ((upper_tick - lower_tick) as u128);
        // Narrower range concentrates liquidity proportionally (capped at 10x boost)
        let conc_factor = fixed_point::min_u128(10, fixed_point::max_u128(1, 1000 / width_ticks));
        let liquidity = base_l * conc_factor;

        pool.reserve_a = pool.reserve_a + amount_a;
        pool.reserve_b = pool.reserve_b + amount_b;
        if (pool.current_tick >= lower_tick && pool.current_tick <= upper_tick) {
            pool.active_liquidity = pool.active_liquidity + liquidity;
        };

        tick_bitmap::set_tick(&mut pool.tick_map, lower_tick);
        tick_bitmap::set_tick(&mut pool.tick_map, upper_tick);

        let position_id = reg.next_position_id;
        reg.next_position_id = position_id + 1;

        table::add(&mut reg.positions, position_id, LpPosition {
            position_id,
            pool_id,
            owner: lp_addr,
            lower_tick,
            upper_tick,
            liquidity,
            fee_growth_last_a_wad: pool.fee_growth_global_a_wad,
            fee_growth_last_b_wad: pool.fee_growth_global_b_wad,
            tokens_owed_a: 0,
            tokens_owed_b: 0
        });

        events::emit_range_position_minted(pool_id, position_id, lp_addr, lower_tick, upper_tick, liquidity);
        position_id
    }

    /// Harvests accumulated dynamic swap fees owed to `position_id`.
    public fun collect_position_fees(lp: &signer, position_id: u64): (u128, u128) acquires RangePoolRegistry {
        let lp_addr = signer::address_of(lp);
        let reg = borrow_global_mut<RangePoolRegistry>(@equinox_clear);
        assert!(table::contains(&reg.positions, position_id), ERR_POSITION_NOT_FOUND);
        let pos = table::borrow_mut(&mut reg.positions, position_id);
        assert!(pos.owner == lp_addr, ERR_POSITION_NOT_FOUND);

        let pool = table::borrow_mut(&mut reg.pools, pos.pool_id);
        accrue_position_fees(pos, pool);

        let owed_a = fixed_point::min_u128(pos.tokens_owed_a, pool.reserve_a);
        let owed_b = fixed_point::min_u128(pos.tokens_owed_b, pool.reserve_b);
        pos.tokens_owed_a = pos.tokens_owed_a - owed_a;
        pos.tokens_owed_b = pos.tokens_owed_b - owed_b;
        pool.reserve_a = pool.reserve_a - owed_a;
        pool.reserve_b = pool.reserve_b - owed_b;

        if (owed_a > 0) {
            escrow_ledger::move_amm_to_available(lp_addr, pool.asset_a, owed_a);
        };
        if (owed_b > 0) {
            escrow_ledger::move_amm_to_available(lp_addr, pool.asset_b, owed_b);
        };
        (owed_a, owed_b)
    }

    // =========================================================================
    // Dynamic Volatility-Adaptive Swap Execution (Used by Batch Clearinghouse)
    // =========================================================================

    /// Executes an exact-input swap against `pool_id` using batch escrow funds:
    /// - Credits `amount_in` into AMM reserves in `escrow_ledger`.
    /// - Debits `amount_out` from AMM reserves back to the active batch.
    /// - Updates global fee growth and EMA tick volatility.
    ///
    /// Returns `(amount_out, fee_amount, dynamic_fee_bps, new_price_wad)`.
    public fun swap_exact_in_for_batch(
        pool_id: u64,
        zero_for_one: bool,
        amount_in: u128,
        min_amount_out: u128,
        now_sec: u64
    ): (u128, u128, u64, u128) acquires RangePoolRegistry {
        assert!(amount_in > 0, ERR_ZERO_LIQUIDITY);
        circuit_breaker::assert_pair_active(pool_id);

        let reg = borrow_global_mut<RangePoolRegistry>(@equinox_clear);
        assert!(table::contains(&reg.pools, pool_id), ERR_POOL_NOT_FOUND);
        let pool = table::borrow_mut(&mut reg.pools, pool_id);
        assert!(pool.reserve_a > 0 && pool.reserve_b > 0, ERR_INSUFFICIENT_POOL_LIQUIDITY);
        assert!(pool.active_liquidity > 0, ERR_INSUFFICIENT_POOL_LIQUIDITY);

        let dyn_fee_bps = compute_dynamic_fee_bps(pool);
        let fee_amount = fixed_point::bps_mul_up(amount_in, dyn_fee_bps);
        let amount_in_net = amount_in - fee_amount;

        let (res_in, res_out) = if (zero_for_one) {
            (pool.reserve_a, pool.reserve_b)
        } else {
            (pool.reserve_b, pool.reserve_a)
        };

        // Constant product output over pool reserves: out = (res_out * in_net) / (res_in + in_net)
        let amount_out = fixed_point::mul_div_down(res_out, amount_in_net, res_in + amount_in_net);
        assert!(amount_out >= min_amount_out && amount_out > 0, ERR_SLIPPAGE_EXCEEDED);
        assert!(amount_out < res_out, ERR_INSUFFICIENT_POOL_LIQUIDITY);

        // Update reserves & fee accumulators
        let (in_asset, out_asset) = if (zero_for_one) {
            pool.reserve_a = pool.reserve_a + amount_in;
            pool.reserve_b = pool.reserve_b - amount_out;
            let fg_inc = fixed_point::div_wad_down(fee_amount, pool.active_liquidity);
            pool.fee_growth_global_a_wad = pool.fee_growth_global_a_wad + fg_inc;
            (pool.asset_a, pool.asset_b)
        } else {
            pool.reserve_b = pool.reserve_b + amount_in;
            pool.reserve_a = pool.reserve_a - amount_out;
            let fg_inc = fixed_point::div_wad_down(fee_amount, pool.active_liquidity);
            pool.fee_growth_global_b_wad = pool.fee_growth_global_b_wad + fg_inc;
            (pool.asset_b, pool.asset_a)
        };

        escrow_ledger::credit_amm_from_batch(in_asset, amount_in);
        escrow_ledger::debit_amm_to_batch(out_asset, amount_out);

        // Update spot price = reserve_b / reserve_a in WAD & EMA volatility
        let new_price_wad = fixed_point::div_wad_down(pool.reserve_b, pool.reserve_a);
        let clamped = fixed_point::clamp_u128(
            new_price_wad,
            tick_bitmap::tick_to_price_wad(0),
            tick_bitmap::tick_to_price_wad(MAX_TICK)
        );
        let new_tick = tick_bitmap::price_wad_to_tick(clamped);
        let tick_delta = fixed_point::abs_diff_u64(new_tick, pool.current_tick);

        let delta_wad = (tick_delta as u128) * fixed_point::wad();
        let decayed = fixed_point::mul_wad_down(pool.ema_tick_volatility_wad, VOL_EMA_DECAY_WAD);
        let one_minus = fixed_point::wad() - VOL_EMA_DECAY_WAD;
        pool.ema_tick_volatility_wad = decayed + fixed_point::mul_wad_down(delta_wad, one_minus);

        pool.current_price_wad = new_price_wad;
        pool.sqrt_price_wad = fixed_point::sqrt_wad(new_price_wad);
        pool.current_tick = new_tick;
        pool.last_swap_sec = now_sec;

        events::emit_range_pool_swap(
            pool_id,
            zero_for_one,
            amount_in,
            amount_out,
            dyn_fee_bps,
            new_price_wad
        );

        (amount_out, fee_amount, dyn_fee_bps, new_price_wad)
    }

    // =========================================================================
    // Quoting & Views
    // =========================================================================

    #[view]
    public fun quote_exact_in(pool_id: u64, zero_for_one: bool, amount_in: u128): (u128, u64) acquires RangePoolRegistry {
        let reg = borrow_global<RangePoolRegistry>(@equinox_clear);
        assert!(table::contains(&reg.pools, pool_id), ERR_POOL_NOT_FOUND);
        let pool = table::borrow(&reg.pools, pool_id);
        let dyn_fee_bps = compute_dynamic_fee_bps(pool);
        let fee_amount = fixed_point::bps_mul_up(amount_in, dyn_fee_bps);
        let in_net = amount_in - fee_amount;

        let (res_in, res_out) = if (zero_for_one) {
            (pool.reserve_a, pool.reserve_b)
        } else {
            (pool.reserve_b, pool.reserve_a)
        };
        if (res_in == 0 || res_out == 0) {
            return (0, dyn_fee_bps)
        };
        let out = fixed_point::mul_div_down(res_out, in_net, res_in + in_net);
        (out, dyn_fee_bps)
    }

    #[view]
    public fun pool_state(pool_id: u64): (u64, u64, u128, u128, u128, u128, u64, u64) acquires RangePoolRegistry {
        let reg = borrow_global<RangePoolRegistry>(@equinox_clear);
        assert!(table::contains(&reg.pools, pool_id), ERR_POOL_NOT_FOUND);
        let p = table::borrow(&reg.pools, pool_id);
        (
            p.asset_a,
            p.asset_b,
            p.reserve_a,
            p.reserve_b,
            p.active_liquidity,
            p.current_price_wad,
            p.current_tick,
            compute_dynamic_fee_bps(p)
        )
    }

    #[view]
    public fun position_info(position_id: u64): (address, u64, u64, u64, u128) acquires RangePoolRegistry {
        let reg = borrow_global<RangePoolRegistry>(@equinox_clear);
        assert!(table::contains(&reg.positions, position_id), ERR_POSITION_NOT_FOUND);
        let pos = table::borrow(&reg.positions, position_id);
        (pos.owner, pos.pool_id, pos.lower_tick, pos.upper_tick, pos.liquidity)
    }

    // =========================================================================
    // Internal Helpers
    // =========================================================================

    fun compute_dynamic_fee_bps(pool: &PoolState): u64 {
        let vol_ticks = (pool.ema_tick_volatility_wad / fixed_point::wad() as u64);
        let extra = vol_ticks * pool.vol_multiplier_bps;
        fixed_point::min_u64(pool.max_fee_bps, pool.base_fee_bps + extra)
    }

    fun accrue_position_fees(pos: &mut LpPosition, pool: &PoolState) {
        let delta_a = pool.fee_growth_global_a_wad - pos.fee_growth_last_a_wad;
        let delta_b = pool.fee_growth_global_b_wad - pos.fee_growth_last_b_wad;

        if (delta_a > 0) {
            pos.tokens_owed_a = pos.tokens_owed_a + fixed_point::mul_wad_down(pos.liquidity, delta_a);
            pos.fee_growth_last_a_wad = pool.fee_growth_global_a_wad;
        };
        if (delta_b > 0) {
            pos.tokens_owed_b = pos.tokens_owed_b + fixed_point::mul_wad_down(pos.liquidity, delta_b);
            pos.fee_growth_last_b_wad = pool.fee_growth_global_b_wad;
        };
    }
}
