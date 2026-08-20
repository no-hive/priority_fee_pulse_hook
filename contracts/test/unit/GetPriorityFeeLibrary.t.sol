// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {GetPriorityFeeLibrary} from "../../src/lib/GetPriorityFeeLibrary.sol";

// -----------------------------------------------------------------------
// Unit tests for GetPriorityFeeLibrary.getPriorityFee (tx.gasprice -
// block.basefee, floored at 0).
//
// SOURCE: no draft test isolated this library directly — `vm.fee(...)` /
// `vm.txGasPrice(...)` were only ever used as setup for full swaps in the
// integration/fork tests. Nothing to move here.
//
// getPriorityFee is `internal view` (reads tx.gasprice/block.basefee), so
// it can be called directly from this test contract after setting
// vm.fee(...) / vm.txGasPrice(...) — no hook deployment needed.
// -----------------------------------------------------------------------
contract GetPriorityFeeLibraryTest is Test {
    // ------------------------------------------------------------------
    // TODO (author): unit tests for GetPriorityFeeLibrary go here, e.g.:
    //   - tx.gasprice > block.basefee -> priorityFee == difference
    //   - tx.gasprice == block.basefee -> priorityFee == 0
    //   - tx.gasprice < block.basefee (legacy tx case) -> priorityFee == 0
    //     without underflow/revert
    // ------------------------------------------------------------------
}
