// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {WithdrawalToken} from "../src/WithdrawalToken.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract WithdrawalTokenTest is Test {
    WithdrawalToken internal token;
    address internal owner = address(0xABCD);
    address internal core = address(0xBEEF);
    address internal user = address(0x1234);

    function setUp() public {
        WithdrawalToken implementation = new WithdrawalToken();
        bytes memory initData = abi.encodeCall(
            WithdrawalToken.initialize,
            (owner, core, "https://api.example.com/", "WithdrawalToken", "WRT-")
        );
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            initData
        );
        token = WithdrawalToken(address(proxy));
        // Ownership is set to `owner` in initialize, so we need to prank as owner for owner-only functions
    }

    function testNameAndSymbol() public view {
        assertEq(token.name(), "WithdrawalToken");
        assertEq(token.symbol(1), "WRT-1");
    }

    function testMintByCore() public {
        vm.prank(core);
        token.mint(user, 1, 100, "");
        assertEq(token.balanceOf(user, 1), 100);
    }

    function testMintNotCoreReverts() public {
        vm.expectRevert(WithdrawalToken.OnlyCoreCanMintOrBurn.selector);
        token.mint(user, 1, 1, "");
    }

    function testBurnByCore() public {
        vm.prank(core);
        token.mint(user, 1, 100, "");
        assertEq(token.balanceOf(user, 1), 100);
        // Only core can burn
        vm.prank(core);
        token.burn(user, 1, 40);
        assertEq(token.balanceOf(user, 1), 60);
    }

    function testBurnNotCoreReverts() public {
        vm.prank(core);
        token.mint(user, 1, 100, "");
        vm.prank(user);
        vm.expectRevert(WithdrawalToken.OnlyCoreCanMintOrBurn.selector);
        token.burn(user, 1, 10);
    }
}
