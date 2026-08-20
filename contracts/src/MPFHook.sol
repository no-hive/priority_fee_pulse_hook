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

/// @title MedianPriorityFeeHook
/// @notice Uniswap v4 hook that tracks a running (approximate) median of the
///         priority fee paid by swappers and penalizes swaps whose priority
///         fee is significantly above that median, discouraging aggressive
///         priority-fee bidding (e.g. sandwich/MEV-style behavior) via a
///         higher dynamic LP fee.
/// @dev To resist single-block / short-burst manipulation of the running
///      median, the fee decision is not based on the live, per-swap-updated
///      median directly. Instead, the live median is snapshotted once per
///      block into a rolling window (see SnapshotWindowLibrary), and the
///      fee is computed against the average of that window. The live
///      median itself is also gated by a tick checker (see
///      TickCheckerLibrary): a swap only feeds its priority fee into the
///      median if the pool's tick has moved far enough since the last
///      accepted update.
///
///      Read/compute logic lives in libraries; this contract is
///      orchestration only — it holds storage, implements the BaseHook
///      callbacks, and wires PoolManager data into the library calls.
contract MedianPriorityFeeHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;
    using SnapshotWindowLibrary for SnapshotWindowLibrary.State;
    using TickCheckerLibrary for TickCheckerLibrary.State;

    // -----------------------------------------------
    // ERRORS
    // -----------------------------------------------

    /// @notice Thrown in `_afterInitialize` when a pool is created without
    ///         the dynamic-fee flag set.
    /// @dev Without dynamic fees enabled, this hook's whole fee-adjustment
    ///      logic would have no effect on the pool, so we reject such pools
    ///      outright instead of silently doing nothing.
    error NotDynamicFee();

    // -----------------------------------------------
    // EVENTS
    // -----------------------------------------------

    /// @notice Emitted when a pool's registration status is set.
    /// @dev Lets indexers/frontends know whether a pool's swaps feed into
    ///      the median without having to read `isRegisteredPool` directly.
    /// @param id The pool id.
    /// @param registered Whether the pool is registered.
    event PoolRegistered(PoolId indexed id, bool registered);

    /// @notice Emitted whenever the running median estimator is updated.
    /// @dev The key metric of the system — without this, tracking the
    ///      median's evolution requires an archive node/tracing. Emitted
    ///      from `_afterSwap` only when the tick checker allows the update.
    /// @param id The pool whose swap triggered the update.
    /// @param newMedian The updated approximate median.
    /// @param step The updated step size of the frugal-median estimator.
    /// @param positive The direction of this update (increase vs decrease).
    event MedianUpdated(PoolId indexed id, int256 newMedian, int256 step, bool positive);

    /// @notice Emitted for every swap once its dynamic LP fee is computed.
    /// @dev Lets anyone reconstruct, after the fact, who was penalized and
    ///      by how much — useful both for trader/LP transparency and for
    ///      debugging the penalty model.
    /// @param id The pool being swapped in.
    /// @param fee The dynamic LP fee applied (without the override flag).
    /// @param priorityFee The swap's EIP-1559 priority fee.
    /// @param referenceMedian The smoothed median the fee was judged against.
    event FeeApplied(PoolId indexed id, uint24 fee, uint256 priorityFee, int256 referenceMedian);

    // -----------------------------------------------
    // STORAGE VARIABLES
    // -----------------------------------------------

    /// @notice Running state for the approximate-median estimator.
    /// @dev NOTE: this state is shared across all pools that use this hook
    ///      instance — there is a single global median, not one per pool.
    ///      Updated in _afterSwap (see updateMedian_), conditionally on the
    ///      tick checker allowing it for that pool.
    struct MedianState {
        int256 approxMedian; // current estimate of the median priority fee
        int256 step; // current step size used by the frugal-median update rule
        bool positive; // direction of the last adjustment (increase vs decrease)
    }

    /// @notice Current global median-priority-fee estimator state.
    MedianState public medianState;

    /// @notice Rolling window of per-block median snapshots + bookkeeping.
    /// @dev Kept private: a struct containing a fixed-size array only
    ///      exposes its non-array/non-mapping members through an
    ///      auto-generated getter, so explicit view functions are provided
    ///      below instead.
    SnapshotWindowLibrary.State private snapshotState;

    /// @notice Whitelist of pools whose swaps are allowed to feed into the
    ///         median.
    /// @dev A pool is registered if either of its tokens is in `isListed`;
    ///      see _afterInitialize.
    mapping(PoolId => bool) public isRegisteredPool;

    /// @notice Whitelist of "nice and sound" token addresses.
    /// @dev Only initialized in the constructor. Chain-specific.
    mapping(address => bool) public isListed;

    /// @notice Per-pool tick-checker bookkeeping (last accepted tick +
    ///         baseline flag).
    /// @dev Held as a struct-of-mappings, so it is private with explicit
    ///      passthrough getters below instead of relying on the
    ///      auto-generated getter.
    TickCheckerLibrary.State private tickCheckerState;

    // -----------------------------------------------
    // CONSTRUCTOR
    // -----------------------------------------------

    /// @notice Deploys the hook and seeds the token whitelist.
    /// @param _poolManager The Uniswap v4 PoolManager this hook is attached to.
    /// @param _listedTokens Token addresses to mark as "listed" (see `isListed`).
    constructor(IPoolManager _poolManager, address[] memory _listedTokens) BaseHook(_poolManager) {
        for (uint256 i = 0; i < _listedTokens.length; i++) {
            isListed[_listedTokens[i]] = true;
        }
    }

    // -----------------------------------------------
    // EXTERNAL / PUBLIC FUNCTIONS
    // -----------------------------------------------

    /// @notice Declares which Uniswap v4 hook callbacks this contract implements.
    /// @dev We only need:
    ///       - afterInitialize: to verify the newly created pool actually
    ///         uses dynamic fees (otherwise our fee logic would never be
    ///         applied).
    ///       - beforeSwap: to compute and apply the penalized dynamic fee
    ///         for every swap.
    ///       - afterSwap: to conditionally update the running median
    ///         estimate.
    /// @return The set of hook permissions used by this contract.
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
    // VIEW FUNCTIONS
    // -----------------------------------------------

    /// @notice Returns the recorded median snapshot at a given index in the rolling window.
    /// @param i Index into the snapshot window.
    /// @return The snapshotted approximate-median value at index `i`.
    function blockMedianSnapshots(uint256 i) external view returns (int256) {
        return snapshotState.snapshots[i];
    }

    /// @notice Number of snapshots currently recorded in the rolling window.
    /// @return The current snapshot count.
    function snapshotCount() external view returns (uint256) {
        return snapshotState.count;
    }

    /// @notice Current write index into the rolling snapshot window.
    /// @return The current snapshot index.
    function snapshotIndex() external view returns (uint256) {
        return snapshotState.index;
    }

    /// @notice Block number at which the last snapshot was recorded.
    /// @return The last snapshot's block number.
    function lastSnapshotBlock() external view returns (uint256) {
        return snapshotState.lastBlock;
    }

    /// @notice Tick recorded the last time the median was accepted for update, for a given pool.
    /// @param id The pool id to query.
    /// @return The last tick at which the median was updated for `id`.
    function lastMedianUpdateTick(PoolId id) external view returns (int24) {
        return tickCheckerState.lastMedianUpdateTick[id];
    }

    /// @notice Whether the tick baseline has been set for a given pool.
    /// @param id The pool id to query.
    /// @return True if a baseline tick has been recorded for `id`.
    function tickBaselineSet(PoolId id) external view returns (bool) {
        return tickCheckerState.tickBaselineSet[id];
    }

    // -----------------------------------------------
    // INTERNAL / OVERRIDE FUNCTIONS
    // -----------------------------------------------

    /// @notice Hook callback run by the PoolManager right after a pool using this hook is initialized.
    /// @dev If the pool was NOT configured with the dynamic-fee flag, this
    ///      hook's fee-adjustment logic can never run, so we revert to
    ///      prevent creating a pool where the hook would be silently
    ///      useless. Otherwise, we set the pool's initial LP fee to
    ///      BASIC_FEE.
    /// @param key The pool's key.
    /// @return The function selector required by the BaseHook callback interface.
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
        emit PoolRegistered(id, isRegisteredPool[id]);

        return this.afterInitialize.selector;
    }

    /// @notice Hook callback run by the PoolManager before every swap on a pool using this hook; computes and applies the penalized dynamic LP fee.
    /// @dev This is where the penalty logic is actually enforced:
    ///       1. If a new block has started, snapshot the (pre-swap) live
    ///          median into the rolling window before anything else changes
    ///          it this block.
    ///       2. Compute the smoothed reference value (average of the
    ///          window) that penalties will be judged against.
    ///       3. Read how much priority fee the current transaction is
    ///          paying.
    ///       4. Compute the dynamic LP fee for this swap based on how far
    ///          its priority fee is above the smoothed reference (see
    ///          PenaltyFeeLibrary.getDynamicFee_).
    ///       5. Feeding this swap's priority fee into the running median
    ///          estimator happens separately, in _afterSwap, and only if
    ///          the tick checker there decides the pool has moved far
    ///          enough since the last accepted update (see
    ///          TickCheckerLibrary.movedEnoughToUpdate). The fee *decision*
    ///          here in beforeSwap always uses the smoothed reference,
    ///          regardless of whether this particular swap ends up
    ///          updating the median.
    ///      The computed fee is returned with the OVERRIDE_FEE_FLAG set so
    ///      the PoolManager uses it instead of the pool's currently stored
    ///      LP fee.
    /// @param key The pool's key.
    /// @return selector The function selector required by the BaseHook callback interface.
    /// @return delta Always zero — this hook does not adjust swap amounts.
    /// @return fee The dynamic LP fee to apply to this swap, OR-ed with `LPFeeLibrary.OVERRIDE_FEE_FLAG`.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4 selector, BeforeSwapDelta delta, uint24 fee)
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

        emit FeeApplied(key.toId(), totalFee, currentPriorityFee, referenceMedian);

        return
            (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, totalFee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @notice Hook callback run by the PoolManager right after every swap on a pool using this hook; conditionally updates the running median.
    /// @dev Only registered pools are considered at all. Among those, the
    ///      running median is updated with this swap's priority fee ONLY
    ///      if the tick checker (TickCheckerLibrary.movedEnoughToUpdate)
    ///      decides the pool's price has moved far enough since the last
    ///      accepted update — see that library's docs for why. This runs
    ///      against the POST-swap tick, since afterSwap fires once the
    ///      swap (and its effect on the pool's price) has already been
    ///      applied.
    /// @param key The pool's key.
    /// @return selector The function selector required by the BaseHook callback interface.
    /// @return delta Always zero — this hook does not adjust settlement amounts.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4 selector, int128 delta)
    {
        PoolId id = key.toId();
        if (isRegisteredPool[id]) {
            (, int24 currentTick,,) = poolManager.getSlot0(id);
            uint128 liquidity = poolManager.getLiquidity(id);

            if (tickCheckerState.movedEnoughToUpdate(id, currentTick, liquidity)) {
                uint256 currentPriorityFee = GetPriorityFeeLibrary.getPriorityFee();
                updateMedian_(currentPriorityFee);
                emit MedianUpdated(id, medianState.approxMedian, medianState.step, medianState.positive);
            }
        }
        return (BaseHook.afterSwap.selector, 0);
    }

    // -----------------------------------------------
    // LIBRARY ADAPTERS
    // -----------------------------------------------

    /// @notice Updates the running approximate median with the priority fee observed in the current swap.
    /// @dev Delegates the actual math to FrugalMedianLibrary and just
    ///      persists whatever it returns. Called from _afterSwap, which
    ///      decides whether this swap's priority fee should be fed in.
    /// @param _currentPriorityFee The priority fee (in wei) paid by the current swap.
    function updateMedian_(uint256 _currentPriorityFee) internal {
        (int256 updatedMedian, int256 updatedStep, bool updatedDirectionIsPositive) = FrugalMedianLibrary.updateApproxMedian(
            int256(_currentPriorityFee), medianState.approxMedian, medianState.step, medianState.positive
        );
        medianState.approxMedian = updatedMedian;
        medianState.step = updatedStep;
        medianState.positive = updatedDirectionIsPositive;
    }
}
