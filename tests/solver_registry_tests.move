// Copyright (c) ZengLLQ
// SPDX-License-Identifier: MIT

#[test_only]
module equinox_clear::solver_registry_tests {
    use equinox_clear::solver_registry;
    use equinox_clear::test_helpers;
    use equinox_clear::treasury;

    #[test]
    fun test_solver_onboarding_reputation_and_slashing() {
        let (_deployer, now) = test_helpers::setup_protocol();
        let wad = test_helpers::wad();

        let s1 = test_helpers::onboard_solver(@0x501, 2_000 * wad, now);
        let (bond, rep, won, settled, slashes, active) = solver_registry::solver_info(@0x501);
        assert!(bond == 2_000 * wad, 1);
        assert!(rep == 500_000_000_000_000_000, 2); // 0.50 initial
        assert!(won == 0 && settled == 0 && slashes == 0 && active, 3);

        // Successful settlement increases EMA reputation: 0.8*0.5 + 0.2*1.0 = 0.60
        solver_registry::record_batch_won(@0x501);
        solver_registry::record_settlement_success(@0x501, 50 * wad);
        let (_, rep2, won2, settled2, _, _) = solver_registry::solver_info(@0x501);
        assert!(rep2 == 600_000_000_000_000_000, 4);
        assert!(won2 == 1 && settled2 == 1, 5);

        // Slash 10% (200 WAD) -> bond drops to 1800 WAD, reputation halved to 0.30, treasury receives 200 WAD
        let slashed = solver_registry::slash_solver(
            @0x501,
            solver_registry::slash_reason_missed_settlement(),
            now + 100
        );
        assert!(slashed == 200 * wad, 6);
        assert!(treasury::total_asset_treasury(1) == 200 * wad, 7);

        let (bond3, rep3, _, _, slashes3, _) = solver_registry::solver_info(@0x501);
        assert!(bond3 == 1_800 * wad, 8);
        assert!(rep3 == 300_000_000_000_000_000, 9);
        assert!(slashes3 == 1, 10);

        // Unbond lifecycle after jail expires
        solver_registry::request_unbond(&s1, now + 4_000);
        let withdrawn = solver_registry::complete_unbond(&s1, now + 4_000 + 86_400);
        assert!(withdrawn == 1_800 * wad, 11);
        assert!(solver_registry::total_bonded() == 0, 12);
    }

    #[test]
    #[expected_failure(abort_code = 3104, location = equinox_clear::solver_registry)]
    fun test_jailed_solver_rejected() {
        let (_deployer, now) = test_helpers::setup_protocol();
        let wad = test_helpers::wad();
        test_helpers::onboard_solver(@0x502, 2_000 * wad, now);
        solver_registry::slash_solver(@0x502, solver_registry::slash_reason_price_band_breach(), now + 10);
        solver_registry::assert_eligible_solver(@0x502, now + 100);
    }
}
