// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

/// @title SnapshotWindowLibrary
/// @notice Stateful library that maintains a fixed-size rolling window of
///         per-block snapshots of the live approximate median.
/// @dev One snapshot is recorded per block (on the first swap that touches
///      a registered pool in that block); `average` returns the smoothed
///      reference value that `PenaltyFeeLibrary` compares priority fees
///      against.
///
///      Operates directly on the caller's storage via a `storage` struct
///      reference (the same pattern OpenZeppelin uses for EnumerableSet /
///      Checkpoints), so the hook contract never has to duplicate the
///      window bookkeeping logic itself — it just holds a `State` slot and
///      calls into this library.
library SnapshotWindowLibrary {
    /// @notice How many past blocks' median snapshots are averaged
    ///         together to form the reference value that penalties are
    ///         computed against.
    /// @dev 15 blocks was chosen to mirror Uniswap's Truncated Oracle hook
    ///      (~15 blocks / ~3 minutes on L1): long enough that sustaining a
    ///      manipulation of the reference is costly (arbitrage / competing
    ///      flow works against the attacker the whole time), short enough
    ///      that the reference still tracks genuine shifts in network fee
    ///      conditions at a reasonable pace.
    uint256 internal constant SNAPSHOT_WINDOW = 15;

    /// @notice Rolling window of per-block median snapshots + bookkeeping.
    struct State {
        int256[SNAPSHOT_WINDOW] snapshots; // rolling window of per-block median snapshots
        uint256 count; // how many slots are populated so far (saturates at SNAPSHOT_WINDOW)
        uint256 index; // next write position in the circular buffer
        uint256 lastBlock; // block number of the last recorded snapshot
    }

    /// @notice Records a snapshot of the current (pre-update) live median
    ///         into the rolling window, at most once per block.
    /// @dev Subsequent calls within the same block are no-ops, so a burst
    ///      of swaps in a single block cannot inject more than one data
    ///      point into the window no matter how many times the live
    ///      median itself moves during that block.
    /// @param self The snapshot-window storage for this hook instance.
    /// @param liveMedian The current live median to snapshot.
    function recordIfNewBlock(State storage self, int256 liveMedian) internal {
        if (block.number == self.lastBlock) return;

        self.snapshots[self.index] = liveMedian;
        self.index = (self.index + 1) % SNAPSHOT_WINDOW;
        if (self.count < SNAPSHOT_WINDOW) {
            self.count++;
        }
        self.lastBlock = block.number;
    }

    /// @notice Averages the populated slots of the snapshot window.
    /// @dev Returns 0 if no snapshot has been recorded yet (e.g. the very
    ///      first block the hook is ever used in); the caller
    ///      (`PenaltyFeeLibrary.getDynamicFee_`) treats a non-positive
    ///      reference as "no data yet" and falls back to the baseline fee
    ///      rather than dividing by zero.
    /// @param self The snapshot-window storage for this hook instance.
    /// @return The average of the populated snapshot slots, or 0 if empty.
    function average(State storage self) internal view returns (int256) {
        if (self.count == 0) return 0;
        int256 sum;
        for (uint256 i; i < self.count;) {
            sum += self.snapshots[i];
            unchecked {
                ++i;
            }
        }
        return sum / int256(self.count);
    }
}
