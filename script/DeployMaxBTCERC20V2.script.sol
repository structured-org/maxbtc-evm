// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {MaxBTCERC20} from "../src/MaxBTCERC20.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployMaxBTCERC20 is Script {
    function run() external {
        address proxy = vm.envAddress("PROXY");
        address newImplementation = vm.envAddress("NEW_IMPLEMENTATION");
        address core = vm.envAddress("CORE");

        bytes memory initializeV2Call = abi.encodeCall(
            MaxBTCERC20.initializeV2,
            (core)
        );

        MaxBTCERC20 maxBTC = MaxBTCERC20(proxy);

        vm.startBroadcast();
        maxBTC.upgradeToAndCall(newImplementation, initializeV2Call);
        vm.stopBroadcast();

        console.log("New configuration:");
        console.log("  New implementation: ", newImplementation);
        console.log("  Core:               ", core);
    }
}
