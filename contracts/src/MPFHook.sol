// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// -----------------------------------------------
//  IMPORTS
// -----------------------------------------------

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FrugalMedianLibrary} from "./lib/FrugalMedianLibrary.sol";
import {PenaltyFeeLibrary} from "./lib/PenaltyFeeLibrary.sol";
import {GetPriorityFeeLibrary} from "./lib/GetPriorityFeeLibrary.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

// -----------------------------------------------
//  CONTRACT
// -----------------------------------------------

// Uniswap v4 hook that tracks a running (approximate) median of the priority
// fee paid by swappers and penalizes swaps whose priority fee is
// significantly above that median. The idea is to discourage aggressive
// priority-fee bidding (e.g. sandwich/MEV-style behavior) by making
// "overpaying" swaps pay a higher dynamic LP fee.
//
// To resist single-block / short-burst manipulation of the running median
// (an attacker flooding many swaps into one or a few blocks to yank the
// median toward a value that benefits them), the fee decision is NOT based
// on the live, per-swap-updated median directly. Instead, the live median
// is snapshotted once per block into a rolling window (SNAPSHOT_WINDOW
// blocks), and the fee is computed against the AVERAGE of that window.
// This mirrors the design of Uniswap's own Truncated Oracle hook
// (https://blog.uniswap.org/uniswap-v4-truncated-oracle-hook), which
// smooths its recorded tick over ~15 blocks so that manipulating it
// requires sustaining the attack over multiple blocks, not just one.
// The live median itself no longer updates on every swap unconditionally.
// It is additionally gated by a tick checker (see _tickMovedEnoughToUpdate
// / _requiredTickMovement in _afterSwap): a swap only feeds its priority
// fee into the median if the pool's tick has moved far enough, since the
// last accepted update, relative to a threshold that scales with the
// pool's current liquidity depth. This stops a burst of same-price
// (or dust) swaps from repeatedly nudging the median with no real price
// movement behind it, on top of the existing per-block snapshot smoothing
// used for the fee decision itself.
contract MedianPriorityFeeHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;

    // -----------------------------------------------
    // ERRORS
    // -----------------------------------------------

    // Thrown in _afterInitialize when a pool is created without the
    // dynamic-fee flag set. Without dynamic fees enabled, this hook's
    // whole fee-adjustment logic would have no effect on the pool, so we
    // reject such pools outright instead of silently doing nothing.
    error NotDynamicFee();

    // -----------------------------------------------
    // EVENTS
    // -----------------------------------------------

    // (none yet)

    // How many past blocks' median snapshots are averaged together to
    // form the reference value that penalties are computed against.
    // 15 blocks was chosen to mirror Uniswap's Truncated Oracle hook
    // (~15 blocks / ~3 minutes on L1), long enough that sustaining a
    // manipulation of the reference is costly (arbitrage / competing
    // flow works against the attacker the whole time), short enough
    // that the reference still tracks genuine shifts in network fee
    // conditions at a reasonable pace.
    uint256 public constant SNAPSHOT_WINDOW = 15;

    // --- Tick checker (gates median updates by price movement) ---

    // Baseline number of ticks a pool must move (in either direction,
    // vs. the tick recorded at the last accepted median update) before
    // a new swap's priority fee is allowed to update the running
    // median again. This is the value used when the pool's liquidity
    // sits exactly at REFERENCE_LIQUIDITY; see _requiredTickMovement
    // for how it's scaled up/down for other liquidity levels.
    int24 public constant BASE_TICK_THRESHOLD = 10;

    // Liquidity level BASE_TICK_THRESHOLD is calibrated against.
    // Pools deeper than this need a SMALLER tick move to trigger an
    // update (moving the tick there took a large, expensive trade, so
    // it's already a meaningful signal). Pools shallower than this
    // need a LARGER tick move (a tiny trade can swing a thin pool's
    // tick a lot, so that movement alone proves little and is cheap
    // to manufacture). Tune per deployment / per fee tier.
    uint128 public constant REFERENCE_LIQUIDITY = 1e21;

    // Hard floor/ceiling on the computed threshold. Without these, a
    // near-zero-liquidity pool could push the requirement to an
    // absurdly large value (median effectively frozen forever), and
    // an extremely deep pool could push it to 0 (median updates on
    // every single swap, defeating the whole point of gating it).
    int24 public constant MIN_TICK_THRESHOLD = 1;
    int24 public constant MAX_TICK_THRESHOLD = 200;

    // -----------------------------------------------
    // STORAGE VARIABLES
    // -----------------------------------------------

    // Running state for the approximate-median estimator (see
    // FrugalMedianLibrary). NOTE: this state is shared across all pools
    // that use this hook instance — there is a single global median, not
    // one per pool. This value updates on EVERY swap in a registered
    // pool (see updateMedian_) — it is not itself rate-limited by block.
    struct MedianState {
        int256 approxMedian; // current estimate of the median priority fee
        int256 step; // current step size used by the frugal-median update rule
        bool positive; // direction of the last adjustment (increase vs decrease)
    }

    MedianState public medianState;

    // Rolling window of per-block snapshots of medianState.approxMedian.
    // One snapshot is recorded per block (on the first swap that touches
    // a registered pool in that block); the average of this window is
    // what getDynamicFee_ actually compares priority fees against.
    int256[SNAPSHOT_WINDOW] public blockMedianSnapshots;

    // How many slots of blockMedianSnapshots are populated so far.
    // Saturates at SNAPSHOT_WINDOW once the window has filled up.
    uint256 public snapshotCount;

    // Next write position in the circular blockMedianSnapshots buffer.
    uint256 public snapshotIndex;

    // Block number of the last recorded snapshot, used to detect when a
    // new block has started and a fresh snapshot is due.
    uint256 public lastSnapshotBlock;

    // Bool creates a whitelist for pools.
    // It is needed to update Median only with those pools where
    // we can definitely know the exact swap amount in USD.
    // It is needed to get rid of dust swaps aimed at
    // destroying the Median value.
    mapping(PoolId => bool) public isRegisteredPool;

    // Mapping of nice and sound token addresses.
    // Only initialized in the constructor.
    // Chain-specific.
    mapping(address => bool) public isListed;

    // Tick recorded at the moment of the last swap that was actually
    // allowed to update the median for a given pool. Every later swap
    // compares the pool's current tick against this value to decide
    // whether enough price movement has occurred (see
    // _tickMovedEnoughToUpdate).
    mapping(PoolId => int24) public lastMedianUpdateTick;

    // Whether lastMedianUpdateTick has been initialized for a given
    // pool. Needed as an explicit sentinel because tick 0 is itself a
    // perfectly valid tick and can't double as "not set yet".
    mapping(PoolId => bool) public tickBaselineSet;

    // -----------------------------------------------
    // CONSTRUCTOR
    // -----------------------------------------------

    constructor(IPoolManager _poolManager, address[] memory _listedTokens) BaseHook(_poolManager) {
        for (uint256 i = 0; i < _listedTokens.length; i++) {
            isListed[_listedTokens[i]] = true;
        }
    }

    // -----------------------------------------------
    // EXTERNAL / PUBLIC FUNCTIONS
    // -----------------------------------------------

    // Declares which Uniswap v4 hook callbacks this contract implements.
    // We only need:
    //  - afterInitialize: to verify the newly created pool actually uses
    //    dynamic fees (otherwise our fee logic would never be applied).
    //  - beforeSwap: to compute and apply the penalized dynamic fee for
    //    every swap, and to update the running median estimate.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true, // used to check pool has dynamic fees
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // used for custom fees logic
            afterSwap: true, // used to conditionally update the median, gated by the tick checker
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // -----------------------------------------------
    // INTERNAL / OVERRIDE FUNCTIONS
    // -----------------------------------------------

    // Called by the PoolManager right after a pool using this hook is
    // initialized. If the pool was NOT configured with the dynamic-fee
    // flag, this hook's fee-adjustment logic can never run, so we revert
    // to prevent creating a pool where the hook would be silently useless.
    // Otherwise, we set the pool's initial LP fee to BASIC_FEE.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24)
        internal
        virtual
        override
        returns (bytes4)
    {
        if (!key.fee.isDynamicFee()) revert NotDynamicFee();
        poolManager.updateDynamicLPFee(key, PenaltyFeeLibrary.BASIC_FEE);

        // Extra value assignment needed to depict
        // which pool we should trust and which we should not.
        PoolId id = key.toId();
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        isRegisteredPool[id] = isListed[token0] || isListed[token1];

        return this.afterInitialize.selector;
    }

    // Called by the PoolManager before every swap on a pool using this
    // hook. This is where the penalty logic is actually enforced:
    //   1. If a new block has started, snapshot the (pre-swap) live
    //      median into the rolling window before anything else changes
    //      it this block.
    //   2. Compute the smoothed reference value (average of the window)
    //      that penalties will be judged against.
    //   3. Read how much priority fee the current transaction is paying.
    //   4. Compute the dynamic LP fee for this swap based on how far its
    //      priority fee is above the smoothed reference (see
    //      getDynamicFee_).
    //   5. Feeding this swap's priority fee into the running median
    //      estimator happens separately, in _afterSwap, and only if
    //      the tick checker there decides the pool has moved far
    //      enough since the last accepted update (see
    //      _tickMovedEnoughToUpdate). The fee *decision* here in
    //      beforeSwap always uses the smoothed reference, regardless
    //      of whether this particular swap ends up updating the
    //      median.
    // The computed fee is returned with the OVERRIDE_FEE_FLAG set so the
    // PoolManager uses it instead of the pool's currently stored LP fee.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // 1. Snapshot the live median once per block, before this
        //    swap's own update touches it.
        _recordSnapshotIfNewBlock();

        // 2. Smoothed reference value used for the fee decision.
        int256 referenceMedian = _averageSnapshot();

        // 3. Read this transaction's EIP-1559 priority fee.
        uint256 currentPriorityFee = GetPriorityFeeLibrary.getPriorityFee();

        // 4. Compute the penalized dynamic fee for this swap.
        uint24 totalFee = PenaltyFeeLibrary.getDynamicFee()(currentPriorityFee, referenceMedian);

        return
            (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, totalFee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    // Records a snapshot of the current (pre-update) live median into
    // the rolling window, but at most once per block. Subsequent swaps
    // within the same block are no-ops here, so a burst of swaps in a
    // single block cannot inject more than one data point into the
    // window no matter how many times the live median itself moves
    // during that block.
    function _recordSnapshotIfNewBlock() internal {
        if (block.number == lastSnapshotBlock) return;

        blockMedianSnapshots[snapshotIndex] = medianState.approxMedian;
        snapshotIndex = (snapshotIndex + 1) % SNAPSHOT_WINDOW;
        if (snapshotCount < SNAPSHOT_WINDOW) {
            snapshotCount++;
        }
        lastSnapshotBlock = block.number;
    }

    // Averages the populated slots of the snapshot window. Returns 0 if
    // no snapshot has been recorded yet (e.g. the very first block the
    // hook is ever used in), which getDynamicFee_ treats the same way
    // the old code treated an empty medianState — fall back to
    // BASIC_FEE rather than dividing by zero.
    function _averageSnapshot() internal view returns (int256) {
        if (snapshotCount == 0) return 0;
        int256 sum;
        for (uint256 i; i < snapshotCount;) {
            sum += blockMedianSnapshots[i];
            unchecked {
                ++i;
            }
        }
        return sum / int256(snapshotCount);
    }

    // Updates the running approximate median (medianState) with the
    // priority fee observed in the current swap. Delegates the actual
    // math to FrugalMedianLibrary and just persists whatever it returns.
    // This must run on every swap so the median stays representative of
    // recent priority-fee activity — the block-level rate limiting lives
    // in the snapshot layer above, not here.
    function updateMedian_(uint256 _currentPriorityFee) internal {
        (int256 updatedMedian, int256 updatedStep, bool updatedDirectionIsPositive) = FrugalMedianLibrary.updateApproxMedian(
            int256(_currentPriorityFee), medianState.approxMedian, medianState.step, medianState.positive
        );
        medianState.approxMedian = updatedMedian;
        medianState.step = updatedStep;
        medianState.positive = updatedDirectionIsPositive;
    }

    // Called by the PoolManager right after every swap on a pool using
    // this hook. Only registered pools are considered at all. Among
    // those, the running median is updated with this swap's priority
    // fee ONLY if the tick checker (_tickMovedEnoughToUpdate) decides
    // the pool's price has moved far enough since the last accepted
    // update — see that function's docs for why. This runs against
    // the POST-swap tick, since afterSwap fires once the swap (and
    // its effect on the pool's price) has already been applied.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        if (isRegisteredPool[id] && _tickMovedEnoughToUpdate(id)) {
            uint256 currentPriorityFee = GetPriorityFeeLibrary.getPriorityFee();
            updateMedian_(currentPriorityFee);
        }
        return (BaseHook.afterSwap.selector, 0);
    }

    // -----------------------------------------------
    // TICK CHECKER
    // -----------------------------------------------

    // Decides whether the pool identified by `id` has moved far enough
    // in tick terms, since the last time it was allowed to update the
    // median, to trust this swap's priority fee again.
    //
    // Rationale: without this gate, many swaps that barely move the
    // price (or don't move it at all, e.g. tiny/dust trades) could
    // each nudge the running median in the same direction. Requiring a
    // minimum tick displacement means the median only reacts to swaps
    // that actually pushed the pool to a new price level — not to
    // repeated pokes at essentially the same price, which is exactly
    // the kind of cheap, repeatable action an attacker would use to
    // drag the median toward a favorable value.
    //
    // The required displacement is not a flat constant — it is scaled
    // by the pool's current liquidity depth in _requiredTickMovement,
    // because the same tick move means very different things in a deep
    // pool vs. a shallow one.
    function _tickMovedEnoughToUpdate(PoolId id) internal returns (bool) {
        (, int24 currentTick,,) = poolManager.getSlot0(id);

        if (!tickBaselineSet[id]) {
            // First observation for this pool: nothing to compare
            // against yet, so accept this swap and establish the
            // baseline for future comparisons.
            lastMedianUpdateTick[id] = currentTick;
            tickBaselineSet[id] = true;
            return true;
        }

        int24 tickDelta = currentTick - lastMedianUpdateTick[id];
        if (tickDelta < 0) tickDelta = -tickDelta;

        uint128 liquidity = poolManager.getLiquidity(id);
        int24 requiredMove = _requiredTickMovement(liquidity);

        if (tickDelta < requiredMove) {
            return false;
        }

        lastMedianUpdateTick[id] = currentTick;
        return true;
    }

    // Computes how many ticks a pool must move before a swap's
    // priority fee is trusted enough to update the median, given the
    // pool's current liquidity:
    //
    //   requiredMove = BASE_TICK_THRESHOLD * sqrt(REFERENCE_LIQUIDITY / liquidity)
    //
    // - Deep pool (liquidity > REFERENCE_LIQUIDITY): requiredMove
    //   shrinks below BASE_TICK_THRESHOLD. Moving the tick in a deep
    //   pool requires a large, expensive trade, so even a modest tick
    //   move there is a meaningful, hard-to-fake signal — we can
    //   afford to accept the median update more readily.
    // - Shallow pool (liquidity < REFERENCE_LIQUIDITY): requiredMove
    //   grows above BASE_TICK_THRESHOLD. A small trade can swing a
    //   thin pool's tick a long way, so that movement alone proves
    //   little and is cheap to manufacture — we demand a bigger move
    //   before trusting it.
    //
    // sqrt-scaling (rather than a flat 1/liquidity scaling) keeps the
    // threshold from exploding or collapsing too aggressively across
    // the wide range of liquidity real pools have; it mirrors how
    // price impact for a fixed trade size scales roughly with
    // 1/sqrt(liquidity) in a constant-product-style AMM, so the
    // required tick move tracks "how hard was this to fake" instead of
    // an arbitrary fixed number of ticks.
    //
    // Result is clamped to [MIN_TICK_THRESHOLD, MAX_TICK_THRESHOLD].
    function _requiredTickMovement(uint128 liquidity) internal pure returns (int24) {
        if (liquidity == 0) return MAX_TICK_THRESHOLD;

        uint256 sqrtLiquidity = Math.sqrt(uint256(liquidity));
        uint256 sqrtReference = Math.sqrt(uint256(REFERENCE_LIQUIDITY));

        uint256 scaled = (uint256(uint24(BASE_TICK_THRESHOLD)) * sqrtReference) / sqrtLiquidity;

        if (scaled < uint256(uint24(MIN_TICK_THRESHOLD))) return MIN_TICK_THRESHOLD;
        if (scaled > uint256(uint24(MAX_TICK_THRESHOLD))) return MAX_TICK_THRESHOLD;
        return int24(int256(scaled));
    }
}
