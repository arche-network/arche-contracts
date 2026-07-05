// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AgentRegistry} from "./AgentRegistry.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IAgentTax {
    function taxRateBps(uint256 lockedStake) external pure returns (uint256);
    function processTax(address payer, uint256 grossAmount) external payable;
}

interface IRevenueShare {
    function distribute(
        uint256 agentId,
        address payer,
        uint256 baseAmount,
        address[3] calldata referrers
    ) external payable returns (uint256 distributed);
}

/**
 * @title ServicePayment
 * @notice Handles user -> agent payments with automatic tax + referral splits.
 * @dev Native $ARCHE. Called by users directly or via SDK.
 *      Hardened with ReentrancyGuard + strict CEI ordering.
 */
contract ServicePayment is ReentrancyGuard {
    // Reference the real AgentRegistry contract type directly (no drifting local interface)
    AgentRegistry public immutable registry;
    IAgentTax public immutable tax;
    IRevenueShare public revenueShare;  // Set post-deploy (cyclic dep)
    address public admin;

    uint256 public totalPaymentsProcessed;
    uint256 public totalGrossVolume;

    mapping(address => uint256) public payerLockedStake;

    event ServicePaid(
        uint256 indexed agentId,
        address indexed payer,
        address indexed agentOwner,
        uint256 grossAmount,
        uint256 taxAmount,
        uint256 referralAmount,
        uint256 netToAgent,
        bytes32 requestId
    );

    event PayerStakeLocked(address indexed payer, uint256 amount, uint256 total);
    event PayerStakeUnlocked(address indexed payer, uint256 amount, uint256 remaining);
    event RevenueShareSet(address indexed revenueShare);

    error NotAdmin();
    error InvalidAddress();
    error AgentNotActive();
    error InvalidAmount();
    error TransferFailed();
    error InsufficientLocked();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    constructor(address _registry, address _tax, address _admin) {
        require(_registry != address(0) && _tax != address(0) && _admin != address(0), "Zero addr");
        registry = AgentRegistry(_registry);
        tax = IAgentTax(_tax);
        admin = _admin;
    }

    // === Payment ===

    function payAgent(uint256 agentId, address[3] calldata referrers, bytes32 requestId)
        external
        payable
        nonReentrant
    {
        // --- Checks ---
        if (msg.value == 0) revert InvalidAmount();
        if (!registry.isActive(agentId)) revert AgentNotActive();

        address agentOwner = registry.getAgent(agentId).owner;

        uint256 taxBps = tax.taxRateBps(payerLockedStake[msg.sender]);
        uint256 taxAmount = (msg.value * taxBps) / 10000;

        // Compute referral budget cap (do NOT transfer yet)
        uint256 referralBudget = 0;
        bool hasReferrer =
            referrers[0] != address(0) || referrers[1] != address(0) || referrers[2] != address(0);
        if (address(revenueShare) != address(0) && hasReferrer) {
            uint256 maxReferral = msg.value - taxAmount;
            uint256 attempted = (msg.value * 2000) / 10000; // 20% max
            if (attempted > maxReferral) attempted = maxReferral;
            referralBudget = attempted;
        }

        // --- Effects (update state BEFORE external interactions) ---
        totalPaymentsProcessed += 1;
        totalGrossVolume += msg.value;

        // --- Interactions ---
        // 1. Tax: burn 50% + treasury 50%
        tax.processTax{value: taxAmount}(msg.sender, msg.value);

        // 2. Referral commissions (distribute returns actual amount sent, refunds unused)
        uint256 referralAmount = 0;
        if (referralBudget > 0) {
            referralAmount = revenueShare.distribute{value: referralBudget}(
                agentId,
                msg.sender,
                msg.value,
                referrers
            );
        }

        // 3. Remainder to agent owner
        uint256 netToAgent = msg.value - taxAmount - referralAmount;
        (bool ok,) = agentOwner.call{value: netToAgent}("");
        if (!ok) revert TransferFailed();

        // 4. Update reputation (trusted internal contract)
        registry.recordSuccessfulCall(agentId, netToAgent);

        emit ServicePaid(
            agentId,
            msg.sender,
            agentOwner,
            msg.value,
            taxAmount,
            referralAmount,
            netToAgent,
            requestId
        );
    }

    // === User stake locking (for tax tier discounts) ===

    function lockStake() external payable nonReentrant {
        if (msg.value == 0) revert InvalidAmount();
        payerLockedStake[msg.sender] += msg.value;
        emit PayerStakeLocked(msg.sender, msg.value, payerLockedStake[msg.sender]);
    }

    function unlockStake(uint256 amount) external nonReentrant {
        uint256 current = payerLockedStake[msg.sender];
        if (amount > current) revert InsufficientLocked();

        // Effects before interaction (CEI)
        payerLockedStake[msg.sender] = current - amount;

        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit PayerStakeUnlocked(msg.sender, amount, current - amount);
    }

    // === Admin ===

    function setRevenueShare(address _revenueShare) external onlyAdmin {
        if (_revenueShare == address(0)) revert InvalidAddress();
        revenueShare = IRevenueShare(_revenueShare);
        emit RevenueShareSet(_revenueShare);
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert InvalidAddress();
        admin = newAdmin;
    }
}
