// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// Stateful library that gates running-median updates by price movement.
//
// Rationale: without this gate, many swaps that barely move the price (or
// don't move it at all, e.g. tiny/dust trades) could each nudge the
// running median in the same direction. Requiring a minimum tick
// displacement means the median only reacts to swaps that actually pushed
// the pool to a new price level — not to repeated pokes at essentially
// the same price, which is exactly the kind of cheap, repeatable action
// an attacker would use to drag the median toward a favorable value.
//
// The required displacement is not a flat constant — it is scaled by the
// pool's current liquidity depth in requiredMovement, because the same
// tick move means very different things in a deep pool vs. a shallow one.
library TickCheckerLibrary {
    // Baseline number of ticks a pool must move (in either direction, vs.
    // the tick recorded at the last accepted median update) before a new
    // swap's priority fee is allowed to update the running median again.
    // This is the value used when the pool's liquidity sits exactly at
    // REFERENCE_LIQUIDITY; see requiredMovement for how it's scaled
    // up/down for other liquidity levels.
    int24 internal constant BASE_TICK_THRESHOLD = 10;

    // Liquidity level BASE_TICK_THRESHOLD is calibrated against. Pools
    // deeper than this need a SMALLER tick move to trigger an update
    // (moving the tick there took a large, expensive trade, so it's
    // already a meaningful signal). Pools shallower than this need a
    // LARGER tick move (a tiny trade can swing a thin pool's tick a lot,
    // so that movement alone proves little and is cheap to manufacture).
    // Tune per deployment / per fee tier.
    uint128 internal constant REFERENCE_LIQUIDITY = 1e21;

    // Hard floor/ceiling on the computed threshold. Without these, a
    // near-zero-liquidity pool could push the requirement to an absurdly
    // large value (median effectively frozen forever), and an extremely
    // deep pool could push it to 0 (median updates on every single swap,
    // defeating the whole point of gating it).
    int24 internal constant MIN_TICK_THRESHOLD = 1;
    int24 internal constant MAX_TICK_THRESHOLD = 200;

    struct State {
        mapping(PoolId => int24) lastMedianUpdateTick; // tick recorded at the last accepted update, per pool
        mapping(PoolId => bool) tickBaselineSet; // whether lastMedianUpdateTick has been initialized, per pool
    }

    // Decides whether the pool identified by `id` has moved far enough in
    // tick terms, since the last time it was allowed to update the
    // median, to trust this swap's priority fee again. This runs against
    // the POST-swap tick (afterSwap fires once the swap's effect on the
    // pool's price has already been applied).
    function movedEnoughToUpdate(State storage self, PoolId id, int24 currentTick, uint128 liquidity)
        internal
        returns (bool)
    {
        if (!self.tickBaselineSet[id]) {
            // First observation for this pool: nothing to compare against
            // yet, so accept this swap and establish the baseline for
            // future comparisons.
            self.lastMedianUpdateTick[id] = currentTick;
            self.tickBaselineSet[id] = true;
            return true;
        }

        int24 tickDelta = currentTick - self.lastMedianUpdateTick[id];
        if (tickDelta < 0) tickDelta = -tickDelta;

        int24 requiredMove = requiredMovement(liquidity);

        if (tickDelta < requiredMove) {
            return false;
        }

        self.lastMedianUpdateTick[id] = currentTick;
        return true;
    }

    // Computes how many ticks a pool must move before a swap's priority
    // fee is trusted enough to update the median, given the pool's
    // current liquidity:
    //
    //   requiredMove = BASE_TICK_THRESHOLD * sqrt(REFERENCE_LIQUIDITY / liquidity)
    //
    // sqrt-scaling (rather than a flat 1/liquidity scaling) keeps the
    // threshold from exploding or collapsing too aggressively across the
    // wide range of liquidity real pools have; it mirrors how price
    // impact for a fixed trade size scales roughly with 1/sqrt(liquidity)
    // in a constant-product-style AMM, so the required tick move tracks
    // "how hard was this to fake" instead of an arbitrary fixed number of
    // ticks.
    //
    // Result is clamped to [MIN_TICK_THRESHOLD, MAX_TICK_THRESHOLD].
    function requiredMovement(uint128 liquidity) internal pure returns (int24) {
        if (liquidity == 0) return MAX_TICK_THRESHOLD;

        uint256 sqrtLiquidity = Math.sqrt(uint256(liquidity));
        uint256 sqrtReference = Math.sqrt(uint256(REFERENCE_LIQUIDITY));

        uint256 scaled = (uint256(uint24(BASE_TICK_THRESHOLD)) * sqrtReference) / sqrtLiquidity;

        if (scaled < uint256(uint24(MIN_TICK_THRESHOLD))) return MIN_TICK_THRESHOLD;
        if (scaled > uint256(uint24(MAX_TICK_THRESHOLD))) return MAX_TICK_THRESHOLD;
        return int24(int256(scaled));
    }
}
