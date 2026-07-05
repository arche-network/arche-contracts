// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title RevenueShare
 * @notice Distributes L1/L2/L3 referral commissions on service payments.
 * @dev Called by ServicePayment. Native $ARCHE.
 *
 * Commission structure (of gross payment amount):
 *   L1 (direct referrer):   10%
 *   L2 (referrer of L1):     6%
 *   L3 (referrer of L2):     4%
 *   Total max:              20%
 *
 * Each referrer must have registered themselves. Unclaimed positions get 0.
 */
contract RevenueShare {
    address public immutable servicePayment;

    // Referral commission percentages (in basis points)
    uint256 public constant L1_BPS = 1000;  // 10%
    uint256 public constant L2_BPS = 600;   // 6%
    uint256 public constant L3_BPS = 400;   // 4%

    // Statistics per referrer
    mapping(address => uint256) public totalEarnedByReferrer;
    mapping(address => uint256) public totalReferralsByReferrer;

    // Global stats
    uint256 public totalDistributed;

    event ReferralPaid(
        address indexed referrer,
        address indexed payer,
        uint256 indexed agentId,
        uint8 tier,
        uint256 amount
    );

    error OnlyServicePayment();
    error TransferFailed();

    modifier onlyServicePayment() {
        if (msg.sender != servicePayment) revert OnlyServicePayment();
        _;
    }

    constructor(address _servicePayment) {
        require(_servicePayment != address(0), "Zero addr");
        servicePayment = _servicePayment;
    }

    /**
     * @notice Actual distribution function called by ServicePayment.
     * @param agentId Agent that was paid
     * @param payer User who paid
     * @param baseAmount Original gross payment amount
     * @param referrers L1, L2, L3 addresses (address(0) means no referrer at that tier)
     */
    function distribute(
        uint256 agentId,
        address payer,
        uint256 baseAmount,
        address[3] calldata referrers
    ) external payable onlyServicePayment returns (uint256 distributed) {
        uint256[3] memory bps = [L1_BPS, L2_BPS, L3_BPS];

        for (uint256 i = 0; i < 3; i++) {
            if (referrers[i] == address(0)) continue;

            uint256 amount = (baseAmount * bps[i]) / 10000;
            if (distributed + amount > msg.value) {
                // Cap to remaining budget
                amount = msg.value - distributed;
            }
            if (amount == 0) continue;

            (bool ok,) = referrers[i].call{value: amount}("");
            if (!ok) revert TransferFailed();

            totalEarnedByReferrer[referrers[i]] += amount;
            totalReferralsByReferrer[referrers[i]] += 1;
            distributed += amount;

            emit ReferralPaid(referrers[i], payer, agentId, uint8(i + 1), amount);

            if (distributed >= msg.value) break;
        }

        totalDistributed += distributed;

        // Refund unused budget
        if (msg.value > distributed) {
            uint256 refund = msg.value - distributed;
            (bool ok,) = msg.sender.call{value: refund}("");
            if (!ok) revert TransferFailed();
        }

        return distributed;
    }
}
