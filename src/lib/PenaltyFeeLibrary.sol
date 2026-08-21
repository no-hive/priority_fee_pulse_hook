// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title PenaltyFeeLibrary
/// @notice Computes the dynamic LP fee to charge a swap, penalizing
///         priority fees that sit far above the smoothed reference median.
/// @dev Stateless — pure math over caller-supplied values, no storage.
library PenaltyFeeLibrary {
    using SafeCast for uint256;

    // -----------------------------------------------
    // CONSTANTS
    // -----------------------------------------------

    /// @notice Fixed-point precision used for all ratio math below (3
    ///         decimal places, e.g. a ratio of 1.000 is stored internally
    ///         as 1000).
    uint256 public constant PRECISION = 1000;

    /// @notice Fixed-point precision used for the fractional-exponent
    ///         (`frac^1.5`) computation in `getDynamicFee_`. 1e18 = "1.0"
    ///         in WAD terms.
    uint256 public constant WAD = 1e18;

    /// @notice Ratio (priorityFee / referenceMedian) above which the
    ///         penalty starts to kick in, expressed in `PRECISION` units.
    /// @dev 2700 / 1000 = 2.7x the current reference median.
    uint256 public constant RATIO_THRESHOLD = 2700;

    /// @notice Excess-ratio value (see `getDynamicFee_`) at which the
    ///         penalty is already saturated at `MAX_PENALTY_PERCENT`.
    /// @dev 7300 / 1000 = an excess of 7.3 ratio units above
    ///      `RATIO_THRESHOLD`, i.e. the penalty saturates at a priority fee
    ///      of ~10x the reference median (RATIO_THRESHOLD + D_CAP = 10.0x).
    ///      Beyond this point the penalty is clamped instead of computed.
    uint256 public constant D_CAP = 7300;

    /// @notice Baseline LP fee applied to every swap before any penalty is
    ///         added, expressed in ppm (parts-per-million, where
    ///         1_000_000 = 100%).
    /// @dev 1000 ppm = 0.1%.
    uint24 public constant BASIC_FEE = 1000;

    /// @notice Upper bound on how large the penalty portion of the fee can
    ///         ever get, as a plain percentage (e.g. 10 = 10%).
    /// @dev Caps the total fee so a single swap is never charged more than
    ///      this share of its notional amount as a penalty. Reached
    ///      exactly at a 10x ratio.
    uint256 public constant MAX_PENALTY_PERCENT = 10;

    /// @notice Conversion factor from "percent" to the ppm fee units used
    ///         internally.
    /// @dev 1% == 10_000 ppm, since 1_000_000 ppm == 100%.
    uint256 public constant PENALTY_UNIT = 10000;

    // -----------------------------------------------
    // FEE COMPUTATION
    // -----------------------------------------------

    /// @notice Computes the dynamic LP fee to charge for a swap.
    /// @dev Compares `priorityFee` against `referenceMedian` (the caller
    ///      is expected to pass the smoothed reference — e.g. the average
    ///      of a rolling snapshot window — not a live, single-block value):
    ///      - No reference data yet (`referenceMedian <= 0`): charge only
    ///        `BASIC_FEE`, to avoid dividing by zero.
    ///      - Ratio below `RATIO_THRESHOLD` (2.7x the reference): no
    ///        penalty.
    ///      - Above the threshold: the penalty grows along a single
    ///        power-1.5 curve (`frac^1.5`, where `frac` is how far the
    ///        excess ratio is through the 2.7x -> 10.0x range), up to
    ///        `D_CAP`, beyond which it is clamped at `MAX_PENALTY_PERCENT`.
    ///        Power-1.5 growth (steeper than linear, gentler than
    ///        quadratic at first) was chosen so the curve passes close to
    ///        three calibration points at once: ~1-2% around 4-5x, ~3-5%
    ///        around 7x, and exactly 10% (the hard cap) at 10x. A plain
    ///        integer exponent cannot hit all three points; `frac^1.5` is
    ///        computed cheaply on-chain via `Math.sqrt`
    ///        (`frac^1.5 = frac * sqrt(frac)`), avoiding a full
    ///        fixed-point pow/ln/exp library.
    ///      The final fee is `BASIC_FEE` plus this penalty, in ppm.
    /// @param priorityFee The swap's EIP-1559 priority fee.
    /// @param referenceMedian The smoothed reference priority fee to
    ///        compare against.
    /// @return totalFee The dynamic LP fee for this swap, in ppm.
    function getDynamicFee_(uint256 priorityFee, int256 referenceMedian) internal pure returns (uint24) {
        if (referenceMedian <= 0) return BASIC_FEE;

        uint256 medianPriorityFee = uint256(referenceMedian);

        // How many times (scaled by PRECISION) this swap's priority fee
        // exceeds the smoothed reference. E.g. 2700 means "2.7x the
        // reference".
        uint256 priorityFeeRatioScaled = (priorityFee * PRECISION) / medianPriorityFee;

        uint256 penaltyPpm;
        if (priorityFeeRatioScaled < RATIO_THRESHOLD) {
            // Priority fee is within the tolerated range — no penalty.
            penaltyPpm = 0;
        } else {
            // How far above the threshold this swap's ratio is, scaled by
            // PRECISION (e.g. ratio 3.7 with threshold 2.7 gives an
            // excess of 1.0 * PRECISION).
            uint256 excessRatioScaled = priorityFeeRatioScaled - RATIO_THRESHOLD;

            // Fraction of the way through the penalty range [0, D_CAP],
            // expressed in WAD (1e18 = "fully saturated"). Clamped to WAD
            // instead of computed further once excess reaches D_CAP, both
            // to save gas and to guarantee no overflow regardless of how
            // large priorityFeeRatioScaled is.
            uint256 fracWad = excessRatioScaled >= D_CAP ? WAD : (excessRatioScaled * WAD) / D_CAP;

            // frac^1.5 = frac * sqrt(frac), computed in WAD fixed point.
            // Math.sqrt(fracWad * WAD) rescales sqrt(x/1e18) back to a
            // 1e18-scaled result (sqrt(1e36) == 1e18).
            uint256 sqrtFracWad = Math.sqrt(fracWad * WAD);
            uint256 frac1_5Wad = (fracWad * sqrtFracWad) / WAD;

            penaltyPpm = (frac1_5Wad * MAX_PENALTY_PERCENT * PENALTY_UNIT) / WAD;
        }

        uint24 totalFee = BASIC_FEE + penaltyPpm.toUint24();

        return totalFee;
    }
}
