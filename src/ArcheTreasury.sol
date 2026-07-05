// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ArcheTreasury
 * @notice Central treasury for Arche ecosystem.
 * @dev Receives Agent Runtime Tax portion (50%) and gas rewards.
 *      Native $ARCHE flows in via receive() and sent to ecosystem uses.
 *      DAO-governed spending in Phase 2. Initially controlled by owner (multisig).
 */
contract ArcheTreasury {
    address public owner;
    address public pendingOwner;

    // Statistics
    uint256 public totalTaxReceived;
    uint256 public totalGrantsPaid;
    uint256 public totalRewardsPaid;

    event TaxReceived(address indexed from, uint256 amount);
    event GrantPaid(address indexed to, uint256 amount, string reason);
    event RewardPaid(address indexed to, uint256 amount, string reason);
    event OwnershipTransferInitiated(address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOwner();
    error NotPendingOwner();
    error TransferFailed();
    error InvalidAddress();
    error InsufficientBalance();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address _owner) {
        if (_owner == address(0)) revert InvalidAddress();
        owner = _owner;
    }

    /// @notice Receive native $ARCHE from AgentTax or direct transfers
    receive() external payable {
        totalTaxReceived += msg.value;
        emit TaxReceived(msg.sender, msg.value);
    }

    /// @notice Pay a developer grant in native $ARCHE
    function payGrant(address to, uint256 amount, string calldata reason) external onlyOwner {
        if (to == address(0)) revert InvalidAddress();
        if (address(this).balance < amount) revert InsufficientBalance();

        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();

        totalGrantsPaid += amount;
        emit GrantPaid(to, amount, reason);
    }

    /// @notice Reward top agents / validators
    function payReward(address to, uint256 amount, string calldata reason) external onlyOwner {
        if (to == address(0)) revert InvalidAddress();
        if (address(this).balance < amount) revert InsufficientBalance();

        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();

        totalRewardsPaid += amount;
        emit RewardPaid(to, amount, reason);
    }

    // === Two-step ownership transfer (safer than one-step) ===

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferInitiated(newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address previousOwner = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(previousOwner, owner);
    }

    /// @notice Current $ARCHE balance held by treasury
    function balance() external view returns (uint256) {
        return address(this).balance;
    }
}
