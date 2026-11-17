// Copyright (c) ZengLLQ
// SPDX-License-Identifier: MIT

/// # Cryptographic Intent Commitment & Merkle Inclusion Verifier
///
/// Provides domain-separated SHA3-256 primitives for:
/// 1. Sealing user trading intents during the commit phase (`compute_intent_commitment`),
///    preventing mempool sandwiching and solver censorship before batch reveal.
/// 2. Verifying canonical sorted-pair and indexed Merkle inclusion proofs for
///    off-chain batch settlement manifests and solver execution receipts.
module equinox_clear::merkle_verifier {
    use std::bcs;
    use std::hash;
    use std::vector;

    // =========================================================================
    // Error Constants
    // =========================================================================

    /// Hash output or root must be exactly 32 bytes
    const ERR_INVALID_HASH_LENGTH: u64 = 1301;
    /// Proof vector cannot exceed maximum tree depth or contain malformed nodes
    const ERR_INVALID_PROOF_NODE: u64 = 1302;
    /// Salt length must be non-empty for commitment entropy
    const ERR_EMPTY_SALT: u64 = 1303;

    // =========================================================================
    // Domain Separation Constants
    // =========================================================================

    const HASH_LEN: u64 = 32;
    const LEAF_PREFIX: u8 = 0x00;
    const NODE_PREFIX: u8 = 0x01;
    const INTENT_DOMAIN: vector<u8> = b"EQUINOX_INTENT_COMMIT_V1";
    const SOLVER_BID_DOMAIN: vector<u8> = b"EQUINOX_SOLVER_BID_V1";

    // =========================================================================
    // Intent & Solver Bid Commitments
    // =========================================================================

    /// Computes a deterministic 32-byte SHA3-256 commitment over all intent fields
    /// plus a trader-supplied random `salt`, preventing preimage collisions and
    /// mempool leakage prior to batch reveal.
    public fun compute_intent_commitment(
        trader: address,
        sell_asset: u64,
        buy_asset: u64,
        sell_amount: u128,
        min_buy_amount: u128,
        partial_fill_allowed: bool,
        max_fee_bps: u64,
        expiry_sec: u64,
        salt: vector<u8>
    ): vector<u8> {
        assert!(!vector::is_empty(&salt), ERR_EMPTY_SALT);

        let payload = INTENT_DOMAIN;
        vector::append(&mut payload, bcs::to_bytes(&trader));
        vector::append(&mut payload, bcs::to_bytes(&sell_asset));
        vector::append(&mut payload, bcs::to_bytes(&buy_asset));
        vector::append(&mut payload, bcs::to_bytes(&sell_amount));
        vector::append(&mut payload, bcs::to_bytes(&min_buy_amount));
        vector::append(&mut payload, bcs::to_bytes(&partial_fill_allowed));
        vector::append(&mut payload, bcs::to_bytes(&max_fee_bps));
        vector::append(&mut payload, bcs::to_bytes(&expiry_sec));
        vector::append(&mut payload, salt);

        hash::sha3_256(payload)
    }

    /// Computes a sealed solver bid commitment so competing solvers cannot copy
    /// each other's surplus scores before bid reveal.
    public fun compute_solver_bid_commitment(
        solver: address,
        batch_id: u64,
        proposed_surplus_usd: u128,
        expected_fill_count: u64,
        salt: vector<u8>
    ): vector<u8> {
        assert!(!vector::is_empty(&salt), ERR_EMPTY_SALT);

        let payload = SOLVER_BID_DOMAIN;
        vector::append(&mut payload, bcs::to_bytes(&solver));
        vector::append(&mut payload, bcs::to_bytes(&batch_id));
        vector::append(&mut payload, bcs::to_bytes(&proposed_surplus_usd));
        vector::append(&mut payload, bcs::to_bytes(&expected_fill_count));
        vector::append(&mut payload, salt);

        hash::sha3_256(payload)
    }

    // =========================================================================
    // Merkle Proof Construction & Verification
    // =========================================================================

    /// Domain-separated leaf hash `SHA3-256(0x00 || raw_leaf)`.
    public fun hash_leaf(raw_leaf: vector<u8>): vector<u8> {
        let buf = vector::singleton<u8>(LEAF_PREFIX);
        vector::append(&mut buf, raw_leaf);
        hash::sha3_256(buf)
    }

    /// Lexicographically compares two 32-byte digests; returns `true` if `a <= b`.
    public fun bytes32_lte(a: &vector<u8>, b: &vector<u8>): bool {
        assert!(vector::length(a) == HASH_LEN, ERR_INVALID_HASH_LENGTH);
        assert!(vector::length(b) == HASH_LEN, ERR_INVALID_HASH_LENGTH);
        let i = 0;
        while (i < HASH_LEN) {
            let ba = *vector::borrow(a, i);
            let bb = *vector::borrow(b, i);
            if (ba < bb) {
                return true
            } else if (ba > bb) {
                return false
            };
            i = i + 1;
        };
        true
    }

    /// Hashes two child nodes with `0x01` domain prefix in canonical sorted order.
    public fun hash_pair_sorted(a: &vector<u8>, b: &vector<u8>): vector<u8> {
        assert!(vector::length(a) == HASH_LEN, ERR_INVALID_HASH_LENGTH);
        assert!(vector::length(b) == HASH_LEN, ERR_INVALID_HASH_LENGTH);
        let buf = vector::singleton<u8>(NODE_PREFIX);
        if (bytes32_lte(a, b)) {
            vector::append(&mut buf, *a);
            vector::append(&mut buf, *b);
        } else {
            vector::append(&mut buf, *b);
            vector::append(&mut buf, *a);
        };
        hash::sha3_256(buf)
    }

    /// Verifies an order-independent sorted-pair Merkle inclusion proof.
    public fun verify_sorted_proof(
        root: &vector<u8>,
        leaf: vector<u8>,
        proof: &vector<vector<u8>>
    ): bool {
        if (vector::length(root) != HASH_LEN || vector::length(&leaf) != HASH_LEN) {
            return false
        };
        let computed = leaf;
        let len = vector::length(proof);
        let i = 0;
        while (i < len) {
            let sibling = vector::borrow(proof, i);
            assert!(vector::length(sibling) == HASH_LEN, ERR_INVALID_PROOF_NODE);
            computed = hash_pair_sorted(&computed, sibling);
            i = i + 1;
        };
        &computed == root
    }

    /// Computes a Merkle root from a non-empty list of 32-byte leaves by iterative pairwise folding.
    public fun compute_root_from_leaves(leaves: vector<vector<u8>>): vector<u8> {
        let count = vector::length(&leaves);
        assert!(count > 0, ERR_INVALID_PROOF_NODE);
        let level = leaves;
        while (vector::length(&level) > 1) {
            let next_level = vector::empty<vector<u8>>();
            let len = vector::length(&level);
            let i = 0;
            while (i < len) {
                let left = vector::borrow(&level, i);
                if (i + 1 < len) {
                    let right = vector::borrow(&level, i + 1);
                    vector::push_back(&mut next_level, hash_pair_sorted(left, right));
                } else {
                    // Duplicate odd node symmetrically
                    vector::push_back(&mut next_level, hash_pair_sorted(left, left));
                };
                i = i + 2;
            };
            level = next_level;
        };
        *vector::borrow(&level, 0)
    }
}
