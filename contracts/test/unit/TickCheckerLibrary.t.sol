// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickCheckerLibrary} from "../../src/lib/TickCheckerLibrary.sol";

// -----------------------------------------------------------------------
// Unit tests for TickCheckerLibrary (movedEnoughToUpdate / requiredMovement).
//
// SOURCE: none of the three draft files test this gate in isolation —
// the tick-movement requirement was never directly exercised (the
// integration/fork drafts always used a fresh baseline tick, so the gate
// was implicitly satisfied on every swap's first observation). This is a
// real coverage gap worth flagging: the tick checker is the mechanism
// that stops dust-swap median manipulation, so it deserves dedicated
// tests here.
//
// TickCheckerLibrary.State holds mappings, so it must stay in storage;
// this test contract holds its own `State` slot and calls the library on
// it directly — no hook deployment needed for the movedEnoughToUpdate
// logic itself. requiredMovement is `pure` and callable directly with any
// liquidity value.
// -----------------------------------------------------------------------
contract TickCheckerLibraryTest is Test {
    using TickCheckerLibrary for TickCheckerLibrary.State;

    TickCheckerLibrary.State internal tickCheckerState;

    // ------------------------------------------------------------------
    // TODO (author): unit tests for TickCheckerLibrary go here, e.g.:
    //   - movedEnoughToUpdate: first observation for a pool always
    //     accepts and sets the baseline
    //   - movedEnoughToUpdate: rejects when tick delta < requiredMovement
    //   - movedEnoughToUpdate: accepts and updates baseline once delta
    //     crosses the threshold
    //   - requiredMovement: clamps to MIN/MAX_TICK_THRESHOLD at the
    //     extremes (liquidity == 0, liquidity >> REFERENCE_LIQUIDITY)
    //   - requiredMovement: matches BASE_TICK_THRESHOLD exactly at
    //     liquidity == REFERENCE_LIQUIDITY
    // ------------------------------------------------------------------
}
