// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { MaxBTCERC20 } from "../src/MaxBTCERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployMaxBTCERC20 is Script {
    function run() external {
        address implementation = vm.envAddress("IMPLEMENTATION");
        address owner = vm.envAddress("OWNER");
        address ics20 = vm.envAddress("ICS20");
        string memory name = vm.envString("TOKEN_NAME");
        string memory symbol = vm.envString("TOKEN_SYMBOL");

        bytes memory initializeCall = abi.encodeCall(MaxBTCERC20.initialize, (owner, ics20, name, symbol));

        vm.startBroadcast();
        ERC1967Proxy proxy = new ERC1967Proxy(implementation, initializeCall);
        vm.stopBroadcast();

        console.log("MaxBTCERC20 address:", address(proxy));
        console.log("Configuration:");
        console.log("  Implementation:     ", implementation);
        console.log("  Owner:              ", owner);
        console.log("  ICS20:              ", ics20);
        console.log("  Name:               ", name);
        console.log("  Symbol:             ", symbol);
    }
}
