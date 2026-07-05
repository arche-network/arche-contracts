// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {ArcheTreasury} from "../src/ArcheTreasury.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";
import {AgentTax} from "../src/AgentTax.sol";
import {ServicePayment} from "../src/ServicePayment.sol";
import {RevenueShare} from "../src/RevenueShare.sol";

contract ArcheE2ETest is Test {
    ArcheTreasury treasury;
    AgentRegistry registry;
    AgentTax tax;
    ServicePayment servicePayment;
    RevenueShare revenueShare;

    address admin = makeAddr("admin");
    address alice = makeAddr("alice");     // Agent owner
    address bob = makeAddr("bob");         // User
    address carol = makeAddr("carol");     // L1 referrer
    address dave = makeAddr("dave");       // L2 referrer
    address eve = makeAddr("eve");         // L3 referrer

    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    function setUp() public {
        vm.startPrank(admin);

        treasury = new ArcheTreasury(admin);
        registry = new AgentRegistry(admin);

        // Predict ServicePayment address
        uint256 currentNonce = vm.getNonce(admin);
        address predictedServicePayment = vm.computeCreateAddress(admin, currentNonce + 1);

        tax = new AgentTax(address(treasury), predictedServicePayment);
        servicePayment = new ServicePayment(address(registry), address(tax), admin);
        assertEq(address(servicePayment), predictedServicePayment, "Prediction");

        revenueShare = new RevenueShare(address(servicePayment));

        registry.setServicePayment(address(servicePayment));
        servicePayment.setRevenueShare(address(revenueShare));

        vm.stopPrank();

        // Fund test accounts
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 100 ether);
    }

    // === AgentRegistry tests ===

    function testRegisterAgent() public {
        vm.prank(alice);
        uint256 agentId = registry.registerAgent{value: 50 ether}(
            keccak256("gpt-4o"),
            bytes32(0),
            keccak256("You are a helpful DeFi advisor"),
            "ipfs://QmXxx/yieldmax.json"
        );

        assertEq(agentId, 1);
        assertTrue(registry.isActive(agentId));

        AgentRegistry.Agent memory a = registry.getAgent(agentId);
        assertEq(a.owner, alice);
        assertEq(a.stakedAmount, 50 ether);
        assertEq(uint256(a.status), uint256(AgentRegistry.AgentStatus.Active));
    }

    function testRegisterAgentInsufficientStake() public {
        vm.prank(alice);
        vm.expectRevert();
        registry.registerAgent{value: 10 ether}(bytes32("m"), bytes32(0), bytes32("p"), "uri");
    }

    function testIncreaseStake() public {
        vm.prank(alice);
        uint256 agentId = registry.registerAgent{value: 50 ether}(bytes32("m"), bytes32(0), bytes32("p"), "uri");

        vm.prank(alice);
        registry.increaseStake{value: 100 ether}(agentId);

        assertEq(registry.getAgent(agentId).stakedAmount, 150 ether);
    }

    function testAgentTierUpgrade() public {
        vm.startPrank(alice);
        uint256 agentId = registry.registerAgent{value: 50 ether}(bytes32("m"), bytes32(0), bytes32("p"), "uri");
        assertEq(uint256(registry.getAgentTier(agentId)), uint256(AgentRegistry.AgentTier.Base));

        registry.increaseStake{value: 450 ether}(agentId);
        assertEq(uint256(registry.getAgentTier(agentId)), uint256(AgentRegistry.AgentTier.Mid));

        registry.increaseStake{value: 4_500 ether}(agentId);
        assertEq(uint256(registry.getAgentTier(agentId)), uint256(AgentRegistry.AgentTier.High));
        vm.stopPrank();
    }

    // === AgentTax tests ===

    function testTaxRateTiers() public view {
        assertEq(tax.taxRateBps(0), 250);
        assertEq(tax.taxRateBps(1_000 ether), 200);
        assertEq(tax.taxRateBps(10_000 ether), 150);
        assertEq(tax.taxRateBps(100_000 ether), 100);
    }

    // === Full end-to-end payment flow ===

    function testE2E_PaymentWithTaxNoReferrer() public {
        // Alice registers an agent
        vm.prank(alice);
        uint256 agentId = registry.registerAgent{value: 50 ether}(
            keccak256("gpt-4o"),
            bytes32(0),
            keccak256("You are a helpful advisor"),
            "ipfs://QmXxx"
        );

        // Bob pays 10 ARCHE
        uint256 aliceBalanceBefore = alice.balance;
        uint256 treasuryBefore = address(treasury).balance;
        uint256 deadBefore = DEAD.balance;

        address[3] memory noReferrers;
        vm.prank(bob);
        servicePayment.payAgent{value: 10 ether}(agentId, noReferrers, bytes32("req-1"));

        // Alice (agent owner) got: 10 - 2.5% = 9.75 ARCHE
        assertEq(alice.balance, aliceBalanceBefore + 9.75 ether, "Agent net payment");

        // Treasury got: 50% of 2.5% = 1.25% = 0.125 ARCHE
        assertEq(address(treasury).balance, treasuryBefore + 0.125 ether, "Treasury cut");

        // Burn: 50% of 2.5% = 1.25% = 0.125 ARCHE
        assertEq(DEAD.balance, deadBefore + 0.125 ether, "Burn cut");

        // Reputation increased
        assertEq(registry.getAgent(agentId).totalCalls, 1);
        assertGt(registry.getAgent(agentId).reputation, 0);
    }

    function testE2E_PaymentWithReferrers() public {
        vm.prank(alice);
        uint256 agentId = registry.registerAgent{value: 50 ether}(bytes32("m"), bytes32(0), bytes32("p"), "uri");

        uint256 aliceBefore = alice.balance;
        uint256 carolBefore = carol.balance;
        uint256 daveBefore = dave.balance;
        uint256 eveBefore = eve.balance;

        // Bob pays 100 ARCHE, three referrers set
        address[3] memory referrers = [carol, dave, eve];
        vm.prank(bob);
        servicePayment.payAgent{value: 100 ether}(agentId, referrers, bytes32("req-2"));

        // Tax: 2.5 ARCHE (2.5% of 100)
        // Referrals: 10 + 6 + 4 = 20 ARCHE
        // Agent net: 100 - 2.5 - 20 = 77.5 ARCHE
        assertEq(alice.balance, aliceBefore + 77.5 ether, "Agent net");
        assertEq(carol.balance, carolBefore + 10 ether, "L1 referral");
        assertEq(dave.balance, daveBefore + 6 ether, "L2 referral");
        assertEq(eve.balance, eveBefore + 4 ether, "L3 referral");
    }

    function testE2E_PayerStakeLockLowersTax() public {
        vm.prank(alice);
        uint256 agentId = registry.registerAgent{value: 50 ether}(bytes32("m"), bytes32(0), bytes32("p"), "uri");

        // Bob locks 10_000 ARCHE (tier 2 = 1.5%)
        vm.deal(bob, 10_100 ether);
        vm.prank(bob);
        servicePayment.lockStake{value: 10_000 ether}();

        uint256 aliceBefore = alice.balance;

        address[3] memory noReferrers;
        vm.prank(bob);
        servicePayment.payAgent{value: 100 ether}(agentId, noReferrers, bytes32("req-3"));

        // Tax should be 1.5 ARCHE (1.5% of 100)
        // Agent net: 100 - 1.5 = 98.5 ARCHE
        assertEq(alice.balance, aliceBefore + 98.5 ether, "Reduced tax net payment");
    }

    function testE2E_AgentRetireRefundsStake() public {
        vm.prank(alice);
        uint256 agentId = registry.registerAgent{value: 200 ether}(bytes32("m"), bytes32(0), bytes32("p"), "uri");

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        registry.retireAgent(agentId);

        assertEq(alice.balance, aliceBefore + 200 ether, "Full stake refund");
        assertEq(uint256(registry.getAgent(agentId).status), uint256(AgentRegistry.AgentStatus.Retired));
    }

    function testE2E_InactiveAgentCannotBePaid() public {
        vm.prank(alice);
        uint256 agentId = registry.registerAgent{value: 50 ether}(bytes32("m"), bytes32(0), bytes32("p"), "uri");

        vm.prank(alice);
        registry.pauseAgent(agentId);

        address[3] memory noReferrers;
        vm.prank(bob);
        vm.expectRevert();
        servicePayment.payAgent{value: 10 ether}(agentId, noReferrers, bytes32("req-fail"));
    }

    // === Fuzz test ===

    function testFuzz_TaxAlwaysBalanced(uint256 payment) public {
        payment = bound(payment, 1 ether, 1_000_000 ether);

        vm.deal(bob, payment + 100 ether);

        vm.prank(alice);
        uint256 agentId = registry.registerAgent{value: 50 ether}(bytes32("m"), bytes32(0), bytes32("p"), "uri");

        uint256 aliceBefore = alice.balance;
        uint256 treasuryBefore = address(treasury).balance;
        uint256 deadBefore = DEAD.balance;

        address[3] memory noReferrers;
        vm.prank(bob);
        servicePayment.payAgent{value: payment}(agentId, noReferrers, bytes32("fuzz"));

        uint256 aliceGain = alice.balance - aliceBefore;
        uint256 treasuryGain = address(treasury).balance - treasuryBefore;
        uint256 deadGain = DEAD.balance - deadBefore;

        // Sum of splits must equal payment
        assertEq(aliceGain + treasuryGain + deadGain, payment, "Balance conservation");

        // Tax is 2.5% (no lockup)
        uint256 expectedTax = (payment * 250) / 10000;
        assertApproxEqAbs(treasuryGain + deadGain, expectedTax, 1, "Tax total");

        // Treasury and burn are equal (50/50 of tax)
        assertApproxEqAbs(treasuryGain, deadGain, 1, "Tax split");
    }
}
