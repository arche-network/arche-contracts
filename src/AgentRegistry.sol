// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title AgentRegistry
 * @notice On-chain identity registry for AI agents on Arche.
 * @dev Implements KYA (Know Your Agent) framework based on EIP-8004.
 *      Each agent is minted as a soulbound-ish NFT (transferable but reputation stays).
 *
 * Native $ARCHE stake required. Reputation grows with successful service.
 *
 * Simplified for Testnet Phase 1:
 *   - No W3C DID resolver on-chain (URI points to off-chain resolver)
 *   - No ERC-6551 TBA (added in Phase 2)
 *   - No slashing (added in Phase 2 with Guardrail Nodes)
 */
contract AgentRegistry {
    // === Constants ===

    uint256 public constant MIN_STAKE = 50 ether;      // 50 ARCHE base tier
    uint256 public constant MID_STAKE = 500 ether;     // 500 ARCHE mid tier
    uint256 public constant HIGH_STAKE = 5_000 ether;  // 5000 ARCHE high tier
    uint256 public constant FLAGSHIP_STAKE = 50_000 ether; // 50k ARCHE flagship

    // === Types ===

    enum AgentStatus { None, Active, Paused, Retired }
    enum AgentTier { Base, Mid, High, Flagship }

    struct Agent {
        address owner;             // Who owns / can update this agent
        bytes32 modelHash;         // Cryptographic fingerprint of base model
        bytes32 weightsHash;       // Fingerprint of fine-tuning weights (0 if base model)
        bytes32 systemPromptHash;  // System prompt fingerprint
        string  metadataURI;       // Off-chain metadata (name, description, category, DID, MCP endpoint)
        uint256 stakedAmount;      // Native $ARCHE staked
        uint256 reputation;        // Reputation score (accumulates)
        uint256 totalEarned;       // Lifetime earnings (net of tax)
        uint256 totalCalls;        // Number of successful service calls
        uint256 registeredAt;      // Registration timestamp
        AgentStatus status;
    }

    // === State ===

    uint256 public nextAgentId = 1;
    mapping(uint256 => Agent) public agents;
    mapping(address => uint256[]) public ownerAgents;
    address public servicePayment;  // Trusted contract that can update reputation
    address public admin;

    // === Events ===

    event AgentRegistered(uint256 indexed agentId, address indexed owner, bytes32 modelHash, uint256 stake);
    event AgentUpdated(uint256 indexed agentId, string metadataURI);
    event AgentStakeIncreased(uint256 indexed agentId, uint256 amount, uint256 newTotal);
    event AgentStakeWithdrawn(uint256 indexed agentId, uint256 amount, uint256 newTotal);
    event AgentPaused(uint256 indexed agentId);
    event AgentResumed(uint256 indexed agentId);
    event AgentRetired(uint256 indexed agentId, uint256 refundedStake);
    event AgentTransferred(uint256 indexed agentId, address indexed from, address indexed to);
    event ReputationIncreased(uint256 indexed agentId, uint256 amount, uint256 newTotal);
    event ServicePaymentSet(address indexed servicePayment);

    // === Errors ===

    error InsufficientStake(uint256 provided, uint256 required);
    error AgentNotFound();
    error NotAgentOwner();
    error AgentNotActive();
    error AlreadyPaused();
    error TransferFailed();
    error NotAdmin();
    error NotServicePayment();
    error InvalidAddress();
    error CannotWithdrawBelowMin();

    // === Modifiers ===

    modifier onlyAgentOwner(uint256 agentId) {
        if (agents[agentId].owner != msg.sender) revert NotAgentOwner();
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    modifier agentExists(uint256 agentId) {
        if (agents[agentId].status == AgentStatus.None) revert AgentNotFound();
        _;
    }

    // === Constructor ===

    constructor(address _admin) {
        if (_admin == address(0)) revert InvalidAddress();
        admin = _admin;
    }

    // === Registration ===

    /**
     * @notice Register a new agent. Requires MIN_STAKE $ARCHE as msg.value.
     * @param modelHash Hash of the base AI model (e.g., GPT-4, Claude, DeepSeek)
     * @param weightsHash Hash of fine-tuning weights (bytes32(0) if base model)
     * @param systemPromptHash Hash of system prompt
     * @param metadataURI URI pointing to off-chain metadata JSON
     * @return agentId The newly assigned agent ID
     */
    function registerAgent(
        bytes32 modelHash,
        bytes32 weightsHash,
        bytes32 systemPromptHash,
        string calldata metadataURI
    ) external payable returns (uint256 agentId) {
        if (msg.value < MIN_STAKE) revert InsufficientStake(msg.value, MIN_STAKE);

        agentId = nextAgentId++;

        agents[agentId] = Agent({
            owner: msg.sender,
            modelHash: modelHash,
            weightsHash: weightsHash,
            systemPromptHash: systemPromptHash,
            metadataURI: metadataURI,
            stakedAmount: msg.value,
            reputation: 0,
            totalEarned: 0,
            totalCalls: 0,
            registeredAt: block.timestamp,
            status: AgentStatus.Active
        });

        ownerAgents[msg.sender].push(agentId);

        emit AgentRegistered(agentId, msg.sender, modelHash, msg.value);
    }

    /**
     * @notice Update off-chain metadata URI. Owner only.
     */
    function updateMetadata(uint256 agentId, string calldata newMetadataURI)
        external
        agentExists(agentId)
        onlyAgentOwner(agentId)
    {
        agents[agentId].metadataURI = newMetadataURI;
        emit AgentUpdated(agentId, newMetadataURI);
    }

    /**
     * @notice Increase stake to unlock higher tier / better routing priority.
     */
    function increaseStake(uint256 agentId) external payable agentExists(agentId) onlyAgentOwner(agentId) {
        if (msg.value == 0) revert InsufficientStake(0, 1);
        agents[agentId].stakedAmount += msg.value;
        emit AgentStakeIncreased(agentId, msg.value, agents[agentId].stakedAmount);
    }

    /**
     * @notice Withdraw part of stake. Cannot go below MIN_STAKE while active.
     */
    function withdrawStake(uint256 agentId, uint256 amount)
        external
        agentExists(agentId)
        onlyAgentOwner(agentId)
    {
        Agent storage a = agents[agentId];
        uint256 newStake = a.stakedAmount - amount; // reverts on underflow
        if (a.status == AgentStatus.Active && newStake < MIN_STAKE) {
            revert CannotWithdrawBelowMin();
        }
        a.stakedAmount = newStake;

        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit AgentStakeWithdrawn(agentId, amount, newStake);
    }

    /**
     * @notice Pause agent temporarily. Owner only. Stops receiving calls.
     */
    function pauseAgent(uint256 agentId) external agentExists(agentId) onlyAgentOwner(agentId) {
        Agent storage a = agents[agentId];
        if (a.status != AgentStatus.Active) revert AlreadyPaused();
        a.status = AgentStatus.Paused;
        emit AgentPaused(agentId);
    }

    function resumeAgent(uint256 agentId) external agentExists(agentId) onlyAgentOwner(agentId) {
        Agent storage a = agents[agentId];
        require(a.status == AgentStatus.Paused, "Not paused");
        a.status = AgentStatus.Active;
        emit AgentResumed(agentId);
    }

    /**
     * @notice Permanently retire agent and reclaim all staked $ARCHE.
     */
    function retireAgent(uint256 agentId) external agentExists(agentId) onlyAgentOwner(agentId) {
        Agent storage a = agents[agentId];
        require(a.status != AgentStatus.Retired, "Already retired");

        uint256 refund = a.stakedAmount;
        a.stakedAmount = 0;
        a.status = AgentStatus.Retired;

        (bool ok,) = msg.sender.call{value: refund}("");
        if (!ok) revert TransferFailed();

        emit AgentRetired(agentId, refund);
    }

    /**
     * @notice Transfer agent ownership. Reputation stays with the agent.
     */
    function transferAgent(uint256 agentId, address newOwner)
        external
        agentExists(agentId)
        onlyAgentOwner(agentId)
    {
        if (newOwner == address(0)) revert InvalidAddress();
        address prev = agents[agentId].owner;
        agents[agentId].owner = newOwner;
        ownerAgents[newOwner].push(agentId);
        emit AgentTransferred(agentId, prev, newOwner);
    }

    // === Reputation (called by ServicePayment) ===

    /**
     * @notice Record a successful service call. Increases reputation.
     * @dev Only callable by trusted ServicePayment contract.
     */
    function recordSuccessfulCall(uint256 agentId, uint256 earnedAmount)
        external
        agentExists(agentId)
    {
        if (msg.sender != servicePayment) revert NotServicePayment();

        Agent storage a = agents[agentId];
        a.totalCalls += 1;
        a.totalEarned += earnedAmount;

        // Simple reputation model: +1 per call, +1 per 1 ARCHE earned
        uint256 repDelta = 1 + (earnedAmount / 1 ether);
        a.reputation += repDelta;

        emit ReputationIncreased(agentId, repDelta, a.reputation);
    }

    // === Views ===

    function getAgent(uint256 agentId) external view returns (Agent memory) {
        return agents[agentId];
    }

    function getAgentTier(uint256 agentId) external view returns (AgentTier) {
        uint256 stake = agents[agentId].stakedAmount;
        if (stake >= FLAGSHIP_STAKE) return AgentTier.Flagship;
        if (stake >= HIGH_STAKE) return AgentTier.High;
        if (stake >= MID_STAKE) return AgentTier.Mid;
        return AgentTier.Base;
    }

    function isActive(uint256 agentId) external view returns (bool) {
        return agents[agentId].status == AgentStatus.Active;
    }

    function agentsOwnedBy(address who) external view returns (uint256[] memory) {
        return ownerAgents[who];
    }

    function totalAgents() external view returns (uint256) {
        return nextAgentId - 1;
    }

    // === Admin ===

    function setServicePayment(address _servicePayment) external onlyAdmin {
        if (_servicePayment == address(0)) revert InvalidAddress();
        servicePayment = _servicePayment;
        emit ServicePaymentSet(_servicePayment);
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert InvalidAddress();
        admin = newAdmin;
    }
}
