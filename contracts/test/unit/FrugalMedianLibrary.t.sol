// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {FrugalMedianLibrary} from "../../src/lib/FrugalMedianLibrary.sol";

// -----------------------------------------------------------------------
// Unit tests for FrugalMedianLibrary (frugalMedian / updateApproxMedian).
//
// SOURCE: no draft test isolated this library directly — its behavior was
// only ever exercised indirectly, end-to-end, through swaps in
// test/integration/MPFHook.t.sol (Tests 2-5: high/low/sustained priority
// fee pressure, convergence, recovery). Those integration tests stay
// where they are (they exercise FrugalMedianLibrary + SnapshotWindowLibrary
// + TickCheckerLibrary + PenaltyFeeLibrary together, through real
// PoolManager swaps) — nothing to move here.
//
// Both `frugalMedian` and `updateApproxMedian` are `public pure`, so they
// can be called directly on the library from this test contract — no hook
// deployment needed.
// -----------------------------------------------------------------------
contract FrugalMedianLibraryTest is Test {
    // ------------------------------------------------------------------
    // TODO (author): unit tests for FrugalMedianLibrary go here, e.g.:
    //   - updateApproxMedian: single-step convergence direction/step size
    //   - updateApproxMedian: step-reset behavior on direction reversal
    //   - frugalMedian: convergence over a known sequence
    //   - fuzz: median stays within [min(sequence), max(sequence)]
    // ------------------------------------------------------------------
}
