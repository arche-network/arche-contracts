// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title ArcheToken ($ARCHE)
 * @notice The native gas token for the Arche AI Agent Layer 2.
 * @dev Standard, clean ERC-20 built for use as an OP Stack custom gas token.
 *
 *      Gas-token compliance (OP Stack custom gas token spec):
 *        - Standard ERC-20 interface (OpenZeppelin, no proxy)   OK
 *        - Exactly 18 decimals (OZ ERC20 default)               OK
 *        - name "Arche" / symbol "ARCHE" both < 32 bytes        OK
 *        - No rebasing, no transfer fee, no transfer hooks       OK
 *        - Deployed on L1 (Sepolia) as required                 OK
 *
 *      Total supply: 1,000,000,000 ARCHE (1B), minted once to deployer.
 */
contract ArcheToken is ERC20 {
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 ether; // 1B * 1e18

    constructor(address initialHolder) ERC20("Arche", "ARCHE") {
        require(initialHolder != address(0), "Zero holder");
        _mint(initialHolder, INITIAL_SUPPLY);
    }
}
