// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {PenaltyFeeLibrary} from "../../src/lib/PenaltyFeeLibrary.sol";

// -----------------------------------------------------------------------
// Unit tests for PenaltyFeeLibrary.getDynamicFee_ — the pure penalty-curve
// math (priorityFee vs. smoothed reference median -> dynamic LP fee).
//
// SOURCE: distributed from MedianPriorityFeeHookMath_t.sol. That file used
// to deploy a MedianPriorityFeeHookHarness (via CREATE2/HookMiner) purely
// to reach an `internal` function on the hook. That's no longer needed:
// getDynamicFee_ now lives in PenaltyFeeLibrary as `internal pure`, so this
// test contract can call it directly (the compiler inlines library-internal
// calls into the caller) — no hook deployment, no HookMiner, no dummy
// PoolManager required.
// -----------------------------------------------------------------------
contract PenaltyFeeLibraryTest is Test {
    uint24 constant BASIC_FEE = PenaltyFeeLibrary.BASIC_FEE;
    uint256 constant RATIO_THRESHOLD = PenaltyFeeLibrary.RATIO_THRESHOLD;

    function test_noReferenceYet_returnsBasicFee() public {
        // referenceMedian <= 0 means "no snapshot data yet"
        assertEq(PenaltyFeeLibrary._getDynamicFee(999_999, 0), BASIC_FEE);
        assertEq(PenaltyFeeLibrary._getDynamicFee(999_999, -1), BASIC_FEE);
    }

    function test_belowThreshold_noPenalty() public {
        int256 referenceMedian = 1_000_000; // 1 gwei-ish, arbitrary units
        // Priority fee exactly at the reference (ratio 1.0x) — well below 2.7x
        uint24 fee = PenaltyFeeLibrary._getDynamicFee(uint256(referenceMedian), referenceMedian);
        assertEq(fee, BASIC_FEE);

        // Just under the threshold (2.69x)
        uint256 justUnder = (uint256(referenceMedian) * 2699) / 1000;
        assertEq(PenaltyFeeLibrary._getDynamicFee(justUnder, referenceMedian), BASIC_FEE);
    }

    function test_atThreshold_zeroPenaltyStart() public {
        int256 referenceMedian = 1_000_000;
        // Exactly at 2.7x: excessRatioScaled == 0 -> fracWad == 0 -> penalty 0
        uint256 atThreshold = (uint256(referenceMedian) * RATIO_THRESHOLD) / 1000;
        assertEq(PenaltyFeeLibrary._getDynamicFee(atThreshold, referenceMedian), BASIC_FEE);
    }

    function test_penaltyIncreasesMonotonically() public {
        int256 referenceMedian = 1_000_000;

        uint24 feeAt3x = PenaltyFeeLibrary._getDynamicFee((uint256(referenceMedian) * 3000) / 1000, referenceMedian);
        uint24 feeAt5x = PenaltyFeeLibrary._getDynamicFee((uint256(referenceMedian) * 5000) / 1000, referenceMedian);
        uint24 feeAt7x = PenaltyFeeLibrary._getDynamicFee((uint256(referenceMedian) * 7000) / 1000, referenceMedian);
        uint24 feeAt10x = PenaltyFeeLibrary._getDynamicFee((uint256(referenceMedian) * 10_000) / 1000, referenceMedian);

        assertGt(feeAt3x, BASIC_FEE);
        assertGt(feeAt5x, feeAt3x);
        assertGt(feeAt7x, feeAt5x);
        assertGt(feeAt10x, feeAt7x);
    }

    function test_saturatesAtMaxPenaltyFrom10xOnward() public {
        int256 referenceMedian = 1_000_000;

        uint24 feeAt10x = PenaltyFeeLibrary._getDynamicFee((uint256(referenceMedian) * 10_000) / 1000, referenceMedian);
        uint24 feeAt50x = PenaltyFeeLibrary._getDynamicFee((uint256(referenceMedian) * 50_000) / 1000, referenceMedian);
        uint24 feeAt1000x =
            PenaltyFeeLibrary._getDynamicFee((uint256(referenceMedian) * 1_000_000) / 1000, referenceMedian);

        // Max penalty is 10% = 100_000 ppm, on top of BASIC_FEE (1000 ppm)
        uint24 expectedMaxFee = BASIC_FEE + uint24(10 * 10_000);

        assertEq(feeAt10x, expectedMaxFee);
        assertEq(feeAt50x, expectedMaxFee);
        assertEq(feeAt1000x, expectedMaxFee);
    }

    function testFuzz_feeNeverExceedsMax(uint256 priorityFee, uint256 referenceMedianRaw) public {
        uint256 boundedReferenceMedian = bound(referenceMedianRaw, 1, 1e30);

        int256 referenceMedian = int256(boundedReferenceMedian);

        priorityFee = bound(priorityFee, 0, type(uint128).max);

        uint24 expectedMaxFee = BASIC_FEE + uint24(10 * 10_000);

        uint24 fee = PenaltyFeeLibrary._getDynamicFee(priorityFee, referenceMedian);

        assertLe(fee, expectedMaxFee);
        assertGe(fee, BASIC_FEE);
    }

    // ------------------------------------------------------------------
    // TODO (author): additional PenaltyFeeLibrary-only unit tests go here
    // (e.g. exact-value checks at specific ratios, PRECISION/WAD edge
    // cases, D_CAP boundary behavior).
    // ------------------------------------------------------------------
}
