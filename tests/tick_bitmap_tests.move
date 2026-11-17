// Copyright (c) ZengLLQ
// SPDX-License-Identifier: MIT

#[test_only]
module equinox_clear::tick_bitmap_tests {
    use aptos_framework::account;
    use equinox_clear::tick_bitmap::{Self, TickBitmap};

    struct BitmapHolder has key {
        bm: TickBitmap
    }

    #[test]
    fun test_flip_and_cross_word_scan() {
        let holder = account::create_account_for_test(@0x71C);
        let bm = tick_bitmap::new();
        let t1 = tick_bitmap::encode_tick(300, true);   // 3796 (word 14)
        let t2 = tick_bitmap::encode_tick(100, false);  // 4196 (word 16)
        let t3 = tick_bitmap::encode_tick(500, false);  // 4596 (word 17)

        tick_bitmap::set_tick(&mut bm, t1);
        tick_bitmap::set_tick(&mut bm, t2);
        tick_bitmap::set_tick(&mut bm, t3);
        assert!(tick_bitmap::active_count(&bm) == 3, 1);

        // Search <= 4300 -> finds t2 (4196)
        let (found_tick, ok) = tick_bitmap::find_next_initialized_tick(&bm, 4300, true);
        assert!(ok && found_tick == t2, 2);

        // Search > 4196 -> finds t3 (4596)
        let (next_tick, ok2) = tick_bitmap::find_next_initialized_tick(&bm, t2, false);
        assert!(ok2 && next_tick == t3, 3);

        // Clear t2 and re-scan <= 4300 -> crosses empty word 15 to find t1 (3796)
        tick_bitmap::clear_tick(&mut bm, t2);
        assert!(tick_bitmap::active_count(&bm) == 2, 4);
        let (found_after, ok3) = tick_bitmap::find_next_initialized_tick(&bm, 4300, true);
        assert!(ok3 && found_after == t1, 5);

        move_to(&holder, BitmapHolder { bm });
    }

    #[test]
    fun test_price_tick_roundtrip() {
        let t_pos = tick_bitmap::encode_tick(250, false);
        let p_pos = tick_bitmap::tick_to_price_wad(t_pos);
        assert!(tick_bitmap::price_wad_to_tick(p_pos) == t_pos, 1);

        let t_neg = tick_bitmap::encode_tick(180, true);
        let p_neg = tick_bitmap::tick_to_price_wad(t_neg);
        assert!(tick_bitmap::price_wad_to_tick(p_neg) == t_neg, 2);
    }
}
