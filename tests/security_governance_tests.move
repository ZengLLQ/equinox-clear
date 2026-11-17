// Copyright (c) ZengLLQ
// SPDX-License-Identifier: MIT

#[test_only]
module equinox_clear::security_governance_tests {
    use equinox_clear::capabilities;
    use equinox_clear::circuit_breaker;
    use equinox_clear::test_helpers;
    use equinox_clear::timelock;
    use equinox_clear::treasury;

    #[test]
    fun test_two_step_admin_transfer_and_guardian() {
        let (deployer, _) = test_helpers::setup_protocol();
        let next_admin = test_helpers::create_signer(@0xA11CE);
        let guardian = test_helpers::create_signer(@0x60A9);

        capabilities::propose_admin(&deployer, @0xA11CE);
        assert!(capabilities::pending_admin() == @0xA11CE, 1);
        capabilities::accept_admin(&next_admin);
        assert!(capabilities::admin() == @0xA11CE, 2);

        capabilities::set_guardian(&next_admin, @0x60A9, true);
        assert!(capabilities::is_guardian(@0x60A9), 3);
        assert!(capabilities::guardian_count() == 2, 4);

        let now = test_helpers::default_now();
        circuit_breaker::trip_global_pause(&guardian, now);
        assert!(circuit_breaker::is_globally_paused(), 5);

        circuit_breaker::lift_global_pause(&next_admin);
        assert!(!circuit_breaker::is_globally_paused(), 6);
    }

    #[test]
    fun test_timelock_queue_execute_and_treasury_splits() {
        let (deployer, now) = test_helpers::setup_protocol();
        let action_id = timelock::queue_action(
            &deployer,
            timelock::action_kind_surplus_fee(),
            0,
            750, // raise surplus fee from 500 to 750 bps
            now
        );
        let (st, eta, _) = timelock::action_status(action_id);
        assert!(st == timelock::status_queued(), 1);
        assert!(eta == now + 3_600, 2);

        timelock::execute_action(&deployer, action_id, now + 3_600);
        assert!(timelock::surplus_fee_bps() == 750, 3);

        // Treasury split check: 50% reserve, 30% solver rebate, 20% LP
        treasury::collect_fee(1, 10_000);
        let (res, reb, lp_inc, life) = treasury::asset_balances(1);
        assert!(res == 5_000 && reb == 3_000 && lp_inc == 2_000 && life == 10_000, 4);
    }

    #[test]
    #[expected_failure(abort_code = 2303, location = equinox_clear::timelock)]
    fun test_timelock_early_execution_aborts() {
        let (deployer, now) = test_helpers::setup_protocol();
        let action_id = timelock::queue_action(
            &deployer,
            timelock::action_kind_oracle_band(),
            0,
            400,
            now
        );
        timelock::execute_action(&deployer, action_id, now + 100);
    }

    #[test]
    #[expected_failure(abort_code = 2103, location = equinox_clear::circuit_breaker)]
    fun test_sliding_window_volume_cap_enforced() {
        let (_deployer, now) = test_helpers::setup_protocol();
        let wad = test_helpers::wad();
        circuit_breaker::record_and_check_volume(80_000_000 * wad, now);
        // Exceeds 100M USD cap in same 3600s window
        circuit_breaker::record_and_check_volume(25_000_000 * wad, now + 100);
    }
}
