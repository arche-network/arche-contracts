// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAgentRegistry {
    function getAgent(uint256 agentId) external view returns (
        address owner,
        bytes32 modelHash,
        bytes32 weightsHash,
        bytes32 systemPromptHash,
        string memory metadataURI,
        uint256 stakedAmount,
        uint256 reputation,
        uint256 totalEarned,
        uint256 totalCalls,
        uint256 registeredAt,
        uint8 status
    );
    function isActive(uint256 agentId) external view returns (bool);
    function recordSuccessfulCall(uint256 agentId, uint256 earnedAmount) external;
}

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
 *
 * Payment flow:
 *   User pays gross amount.
 *   Tax (2.5% default) computed and sent to AgentTax (50% burn + 50% treasury).
 *   Optional referral commissions (10%/6%/4%) sent via RevenueShare.
 *   Remainder goes to agent owner.
 *   AgentRegistry updates reputation.
 */
contract ServicePayment {
    IAgentRegistry public immutable registry;
    IAgentTax public immutable tax;
    IRevenueShare public revenueShare;  // Set post-deploy (cyclic dep)
    address public admin;

    // Statistics
    uint256 public totalPaymentsProcessed;
    uint256 public totalGrossVolume;

    // Payer's locked stake for tax tier calculation (kept simple for Phase 1)
    // In Phase 2: read from staking contract with lock periods
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
        registry = IAgentRegistry(_registry);
        tax = IAgentTax(_tax);
        admin = _admin;
    }

    // === Payment ===

    /**
     * @notice Pay an agent for service. msg.value is gross amount.
     * @param agentId Target agent
     * @param referrers Up to 3 referrers for L1/L2/L3 commissions (address(0) for none)
     * @param requestId Off-chain request identifier for tracking
     */
    function payAgent(uint256 agentId, address[3] calldata referrers, bytes32 requestId)
        external
        payable
    {
        if (msg.value == 0) revert InvalidAmount();
        if (!registry.isActive(agentId)) revert AgentNotActive();

        // Get agent owner
        (address agentOwner,,,,,,,,,,) = registry.getAgent(agentId);

        // Compute tax
        uint256 taxBps = tax.taxRateBps(payerLockedStake[msg.sender]);
        uint256 taxAmount = (msg.value * taxBps) / 10000;

        // Send tax to AgentTax (which burns 50% + sends 50% to treasury)
        tax.processTax{value: taxAmount}(msg.sender, msg.value);

        // Compute referral commissions (10% / 6% / 4% of gross = 20% total max)
        uint256 referralAmount = 0;
        if (address(revenueShare) != address(0)) {
            // baseAmount for referrals = gross (not net) so we're honest about split
            // But we cap at msg.value - taxAmount to avoid over-spending
            uint256 maxReferral = msg.value - taxAmount;
            uint256 attempted = (msg.value * 2000) / 10000; // 20% max
            if (attempted > maxReferral) attempted = maxReferral;

            if (attempted > 0 && (referrers[0] != address(0) || referrers[1] != address(0) || referrers[2] != address(0))) {
                referralAmount = revenueShare.distribute{value: attempted}(
                    agentId,
                    msg.sender,
                    msg.value,
                    referrers
                );
            }
        }

        // Remainder to agent owner
        uint256 netToAgent = msg.value - taxAmount - referralAmount;
        (bool ok,) = agentOwner.call{value: netToAgent}("");
        if (!ok) revert TransferFailed();

        // Update reputation
        registry.recordSuccessfulCall(agentId, netToAgent);

        // Stats
        totalPaymentsProcessed += 1;
        totalGrossVolume += msg.value;

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

    /**
     * @notice Lock $ARCHE to qualify for lower tax tier.
     * @dev Simplified for Phase 1: no time lock, can unlock anytime.
     *      Phase 2: add lock periods (30/90/180 days).
     */
    function lockStake() external payable {
        if (msg.value == 0) revert InvalidAmount();
        payerLockedStake[msg.sender] += msg.value;
        emit PayerStakeLocked(msg.sender, msg.value, payerLockedStake[msg.sender]);
    }

    function unlockStake(uint256 amount) external {
        uint256 current = payerLockedStake[msg.sender];
        if (amount > current) revert InsufficientLocked();
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
