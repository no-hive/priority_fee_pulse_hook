// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

/// @title GetPriorityFeeLibrary
/// @notice Reads the EIP-1559 priority fee paid by the current transaction.
/// @dev Stateless — a single pure/view helper, no storage.
library GetPriorityFeeLibrary {
    /// @notice Returns the priority fee (tip above the base fee) paid by
    ///         the currently executing transaction.
    /// @dev The priority-fee concept only applies to EIP-1559 transactions
    ///      where `tx.gasprice > block.basefee`. For legacy transactions,
    ///      or whenever `tx.gasprice` does not exceed the base fee, this
    ///      returns 0 rather than reverting or underflowing.
    /// @return priorityFee The priority fee, in wei per gas.
    function getPriorityFee() internal view returns (uint256) {
        uint256 priorityFee;
        if (tx.gasprice <= block.basefee) {
            priorityFee = 0;
        } else {
            priorityFee = tx.gasprice - block.basefee;
        }
        return priorityFee;
    }
}
