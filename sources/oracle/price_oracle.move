// Copyright (c) ZengLLQ
// SPDX-License-Identifier: MIT

/// # Multi-Source Medianized Price Oracle & TWAP Circuit Guard
///
/// Aggregates price reports from independent authorized feeders for each market
/// pair (`pair_id`), computing:
/// - **Outlier-Resistant Median**: Exact sorted median across active publishers,
///   ignoring stale quotes (`now - reported_at > max_staleness_sec`).
/// - **Confidence Interval Check**: Rejects feeds whose spread `(max - min) / median`
///   exceeds `max_confidence_bps`.
/// - **Circular-Buffer TWAP**: Time-weighted average over a ring buffer of `16`
///   recent median checkpoints.
/// - **Uniform Clearing Price (UCP) Guard**: Validates solver batch clearing prices
///   against both live median and TWAP reference within `max_deviation_bps`.
module equinox_clear::price_oracle {
    use std::signer;
    use std::vector;
    use aptos_std::table::{Self, Table};
    use equinox_clear::capabilities;
    use equinox_clear::events;
    use equinox_clear::fixed_point;

    // =========================================================================
    // Error Constants
    // =========================================================================

    /// Pair ID is not registered in the oracle
    const ERR_PAIR_NOT_REGISTERED: u64 = 3001;
    /// Pair ID already exists
    const ERR_PAIR_ALREADY_EXISTS: u64 = 3002;
    /// Supplied price must be strictly positive
    const ERR_ZERO_PRICE: u64 = 3003;
    /// Fewer than `min_quorum` fresh publisher reports available
    const ERR_INSUFFICIENT_QUORUM: u64 = 3004;
    /// Cross-publisher confidence spread exceeded max_confidence_bps
    const ERR_CONFIDENCE_TOO_WIDE: u64 = 3005;
    /// Oracle price is stale relative to current timestamp
    const ERR_STALE_ORACLE_PRICE: u64 = 3006;
    /// Proposed clearing price deviated beyond allowed oracle band
    const ERR_CLEARING_PRICE_OUT_OF_BAND: u64 = 3007;
    /// Oracle registry already initialized
    const ERR_ALREADY_INITIALIZED: u64 = 3008;

    const TWAP_BUFFER_CAP: u64 = 16;

    // =========================================================================
    // Types
    // =========================================================================

    struct PublisherQuote has copy, drop, store {
        publisher: address,
        price_wad: u128,
        timestamp_sec: u64
    }

    struct TwapSample has copy, drop, store {
        price_wad: u128,
        timestamp_sec: u64
    }

    struct PairFeed has store {
        pair_id: u64,
        base_asset: u64,
        quote_asset: u64,
        min_quorum: u64,
        max_staleness_sec: u64,
        max_confidence_bps: u64,
        quotes: vector<PublisherQuote>,
        twap_ring: vector<TwapSample>,
        twap_head: u64,
        last_median_wad: u128,
        last_twap_wad: u128,
        last_confidence_bps: u64,
        last_updated_sec: u64
    }

    struct OracleRegistry has key {
        feeds: Table<u64, PairFeed>,
        pair_count: u64
    }

    // =========================================================================
    // Initialization & Pair Registration
    // =========================================================================

    public fun initialize(deployer: &signer) {
        assert!(!exists<OracleRegistry>(@equinox_clear), ERR_ALREADY_INITIALIZED);
        move_to(deployer, OracleRegistry {
            feeds: table::new<u64, PairFeed>(),
            pair_count: 0
        });
    }

    public fun register_pair(
        caller: &signer,
        pair_id: u64,
        base_asset: u64,
        quote_asset: u64,
        min_quorum: u64,
        max_staleness_sec: u64,
        max_confidence_bps: u64
    ) acquires OracleRegistry {
        capabilities::assert_admin(signer::address_of(caller));
        let reg = borrow_global_mut<OracleRegistry>(@equinox_clear);
        assert!(!table::contains(&reg.feeds, pair_id), ERR_PAIR_ALREADY_EXISTS);
        assert!(min_quorum > 0 && max_staleness_sec > 0, ERR_INSUFFICIENT_QUORUM);

        table::add(&mut reg.feeds, pair_id, PairFeed {
            pair_id,
            base_asset,
            quote_asset,
            min_quorum,
            max_staleness_sec,
            max_confidence_bps,
            quotes: vector::empty<PublisherQuote>(),
            twap_ring: vector::empty<TwapSample>(),
            twap_head: 0,
            last_median_wad: 0,
            last_twap_wad: 0,
            last_confidence_bps: 0,
            last_updated_sec: 0
        });
        reg.pair_count = reg.pair_count + 1;
    }

    // =========================================================================
    // Quote Submission & Median / TWAP Aggregation
    // =========================================================================

    /// Submits a publisher quote and recomputes median, confidence spread, and TWAP
    /// if quorum of fresh feeds is met.
    public fun submit_quote(
        feeder: &signer,
        pair_id: u64,
        price_wad: u128,
        now_sec: u64
    ) acquires OracleRegistry {
        let feeder_addr = signer::address_of(feeder);
        capabilities::assert_oracle_feeder(feeder_addr);
        assert!(price_wad > 0, ERR_ZERO_PRICE);

        let reg = borrow_global_mut<OracleRegistry>(@equinox_clear);
        assert!(table::contains(&reg.feeds, pair_id), ERR_PAIR_NOT_REGISTERED);
        let feed = table::borrow_mut(&mut reg.feeds, pair_id);

        upsert_quote(&mut feed.quotes, feeder_addr, price_wad, now_sec);

        // Collect fresh prices within staleness threshold
        let fresh_prices = vector::empty<u128>();
        let len = vector::length(&feed.quotes);
        let i = 0;
        while (i < len) {
            let q = vector::borrow(&feed.quotes, i);
            if (now_sec >= q.timestamp_sec && (now_sec - q.timestamp_sec) <= feed.max_staleness_sec) {
                vector::push_back(&mut fresh_prices, q.price_wad);
            };
            i = i + 1;
        };

        let fresh_count = vector::length(&fresh_prices);
        if (fresh_count >= feed.min_quorum) {
            sort_u128(&mut fresh_prices);
            let min_p = *vector::borrow(&fresh_prices, 0);
            let max_p = *vector::borrow(&fresh_prices, fresh_count - 1);
            let median_p = compute_sorted_median(&fresh_prices);
            let conf_bps = fixed_point::deviation_bps(max_p, min_p, median_p);

            feed.last_median_wad = median_p;
            feed.last_confidence_bps = conf_bps;
            feed.last_updated_sec = now_sec;

            push_twap_sample(feed, median_p, now_sec);
            feed.last_twap_wad = compute_twap(feed);

            events::emit_oracle_price_updated(
                pair_id,
                median_p,
                feed.last_twap_wad,
                conf_bps,
                now_sec
            );
        };
    }

    // =========================================================================
    // Validation & Clearinghouse Guards
    // =========================================================================

    /// Returns `(median_price_wad, twap_price_wad)` after asserting freshness,
    /// quorum availability, and tight publisher confidence spread.
    public fun get_validated_prices(pair_id: u64, now_sec: u64): (u128, u128) acquires OracleRegistry {
        let reg = borrow_global<OracleRegistry>(@equinox_clear);
        assert!(table::contains(&reg.feeds, pair_id), ERR_PAIR_NOT_REGISTERED);
        let feed = table::borrow(&reg.feeds, pair_id);

        assert!(feed.last_median_wad > 0, ERR_INSUFFICIENT_QUORUM);
        assert!(
            now_sec >= feed.last_updated_sec && (now_sec - feed.last_updated_sec) <= feed.max_staleness_sec,
            ERR_STALE_ORACLE_PRICE
        );
        assert!(feed.last_confidence_bps <= feed.max_confidence_bps, ERR_CONFIDENCE_TOO_WIDE);

        (feed.last_median_wad, feed.last_twap_wad)
    }

    /// Asserts that a proposed Uniform Clearing Price (`ucp_wad`) lies within
    /// `max_deviation_bps` of both live median and circular-buffer TWAP.
    public fun assert_clearing_price_within_band(
        pair_id: u64,
        ucp_wad: u128,
        max_deviation_bps: u64,
        now_sec: u64
    ) acquires OracleRegistry {
        assert!(ucp_wad > 0, ERR_ZERO_PRICE);
        let (median_p, twap_p) = get_validated_prices(pair_id, now_sec);

        let dev_median = fixed_point::deviation_bps(ucp_wad, median_p, median_p);
        let dev_twap = fixed_point::deviation_bps(ucp_wad, twap_p, twap_p);
        assert!(dev_median <= max_deviation_bps && dev_twap <= max_deviation_bps, ERR_CLEARING_PRICE_OUT_OF_BAND);
    }

    /// Checks clearing price without aborting so the clearinghouse can trip a
    /// circuit breaker or slash a malicious solver cleanly.
    public fun is_clearing_price_valid(
        pair_id: u64,
        ucp_wad: u128,
        max_deviation_bps: u64,
        now_sec: u64
    ): bool acquires OracleRegistry {
        if (ucp_wad == 0) {
            return false
        };
        let reg = borrow_global<OracleRegistry>(@equinox_clear);
        if (!table::contains(&reg.feeds, pair_id)) {
            return false
        };
        let feed = table::borrow(&reg.feeds, pair_id);
        if (feed.last_median_wad == 0 || feed.last_confidence_bps > feed.max_confidence_bps) {
            return false
        };
        if (now_sec < feed.last_updated_sec || (now_sec - feed.last_updated_sec) > feed.max_staleness_sec) {
            return false
        };
        let dev_median = fixed_point::deviation_bps(ucp_wad, feed.last_median_wad, feed.last_median_wad);
        let dev_twap = fixed_point::deviation_bps(ucp_wad, feed.last_twap_wad, feed.last_twap_wad);
        dev_median <= max_deviation_bps && dev_twap <= max_deviation_bps
    }

    #[view]
    public fun peek_pair(pair_id: u64): (u128, u128, u64, u64) acquires OracleRegistry {
        let reg = borrow_global<OracleRegistry>(@equinox_clear);
        assert!(table::contains(&reg.feeds, pair_id), ERR_PAIR_NOT_REGISTERED);
        let feed = table::borrow(&reg.feeds, pair_id);
        (feed.last_median_wad, feed.last_twap_wad, feed.last_confidence_bps, feed.last_updated_sec)
    }

    // =========================================================================
    // Internal Sorting, Median & Circular TWAP Helpers
    // =========================================================================

    fun upsert_quote(
        quotes: &mut vector<PublisherQuote>,
        publisher: address,
        price_wad: u128,
        timestamp_sec: u64
    ) {
        let len = vector::length(quotes);
        let i = 0;
        while (i < len) {
            let q = vector::borrow_mut(quotes, i);
            if (q.publisher == publisher) {
                q.price_wad = price_wad;
                q.timestamp_sec = timestamp_sec;
                return
            };
            i = i + 1;
        };
        vector::push_back(quotes, PublisherQuote { publisher, price_wad, timestamp_sec });
    }

    fun sort_u128(arr: &mut vector<u128>) {
        let len = vector::length(arr);
        if (len <= 1) {
            return
        };
        let i = 1;
        while (i < len) {
            let key = *vector::borrow(arr, i);
            let j = i;
            while (j > 0 && *vector::borrow(arr, j - 1) > key) {
                let prev = *vector::borrow(arr, j - 1);
                *vector::borrow_mut(arr, j) = prev;
                j = j - 1;
            };
            *vector::borrow_mut(arr, j) = key;
            i = i + 1;
        };
    }

    fun compute_sorted_median(sorted: &vector<u128>): u128 {
        let len = vector::length(sorted);
        if (len % 2 == 1) {
            *vector::borrow(sorted, len / 2)
        } else {
            let a = *vector::borrow(sorted, (len / 2) - 1);
            let b = *vector::borrow(sorted, len / 2);
            (a / 2) + (b / 2) + ((a % 2 + b % 2) / 2)
        }
    }

    fun push_twap_sample(feed: &mut PairFeed, price_wad: u128, timestamp_sec: u64) {
        let sample = TwapSample { price_wad, timestamp_sec };
        let len = vector::length(&feed.twap_ring);
        if (len < TWAP_BUFFER_CAP) {
            vector::push_back(&mut feed.twap_ring, sample);
        } else {
            let slot = vector::borrow_mut(&mut feed.twap_ring, feed.twap_head);
            *slot = sample;
            feed.twap_head = (feed.twap_head + 1) % TWAP_BUFFER_CAP;
        };
    }

    fun compute_twap(feed: &PairFeed): u128 {
        let len = vector::length(&feed.twap_ring);
        if (len == 0) {
            return 0
        };
        if (len == 1) {
            return vector::borrow(&feed.twap_ring, 0).price_wad
        };

        let acc: u256 = 0;
        let i = 0;
        while (i < len) {
            acc = acc + (vector::borrow(&feed.twap_ring, i).price_wad as u256);
            i = i + 1;
        };
        ((acc / (len as u256)) as u128)
    }
}
