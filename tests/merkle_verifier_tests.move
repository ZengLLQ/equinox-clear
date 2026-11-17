// Copyright (c) ZengLLQ
// SPDX-License-Identifier: MIT

#[test_only]
module equinox_clear::merkle_verifier_tests {
    use std::vector;
    use equinox_clear::merkle_verifier;

    #[test]
    fun test_commitment_determinism_and_uniqueness() {
        let h1 = merkle_verifier::compute_intent_commitment(
            @0x111, 1, 2, 1000, 950, true, 50, 2000, b"salt-1"
        );
        let h2 = merkle_verifier::compute_intent_commitment(
            @0x111, 1, 2, 1000, 950, true, 50, 2000, b"salt-1"
        );
        let h3 = merkle_verifier::compute_intent_commitment(
            @0x111, 1, 2, 1000, 950, true, 50, 2000, b"salt-2"
        );
        assert!(vector::length(&h1) == 32, 1);
        assert!(h1 == h2, 2);
        assert!(h1 != h3, 3);
    }

    #[test]
    fun test_sorted_merkle_tree_proof_verification() {
        let l0 = merkle_verifier::hash_leaf(b"intent-0");
        let l1 = merkle_verifier::hash_leaf(b"intent-1");
        let l2 = merkle_verifier::hash_leaf(b"intent-2");
        let l3 = merkle_verifier::hash_leaf(b"intent-3");

        let root = merkle_verifier::compute_root_from_leaves(vector[l0, l1, l2, l3]);
        let h23 = merkle_verifier::hash_pair_sorted(&l2, &l3);

        // Proof for l0 is [l1, h23]
        let proof_0 = vector[l1, h23];
        assert!(merkle_verifier::verify_sorted_proof(&root, l0, &proof_0), 1);

        // Tampered leaf fails verification
        let bad_leaf = merkle_verifier::hash_leaf(b"tampered");
        assert!(!merkle_verifier::verify_sorted_proof(&root, bad_leaf, &proof_0), 2);
    }
}
