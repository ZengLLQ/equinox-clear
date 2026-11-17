// Copyright (c) ZengLLQ
// SPDX-License-Identifier: MIT

/// # Role-Based Access Control & Two-Step Capability Registry
///
/// Manages protocol-level authorization via linear Move resources and explicit
/// address role grants:
/// - **Admin**: Two-step `propose_admin` -> `accept_admin` prevents accidental lockout.
/// - **Guardian**: Instant emergency circuit-breaker authority (cannot seize funds).
/// - **Governance**: Queues and executes timelocked protocol parameter changes.
/// - **OracleFeeder**: Authorized publishers allowed to submit signed spot feeds.
module equinox_clear::capabilities {
    use std::signer;
    use aptos_std::table::{Self, Table};

    // =========================================================================
    // Error Constants
    // =========================================================================

    /// Caller lacks Admin authority
    const ERR_NOT_ADMIN: u64 = 2001;
    /// Caller lacks Guardian or Admin authority
    const ERR_NOT_GUARDIAN: u64 = 2002;
    /// Caller lacks Governance authority
    const ERR_NOT_GOVERNANCE: u64 = 2003;
    /// Caller lacks authorized Oracle Feeder role
    const ERR_NOT_ORACLE_FEEDER: u64 = 2004;
    /// Caller is not the pending admin nominated in two-step handover
    const ERR_NOT_PENDING_ADMIN: u64 = 2005;
    /// Zero address is prohibited for role assignment
    const ERR_ZERO_ADDRESS: u64 = 2006;
    /// Role registry already initialized under deployer account
    const ERR_ALREADY_INITIALIZED: u64 = 2007;

    // =========================================================================
    // Role Registry Resource
    // =========================================================================

    struct RoleRegistry has key {
        admin: address,
        pending_admin: address,
        guardians: Table<address, bool>,
        governance_executors: Table<address, bool>,
        oracle_feeders: Table<address, bool>,
        guardian_count: u64,
        feeder_count: u64
    }

    // =========================================================================
    // Initialization & Two-Step Admin Handover
    // =========================================================================

    public fun initialize(deployer: &signer) {
        let admin_addr = signer::address_of(deployer);
        assert!(!exists<RoleRegistry>(@equinox_clear), ERR_ALREADY_INITIALIZED);

        let guardians = table::new<address, bool>();
        table::add(&mut guardians, admin_addr, true);

        let governance_executors = table::new<address, bool>();
        table::add(&mut governance_executors, admin_addr, true);

        let oracle_feeders = table::new<address, bool>();
        table::add(&mut oracle_feeders, admin_addr, true);

        move_to(deployer, RoleRegistry {
            admin: admin_addr,
            pending_admin: @0x0,
            guardians,
            governance_executors,
            oracle_feeders,
            guardian_count: 1,
            feeder_count: 1
        });
    }

    /// Initiates a two-step admin transfer. Current admin retains authority until accepted.
    public fun propose_admin(caller: &signer, new_admin: address) acquires RoleRegistry {
        let reg = borrow_global_mut<RoleRegistry>(@equinox_clear);
        assert!(signer::address_of(caller) == reg.admin, ERR_NOT_ADMIN);
        assert!(new_admin != @0x0, ERR_ZERO_ADDRESS);
        reg.pending_admin = new_admin;
    }

    /// Completes the two-step admin transfer; must be signed by `pending_admin`.
    public fun accept_admin(caller: &signer) acquires RoleRegistry {
        let reg = borrow_global_mut<RoleRegistry>(@equinox_clear);
        let caller_addr = signer::address_of(caller);
        assert!(reg.pending_admin != @0x0 && caller_addr == reg.pending_admin, ERR_NOT_PENDING_ADMIN);
        reg.admin = caller_addr;
        reg.pending_admin = @0x0;
    }

    // =========================================================================
    // Role Management
    // =========================================================================

    public fun set_guardian(caller: &signer, account: address, enabled: bool) acquires RoleRegistry {
        let reg = borrow_global_mut<RoleRegistry>(@equinox_clear);
        assert!(signer::address_of(caller) == reg.admin, ERR_NOT_ADMIN);
        assert!(account != @0x0, ERR_ZERO_ADDRESS);

        let currently = is_table_true(&reg.guardians, account);
        if (enabled && !currently) {
            upsert_bool(&mut reg.guardians, account, true);
            reg.guardian_count = reg.guardian_count + 1;
        } else if (!enabled && currently) {
            upsert_bool(&mut reg.guardians, account, false);
            reg.guardian_count = reg.guardian_count - 1;
        };
    }

    public fun set_governance_executor(caller: &signer, account: address, enabled: bool) acquires RoleRegistry {
        let reg = borrow_global_mut<RoleRegistry>(@equinox_clear);
        assert!(signer::address_of(caller) == reg.admin, ERR_NOT_ADMIN);
        assert!(account != @0x0, ERR_ZERO_ADDRESS);
        upsert_bool(&mut reg.governance_executors, account, enabled);
    }

    public fun set_oracle_feeder(caller: &signer, account: address, enabled: bool) acquires RoleRegistry {
        let reg = borrow_global_mut<RoleRegistry>(@equinox_clear);
        assert!(signer::address_of(caller) == reg.admin, ERR_NOT_ADMIN);
        assert!(account != @0x0, ERR_ZERO_ADDRESS);

        let currently = is_table_true(&reg.oracle_feeders, account);
        if (enabled && !currently) {
            upsert_bool(&mut reg.oracle_feeders, account, true);
            reg.feeder_count = reg.feeder_count + 1;
        } else if (!enabled && currently) {
            upsert_bool(&mut reg.oracle_feeders, account, false);
            reg.feeder_count = reg.feeder_count - 1;
        };
    }

    // =========================================================================
    // Verification Guards & View Accessors
    // =========================================================================

    public fun assert_admin(addr: address) acquires RoleRegistry {
        let reg = borrow_global<RoleRegistry>(@equinox_clear);
        assert!(addr == reg.admin, ERR_NOT_ADMIN);
    }

    public fun assert_guardian_or_admin(addr: address) acquires RoleRegistry {
        let reg = borrow_global<RoleRegistry>(@equinox_clear);
        assert!(addr == reg.admin || is_table_true(&reg.guardians, addr), ERR_NOT_GUARDIAN);
    }

    public fun assert_governance_or_admin(addr: address) acquires RoleRegistry {
        let reg = borrow_global<RoleRegistry>(@equinox_clear);
        assert!(addr == reg.admin || is_table_true(&reg.governance_executors, addr), ERR_NOT_GOVERNANCE);
    }

    public fun assert_oracle_feeder(addr: address) acquires RoleRegistry {
        let reg = borrow_global<RoleRegistry>(@equinox_clear);
        assert!(addr == reg.admin || is_table_true(&reg.oracle_feeders, addr), ERR_NOT_ORACLE_FEEDER);
    }

    #[view]
    public fun admin(): address acquires RoleRegistry {
        borrow_global<RoleRegistry>(@equinox_clear).admin
    }

    #[view]
    public fun pending_admin(): address acquires RoleRegistry {
        borrow_global<RoleRegistry>(@equinox_clear).pending_admin
    }

    #[view]
    public fun is_guardian(addr: address): bool acquires RoleRegistry {
        let reg = borrow_global<RoleRegistry>(@equinox_clear);
        addr == reg.admin || is_table_true(&reg.guardians, addr)
    }

    #[view]
    public fun is_oracle_feeder(addr: address): bool acquires RoleRegistry {
        let reg = borrow_global<RoleRegistry>(@equinox_clear);
        addr == reg.admin || is_table_true(&reg.oracle_feeders, addr)
    }

    #[view]
    public fun guardian_count(): u64 acquires RoleRegistry {
        borrow_global<RoleRegistry>(@equinox_clear).guardian_count
    }

    #[view]
    public fun feeder_count(): u64 acquires RoleRegistry {
        borrow_global<RoleRegistry>(@equinox_clear).feeder_count
    }

    // =========================================================================
    // Internal Helpers
    // =========================================================================

    fun is_table_true(tbl: &Table<address, bool>, key: address): bool {
        if (!table::contains(tbl, key)) {
            false
        } else {
            *table::borrow(tbl, key)
        }
    }

    fun upsert_bool(tbl: &mut Table<address, bool>, key: address, val: bool) {
        if (table::contains(tbl, key)) {
            let r = table::borrow_mut(tbl, key);
            *r = val;
        } else {
            table::add(tbl, key, val);
        };
    }
}
