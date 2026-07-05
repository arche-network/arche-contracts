// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title AgentTax
 * @notice Enforces the 2.5% Agent Runtime Tax with dual-deflation flywheel.
 * @dev Called by ServicePayment on every user->agent payment.
 *      50% burned (sent to DEAD address), 50% goes to ArcheTreasury.
 *      Native $ARCHE (msg.value).
 *
 * Dynamic tax rates based on lockedStake:
 *   >= 100_000 ARCHE locked -> 1.0%
 *   >= 10_000 ARCHE locked  -> 1.5%
 *   >= 1_000 ARCHE locked   -> 2.0%
 *   otherwise               -> 2.5%
 */
contract AgentTax {
    // Basis points (10000 = 100%)
    uint256 public constant TAX_BASE_BPS = 250;      // 2.5%
    uint256 public constant TAX_TIER_1_BPS = 200;    // 2.0%
    uint256 public constant TAX_TIER_2_BPS = 150;    // 1.5%
    uint256 public constant TAX_TIER_3_BPS = 100;    // 1.0%

    uint256 public constant STAKE_TIER_1 = 1_000 ether;
    uint256 public constant STAKE_TIER_2 = 10_000 ether;
    uint256 public constant STAKE_TIER_3 = 100_000 ether;

    // Split of tax amount
    uint256 public constant BURN_SHARE_BPS = 5000;      // 50%
    uint256 public constant TREASURY_SHARE_BPS = 5000;  // 50%

    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    address public immutable treasury;
    address public immutable servicePayment;

    // Statistics
    uint256 public totalTaxCollected;
    uint256 public totalBurned;
    uint256 public totalToTreasury;

    event TaxProcessed(
        address indexed payer,
        uint256 grossAmount,
        uint256 taxAmount,
        uint256 burned,
        uint256 toTreasury
    );

    error OnlyServicePayment();
    error TransferFailed();
    error InvalidAmount();

    modifier onlyServicePayment() {
        if (msg.sender != servicePayment) revert OnlyServicePayment();
        _;
    }

    constructor(address _treasury, address _servicePayment) {
        require(_treasury != address(0) && _servicePayment != address(0), "Zero addr");
        treasury = _treasury;
        servicePayment = _servicePayment;
    }

    /**
     * @notice Calculate the tax rate given locked stake amount.
     * @param lockedStake Amount of $ARCHE locked by the payer.
     * @return taxBps Tax rate in basis points.
     */
    function taxRateBps(uint256 lockedStake) public pure returns (uint256) {
        if (lockedStake >= STAKE_TIER_3) return TAX_TIER_3_BPS;
        if (lockedStake >= STAKE_TIER_2) return TAX_TIER_2_BPS;
        if (lockedStake >= STAKE_TIER_1) return TAX_TIER_1_BPS;
        return TAX_BASE_BPS;
    }

    /**
     * @notice Process the tax on a payment.
     * @dev Called by ServicePayment with msg.value = tax amount (already computed).
     *      50% burned, 50% sent to treasury.
     * @param payer Address that originated the payment.
     * @param grossAmount Original payment amount (for logging).
     */
    function processTax(address payer, uint256 grossAmount) external payable onlyServicePayment {
        uint256 taxAmount = msg.value;
        if (taxAmount == 0) revert InvalidAmount();

        uint256 burnAmount = (taxAmount * BURN_SHARE_BPS) / 10000;
        uint256 treasuryAmount = taxAmount - burnAmount; // remainder to avoid rounding loss

        // Burn (send to dead address)
        (bool ok1,) = BURN_ADDRESS.call{value: burnAmount}("");
        if (!ok1) revert TransferFailed();

        // To Treasury
        (bool ok2,) = treasury.call{value: treasuryAmount}("");
        if (!ok2) revert TransferFailed();

        totalTaxCollected += taxAmount;
        totalBurned += burnAmount;
        totalToTreasury += treasuryAmount;

        emit TaxProcessed(payer, grossAmount, taxAmount, burnAmount, treasuryAmount);
    }
}
