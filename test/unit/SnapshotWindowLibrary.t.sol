// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {SnapshotWindowLibrary} from "../../src/lib/SnapshotWindowLibrary.sol";

// -----------------------------------------------------------------------
// Unit tests for SnapshotWindowLibrary (recordIfNewBlock / average).
//
// SOURCE: no draft test isolated this library directly — the rolling
// window's smoothing effect was only ever exercised indirectly, across
// many blocks, through the integration tests in
// test/integration/MPFHook.t.sol. Nothing to move here.
//
// SnapshotWindowLibrary.State lives in storage, so this test contract
// needs to hold its own `State` slot and call the library on it directly
// (`using SnapshotWindowLibrary for SnapshotWindowLibrary.State;`) — no
// hook deployment needed, this is pure storage manipulation + vm.roll.
// -----------------------------------------------------------------------
contract SnapshotWindowLibraryTest is Test {
    using SnapshotWindowLibrary for SnapshotWindowLibrary.State;

    SnapshotWindowLibrary.State internal snapshotState;

    // ------------------------------------------------------------------
    // TODO (author): unit tests for SnapshotWindowLibrary go here, e.g.:
    //   - recordIfNewBlock: no-op within the same block (vm.roll not called)
    //   - recordIfNewBlock: records exactly once per new block
    //   - circular buffer wraps correctly past SNAPSHOT_WINDOW entries
    //   - average(): returns 0 before any snapshot is recorded
    //   - average(): correct mean once the window is partially/fully filled
    // ------------------------------------------------------------------
}
