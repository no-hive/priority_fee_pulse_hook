// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

library GetPriorityFeeLibrary {
    // Returns the priority fee (tip above the base fee) paid by the
    // current transaction. This concept only exists for EIP-1559
    // transactions (tx.gasprice > block.basefee); for legacy transactions
    // or when tx.gasprice does not exceed the base fee, we treat the
    // priority fee as zero rather than reverting or underflowing.
    function getPriorityFee() internal view returns (uint256) {
        uint256 priorityFee;
        // Priority fee = what the sender actually paid above the base fee.
        if (tx.gasprice <= block.basefee) {
            priorityFee = 0;
        } else {
            priorityFee = tx.gasprice - block.basefee;
        }
        return priorityFee;
    }
}
