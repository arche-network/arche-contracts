// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ArcheToken} from "../src/ArcheToken.sol";

contract ArcheTokenTest is Test {
    ArcheToken token;
    address holder = makeAddr("holder");

    function setUp() public {
        token = new ArcheToken(holder);
    }

    // --- Gas-token compliance checks ---

    function testDecimalsExactly18() public view {
        assertEq(token.decimals(), 18, "gas token must have exactly 18 decimals");
    }

    function testNameUnder32Bytes() public view {
        assertLt(bytes(token.name()).length, 32, "name must be < 32 bytes");
        assertEq(token.name(), "Arche");
    }

    function testSymbolUnder32Bytes() public view {
        assertLt(bytes(token.symbol()).length, 32, "symbol must be < 32 bytes");
        assertEq(token.symbol(), "ARCHE");
    }

    // --- Supply checks ---

    function testTotalSupplyIsOneBillion() public view {
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function testInitialHolderGetsFullSupply() public view {
        assertEq(token.balanceOf(holder), 1_000_000_000 ether);
    }

    function testInitialSupplyConstant() public view {
        assertEq(token.INITIAL_SUPPLY(), 1_000_000_000 ether);
    }

    // --- Standard ERC-20 behavior (no fee, no rebase) ---

    function testTransferNoFee() public {
        vm.prank(holder);
        token.transfer(address(0xBEEF), 100 ether);
        // Recipient gets exactly 100, no fee skimmed
        assertEq(token.balanceOf(address(0xBEEF)), 100 ether);
        assertEq(token.balanceOf(holder), 1_000_000_000 ether - 100 ether);
    }

    function testApproveAndTransferFrom() public {
        vm.prank(holder);
        token.approve(address(this), 50 ether);
        token.transferFrom(holder, address(0xCAFE), 50 ether);
        assertEq(token.balanceOf(address(0xCAFE)), 50 ether);
    }

    // --- Constructor guard ---

    function testConstructorRejectsZeroHolder() public {
        vm.expectRevert("Zero holder");
        new ArcheToken(address(0));
    }
}
