// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ArcheTreasury} from "../src/ArcheTreasury.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";
import {AgentTax} from "../src/AgentTax.sol";
import {ServicePayment} from "../src/ServicePayment.sol";
import {RevenueShare} from "../src/RevenueShare.sol";

/**
 * @title DeployArche
 * @notice One-click deployment of all Arche Phase 1 contracts.
 *
 * Deployment order:
 *   1. ArcheTreasury  (owner = deployer for now, transfer to multisig later)
 *   2. AgentRegistry  (admin = deployer)
 *   3. Predict ServicePayment address via nonce
 *   4. AgentTax       (treasury + predicted ServicePayment)
 *   5. ServicePayment (registry + tax)
 *   6. RevenueShare   (servicePayment)
 *   7. Wire up:
 *      - registry.setServicePayment(servicePayment)
 *      - servicePayment.setRevenueShare(revenueShare)
 *
 * Usage:
 *   forge script script/DeployArche.s.sol \
 *       --rpc-url $RPC_URL \
 *       --broadcast \
 *       --verify
 */
contract DeployArche is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        console.log("========================================");
        console.log("Arche Phase 1 Deployment");
        console.log("Deployer:", deployer);
        console.log("Balance :", deployer.balance);
        console.log("========================================");

        vm.startBroadcast(deployerKey);

        // 1. Treasury
        ArcheTreasury treasury = new ArcheTreasury(deployer);
        console.log("ArcheTreasury  ", address(treasury));

        // 2. Registry
        AgentRegistry registry = new AgentRegistry(deployer);
        console.log("AgentRegistry  ", address(registry));

        // 3. Predict ServicePayment address (nonce + 2 from here)
        // Next nonce = current, then AgentTax will use current, then ServicePayment = current + 1
        uint256 currentNonce = vm.getNonce(deployer);
        address predictedServicePayment = vm.computeCreateAddress(deployer, currentNonce + 1);
        console.log("Predicted ServicePayment:", predictedServicePayment);

        // 4. AgentTax
        AgentTax tax = new AgentTax(address(treasury), predictedServicePayment);
        console.log("AgentTax       ", address(tax));

        // 5. ServicePayment
        ServicePayment servicePayment = new ServicePayment(
            address(registry),
            address(tax),
            deployer
        );
        console.log("ServicePayment ", address(servicePayment));
        require(address(servicePayment) == predictedServicePayment, "Prediction mismatch");

        // 6. RevenueShare
        RevenueShare revenueShare = new RevenueShare(address(servicePayment));
        console.log("RevenueShare   ", address(revenueShare));

        // 7. Wire up
        registry.setServicePayment(address(servicePayment));
        servicePayment.setRevenueShare(address(revenueShare));

        vm.stopBroadcast();

        console.log("========================================");
        console.log("Deployment complete!");
        console.log("========================================");
        console.log("");
        console.log("Save these addresses:");
        console.log("");
        console.log("ARCHE_TREASURY=%s", address(treasury));
        console.log("ARCHE_REGISTRY=%s", address(registry));
        console.log("ARCHE_TAX=%s", address(tax));
        console.log("ARCHE_SERVICE_PAYMENT=%s", address(servicePayment));
        console.log("ARCHE_REVENUE_SHARE=%s", address(revenueShare));
    }
}
