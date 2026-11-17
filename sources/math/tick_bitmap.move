// Copyright (c) ZengLLQ
// SPDX-License-Identifier: MIT

/// # Hierarchical 256-Bit Sparse Tick Bitmap & Log-Price Index
///
/// Maps discrete signed price ticks `[-4096, +4096]` onto `u256` words stored
/// in a sparse `Table<u64, u256>`, enabling $O(1)$ bit-scan discovery of the
/// nearest active limit order bucket or concentrated liquidity tick boundary.
///
/// Each tick spacing corresponds to a multiplicative 10 bps ($0.1\%$) step:
/// $$P(\text{tick}) = \text{WAD} \cdot (1.001)^{\text{tick}}$$
module equinox_clear::tick_bitmap {
    use aptos_std::table::{Self, Table};
    use equinox_clear::fixed_point;

    // =========================================================================
    // Error Constants
    // =========================================================================

    /// Tick index lies outside allowable signed domain [-4096, 4096]
    const ERR_TICK_OUT_OF_RANGE: u64 = 1201;
    /// Price is zero or out of representable tick bounds
    const ERR_INVALID_PRICE: u64 = 1202;

    // =========================================================================
    // Tick Constants
    // =========================================================================

    /// Offset applied to convert signed tick [-4096, 4096] into unsigned [0, 8192]
    const TICK_OFFSET: u64 = 4096;
    const MIN_SHIFTED_TICK: u64 = 0;
    const MAX_SHIFTED_TICK: u64 = 8192;
    /// 1.001 in WAD (10 bps multiplicative tick step)
    const TICK_BASE_WAD: u128 = 1_001_000_000_000_000_000;
    const MAX_U256: u256 = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

    // =========================================================================
    // Types
    // =========================================================================

    struct TickBitmap has store {
        words: Table<u64, u256>,
        active_count: u64
    }

    // =========================================================================
    // Lifecycle & Mutations
    // =========================================================================

    public fun new(): TickBitmap {
        TickBitmap {
            words: table::new<u64, u256>(),
            active_count: 0
        }
    }

    /// Converts signed tick `(mag, is_neg)` to shifted unsigned index `[0, 8192]`.
    public fun encode_tick(mag: u64, is_neg: bool): u64 {
        assert!(mag <= TICK_OFFSET, ERR_TICK_OUT_OF_RANGE);
        if (is_neg) {
            TICK_OFFSET - mag
        } else {
            TICK_OFFSET + mag
        }
    }

    /// Decodes shifted unsigned index back to `(mag, is_neg)`.
    public fun decode_tick(shifted: u64): (u64, bool) {
        assert!(shifted <= MAX_SHIFTED_TICK, ERR_TICK_OUT_OF_RANGE);
        if (shifted < TICK_OFFSET) {
            (TICK_OFFSET - shifted, true)
        } else {
            (shifted - TICK_OFFSET, false)
        }
    }

    /// Flips the initialization bit for `shifted_tick`.
    public fun flip_tick(self: &mut TickBitmap, shifted_tick: u64) {
        assert!(shifted_tick <= MAX_SHIFTED_TICK, ERR_TICK_OUT_OF_RANGE);
        let word_pos = shifted_tick >> 8;
        let bit_pos = ((shifted_tick & 255) as u8);
        let mask = (1u256 << bit_pos);

        if (!table::contains(&self.words, word_pos)) {
            table::add(&mut self.words, word_pos, mask);
            self.active_count = self.active_count + 1;
        } else {
            let word_ref = table::borrow_mut(&mut self.words, word_pos);
            let was_set = (*word_ref & mask) != 0;
            *word_ref = *word_ref ^ mask;
            if (was_set) {
                self.active_count = self.active_count - 1;
            } else {
                self.active_count = self.active_count + 1;
            };
        };
    }

    /// Sets the initialization bit for `shifted_tick` idempotently.
    public fun set_tick(self: &mut TickBitmap, shifted_tick: u64) {
        if (!is_initialized(self, shifted_tick)) {
            flip_tick(self, shifted_tick);
        };
    }

    /// Clears the initialization bit for `shifted_tick` idempotently.
    public fun clear_tick(self: &mut TickBitmap, shifted_tick: u64) {
        if (is_initialized(self, shifted_tick)) {
            flip_tick(self, shifted_tick);
        };
    }

    public fun is_initialized(self: &TickBitmap, shifted_tick: u64): bool {
        assert!(shifted_tick <= MAX_SHIFTED_TICK, ERR_TICK_OUT_OF_RANGE);
        let word_pos = shifted_tick >> 8;
        if (!table::contains(&self.words, word_pos)) {
            return false
        };
        let bit_pos = ((shifted_tick & 255) as u8);
        let word = *table::borrow(&self.words, word_pos);
        (word & (1u256 << bit_pos)) != 0
    }

    public fun active_count(self: &TickBitmap): u64 {
        self.active_count
    }

    // =========================================================================
    // O(1) Bit-Scan Traversal
    // =========================================================================

    /// Searches within the current 256-bit word for the next initialized tick
    /// `<= shifted_tick` (when `lte == true`) or `> shifted_tick` (when `lte == false`).
    /// Returns `(next_shifted_tick, found)`.
    public fun next_initialized_tick_within_word(
        self: &TickBitmap,
        shifted_tick: u64,
        lte: bool
    ): (u64, bool) {
        assert!(shifted_tick <= MAX_SHIFTED_TICK, ERR_TICK_OUT_OF_RANGE);
        let word_pos = shifted_tick >> 8;
        let bit_pos = ((shifted_tick & 255) as u8);

        if (!table::contains(&self.words, word_pos)) {
            let boundary = if (lte) { word_pos << 8 } else { ((word_pos << 8) + 255) };
            return (min_u64_cap(boundary), false)
        };

        let word = *table::borrow(&self.words, word_pos);
        if (lte) {
            // Mask all bits <= bit_pos
            let low_mask = if (bit_pos == 255) {
                MAX_U256
            } else {
                (1u256 << (bit_pos + 1)) - 1
            };
            let masked = word & low_mask;
            if (masked != 0) {
                let msb = most_significant_bit(masked);
                let next_tick = (word_pos << 8) + (msb as u64);
                (next_tick, true)
            } else {
                ((word_pos << 8), false)
            }
        } else {
            // Mask all bits > bit_pos
            if (bit_pos == 255) {
                return (min_u64_cap((word_pos << 8) + 255), false)
            };
            let next_bit = bit_pos + 1;
            let high_mask = MAX_U256 ^ ((1u256 << next_bit) - 1);
            let masked = word & high_mask;
            if (masked != 0) {
                let lsb = least_significant_bit(masked);
                let next_tick = (word_pos << 8) + (lsb as u64);
                (min_u64_cap(next_tick), next_tick <= MAX_SHIFTED_TICK)
            } else {
                (min_u64_cap((word_pos << 8) + 255), false)
            }
        }
    }

    /// Scans across words up to the domain boundary to find the nearest initialized tick.
    public fun find_next_initialized_tick(
        self: &TickBitmap,
        start_shifted_tick: u64,
        lte: bool
    ): (u64, bool) {
        assert!(start_shifted_tick <= MAX_SHIFTED_TICK, ERR_TICK_OUT_OF_RANGE);
        let cur = start_shifted_tick;
        loop {
            let (next_tick, found) = next_initialized_tick_within_word(self, cur, lte);
            if (found) {
                return (next_tick, true)
            };
            if (lte) {
                if (next_tick == 0) {
                    return (0, false)
                };
                cur = next_tick - 1;
            } else {
                if (next_tick >= MAX_SHIFTED_TICK) {
                    return (MAX_SHIFTED_TICK, false)
                };
                cur = next_tick + 1;
            };
        }
    }

    // =========================================================================
    // Price <-> Tick Conversion
    // =========================================================================

    /// Evaluates $P(\text{shifted\_tick}) = \text{WAD} \cdot (1.001)^{\text{tick}}$ in WAD precision.
    public fun tick_to_price_wad(shifted_tick: u64): u128 {
        let (mag, is_neg) = decode_tick(shifted_tick);
        let factor = fixed_point::pow_wad(TICK_BASE_WAD, mag);
        if (is_neg) {
            fixed_point::div_wad_down(fixed_point::wad(), factor)
        } else {
            factor
        }
    }

    /// Maps an arbitrary WAD price to the closest floor shifted tick using binary search.
    public fun price_wad_to_tick(price_wad: u128): u64 {
        assert!(price_wad > 0, ERR_INVALID_PRICE);
        let lo = MIN_SHIFTED_TICK;
        let hi = MAX_SHIFTED_TICK;

        if (price_wad <= tick_to_price_wad(lo)) {
            return lo
        };
        if (price_wad >= tick_to_price_wad(hi)) {
            return hi
        };

        while (lo < hi) {
            let mid = (lo + hi + 1) / 2;
            let p_mid = tick_to_price_wad(mid);
            if (p_mid <= price_wad) {
                lo = mid;
            } else {
                hi = mid - 1;
            };
        };
        lo
    }

    // =========================================================================
    // Internal Binary Bit-Scan Helpers
    // =========================================================================

    fun min_u64_cap(x: u64): u64 {
        if (x > MAX_SHIFTED_TICK) MAX_SHIFTED_TICK else x
    }

    fun most_significant_bit(x: u256): u8 {
        let r: u8 = 0;
        let v = x;
        if (v >= (1u256 << 128)) { v = v >> 128; r = r + 128; };
        if (v >= (1u256 << 64)) { v = v >> 64; r = r + 64; };
        if (v >= (1u256 << 32)) { v = v >> 32; r = r + 32; };
        if (v >= (1u256 << 16)) { v = v >> 16; r = r + 16; };
        if (v >= (1u256 << 8)) { v = v >> 8; r = r + 8; };
        if (v >= (1u256 << 4)) { v = v >> 4; r = r + 4; };
        if (v >= (1u256 << 2)) { v = v >> 2; r = r + 2; };
        if (v >= (1u256 << 1)) { r = r + 1; };
        r
    }

    fun least_significant_bit(x: u256): u8 {
        let r: u8 = 255;
        let v = x;
        if ((v & 0xffffffffffffffffffffffffffffffff) > 0) {
            r = r - 128;
        } else {
            v = v >> 128;
        };
        if ((v & 0xffffffffffffffff) > 0) {
            r = r - 64;
        } else {
            v = v >> 64;
        };
        if ((v & 0xffffffff) > 0) {
            r = r - 32;
        } else {
            v = v >> 32;
        };
        if ((v & 0xffff) > 0) {
            r = r - 16;
        } else {
            v = v >> 16;
        };
        if ((v & 0xff) > 0) {
            r = r - 8;
        } else {
            v = v >> 8;
        };
        if ((v & 0xf) > 0) {
            r = r - 4;
        } else {
            v = v >> 4;
        };
        if ((v & 0x3) > 0) {
            r = r - 2;
        } else {
            v = v >> 2;
        };
        if ((v & 0x1) > 0) {
            r = r - 1;
        };
        r
    }
}
