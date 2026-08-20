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
import {SnapshotWindowLibrary} from "./lib/SnapshotWindowLibrary.sol";
import {TickCheckerLibrary} from "./lib/TickCheckerLibrary.sol";
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
// is snapshotted once per block into a rolling window (see
// SnapshotWindowLibrary), and the fee is computed against the AVERAGE of
// that window. This mirrors the design of Uniswap's own Truncated Oracle
// hook (https://blog.uniswap.org/uniswap-v4-truncated-oracle-hook), which
// smooths its recorded tick over ~15 blocks so that manipulating it
// requires sustaining the attack over multiple blocks, not just one.
// The live median itself no longer updates on every swap unconditionally.
// It is additionally gated by a tick checker (see TickCheckerLibrary): a
// swap only feeds its priority fee into the median if the pool's tick has
// moved far enough, since the last accepted update, relative to a
// threshold that scales with the pool's current liquidity depth. This
// stops a burst of same-price (or dust) swaps from repeatedly nudging the
// median with no real price movement behind it, on top of the existing
// per-block snapshot smoothing used for the fee decision itself.
//
// Read/compute logic lives in libraries; this contract is orchestration
// only — it holds storage, implements the BaseHook callbacks, and wires
// PoolManager data into the library calls.
contract MedianPriorityFeeHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;
    using SnapshotWindowLibrary for SnapshotWindowLibrary.State;
    using TickCheckerLibrary for TickCheckerLibrary.State;

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

    // Rolling window of per-block median snapshots + bookkeeping. See
    // SnapshotWindowLibrary for the update/average logic; the raw fields
    // are no longer public directly (a struct containing a fixed-size
    // array only exposes its non-array/non-mapping members through an
    // auto-generated getter), so equivalent view functions are exposed
    // below to keep the same external surface as before.
    SnapshotWindowLibrary.State private snapshotState;

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

    // Per-pool tick-checker bookkeeping (last accepted tick + baseline
    // flag). See TickCheckerLibrary. Held as a struct-of-mappings, so
    // (like snapshotState) it is private with explicit passthrough
    // getters below instead of relying on the auto-generated getter.
    TickCheckerLibrary.State private tickCheckerState;

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
    // VIEW FUNCTIONS (public surface previously provided by
    // auto-generated getters on the now-private struct fields)
    // -----------------------------------------------

    function blockMedianSnapshots(uint256 i) external view returns (int256) {
        return snapshotState.snapshots[i];
    }

    function snapshotCount() external view returns (uint256) {
        return snapshotState.count;
    }

    function snapshotIndex() external view returns (uint256) {
        return snapshotState.index;
    }

    function lastSnapshotBlock() external view returns (uint256) {
        return snapshotState.lastBlock;
    }

    function lastMedianUpdateTick(PoolId id) external view returns (int24) {
        return tickCheckerState.lastMedianUpdateTick[id];
    }

    function tickBaselineSet(PoolId id) external view returns (bool) {
        return tickCheckerState.tickBaselineSet[id];
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
    //      PenaltyFeeLibrary.getDynamicFee_).
    //   5. Feeding this swap's priority fee into the running median
    //      estimator happens separately, in _afterSwap, and only if
    //      the tick checker there decides the pool has moved far
    //      enough since the last accepted update (see
    //      TickCheckerLibrary.movedEnoughToUpdate). The fee *decision*
    //      here in beforeSwap always uses the smoothed reference,
    //      regardless of whether this particular swap ends up updating
    //      the median.
    // The computed fee is returned with the OVERRIDE_FEE_FLAG set so the
    // PoolManager uses it instead of the pool's currently stored LP fee.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // 1. Snapshot the live median once per block, before this
        //    swap's own update touches it.
        snapshotState.recordIfNewBlock(medianState.approxMedian);

        // 2. Smoothed reference value used for the fee decision.
        int256 referenceMedian = snapshotState.average();

        // 3. Read this transaction's EIP-1559 priority fee.
        uint256 currentPriorityFee = GetPriorityFeeLibrary.getPriorityFee();

        // 4. Compute the penalized dynamic fee for this swap.
        uint24 totalFee = PenaltyFeeLibrary.getDynamicFee_(currentPriorityFee, referenceMedian);

        return
            (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, totalFee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
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
    // fee ONLY if the tick checker (TickCheckerLibrary.movedEnoughToUpdate)
    // decides the pool's price has moved far enough since the last
    // accepted update — see that library's docs for why. This runs
    // against the POST-swap tick, since afterSwap fires once the swap
    // (and its effect on the pool's price) has already been applied.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        if (isRegisteredPool[id]) {
            (, int24 currentTick,,) = poolManager.getSlot0(id);
            uint128 liquidity = poolManager.getLiquidity(id);

            if (tickCheckerState.movedEnoughToUpdate(id, currentTick, liquidity)) {
                uint256 currentPriorityFee = GetPriorityFeeLibrary.getPriorityFee();
                updateMedian_(currentPriorityFee);
            }
        }
        return (BaseHook.afterSwap.selector, 0);
    }
}
