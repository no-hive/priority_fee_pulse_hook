// SPDX-License-Identifier: MIT
// This lib is part of https://github.com/saucepoint/median-oracles project. Thanks to its creator!
pragma solidity ^0.8.15;

/// @title FrugalMedianLibrary
/// @notice Approximate, O(1)-space running-median estimator ("frugal
///         median" / "1% method"): tracks an estimate of the median of a
///         stream of values without storing the stream itself.
/// @dev Pure math only — no storage, no coupling to any specific caller.
///      Ported from the upstream project linked above; kept as close to
///      the original as possible so it stays easy to diff against future
///      upstream fixes.
library FrugalMedianLibrary {
    /// @notice Computes the frugal-median estimate for an entire sequence
    ///         of values in one call, starting from a fresh estimator.
    /// @dev Folds `updateApproxMedian` over `sequence` in order. The hook
    ///      itself does not call this directly — it feeds one observation
    ///      at a time via `updateApproxMedian` — this is provided for
    ///      batch use (e.g. tests, backfills).
    /// @param sequence The values to estimate the median of, in order.
    /// @return approxMedian The resulting approximate median.
    function frugalMedian(int256[] memory sequence) public pure returns (int256 approxMedian) {
        int256 step;
        uint256 i;
        bool positive;
        for (i; i < sequence.length;) {
            (approxMedian, step, positive) = updateApproxMedian(sequence[i], approxMedian, step, positive);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Advances the estimator by one new observation.
    /// @dev Moves `approxMedian` by `step` toward `newNumber`; `step` grows
    ///      while updates keep moving in the same direction and resets
    ///      toward 1 when the direction flips (see `stepIncrement` for how
    ///      the per-iteration growth is computed). Wrapped in `unchecked`
    ///      since the values involved (priority fees, as int256) cannot
    ///      realistically over/underflow.
    /// @param newNumber The new observation to fold into the estimate.
    /// @param approxMedian The estimator's current median estimate.
    /// @param step The estimator's current step size.
    /// @param positive The direction of the previous update (true = last
    ///        move was upward).
    /// @return The updated (approxMedian, step, positive) triple.
    function updateApproxMedian(int256 newNumber, int256 approxMedian, int256 step, bool positive)
        public
        pure
        returns (int256, int256, bool)
    {
        unchecked {
            if (newNumber > approxMedian) {
                step += positive ? stepIncrement(newNumber) : -stepIncrement(newNumber);
                // Integer division truncates toward zero, so a positive
                // step below 1 would round down to 0 and stall the
                // estimate; floor at 1 instead.
                approxMedian += (step > 0) ? step : int256(1);
                if (approxMedian > newNumber) {
                    step += newNumber - approxMedian;
                    approxMedian = newNumber;
                }
                if (!positive && step > 1) {
                    step = 1;
                }
                positive = true;
            } else if (newNumber < approxMedian) {
                step += !positive ? stepIncrement(newNumber) : -stepIncrement(newNumber);
                approxMedian -= (step > 0) ? step : int256(1);
                // Mirror of the overshoot correction above, for downward moves.
                if (approxMedian < newNumber) {
                    step += approxMedian - newNumber;
                    approxMedian = newNumber;
                }
                if (positive && step > 1) {
                    step = 1;
                }
                positive = false;
            }
        }
        return (approxMedian, step, positive);
    }

    /// @notice Per-iteration increment added to the accumulating `step`.
    /// @dev ~1% of `|newNumber|`, floored at 1 so the estimate can still
    ///      move even for very small values. Because `step` accumulates
    ///      via `step += stepIncrement(...)` across iterations instead of
    ///      being reassigned, a sustained same-direction run of updates
    ///      converges quadratically (~sqrt(2*100) ≈ 14 iterations to fully
    ///      catch up to a new level), not linearly at ~100.
    uint256 private constant STEP_DIVISOR = 100;

    /// @param newNumber The observation the increment is derived from.
    /// @return The step increment for this observation.
    function stepIncrement(int256 newNumber) private pure returns (int256) {
        int256 magnitude = newNumber >= 0 ? newNumber : -newNumber;
        int256 inc = magnitude / int256(STEP_DIVISOR);
        return inc < 1 ? int256(1) : inc;
    }
}
