// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { WithdrawalToken } from "../src/WithdrawalToken.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract WithdrawalTokenTest is Test {
    WithdrawalToken internal token;
    address internal owner = address(0xABCD);
    address internal core = address(0xBEEF);
    error OwnableUnauthorizedAccount(address account);
    address internal user = address(0x1234);

    function setUp() public {
        WithdrawalToken implementation = new WithdrawalToken();
        bytes memory initData = abi.encodeCall(
            WithdrawalToken.initialize, (owner, core, "https://api.example.com/", "WithdrawalToken", "WRT-")
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
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
        vm.expectRevert(WithdrawalToken.OnlyCoreCanMint.selector);
        token.mint(user, 1, 1, "");
    }

    function testBurn() public {
        vm.prank(core);
        token.mint(user, 1, 100, "");
        assertEq(token.balanceOf(user, 1), 100);
        // Owner can burn their own tokens
        vm.prank(user);
        token.burn(user, 1, 40);
        assertEq(token.balanceOf(user, 1), 60);
    }

    function testBurnUnauthorizedReverts() public {
        vm.prank(core);
        token.mint(user, 1, 10, "");
        address attacker = address(0x9999);
        vm.prank(attacker);
        bytes4 selector = bytes4(keccak256("ERC1155MissingApprovalForAll(address,address)"));
        vm.expectRevert(abi.encodeWithSelector(selector, attacker, user));
        token.burn(user, 1, 1);
    }

    function testBurnByApprovedOperator() public {
        vm.prank(core);
        token.mint(user, 1, 50, "");
        address operator = address(0x9999);
        // user approves operator
        vm.prank(user);
        token.setApprovalForAll(operator, true);
        // operator burns on behalf of user
        vm.prank(operator);
        token.burn(user, 1, 25);
        assertEq(token.balanceOf(user, 1), 25);
    }

    function testUpdateCoreAddressByOwner() public {
        address newCore = address(0xDEAD);
        vm.prank(owner);
        token.updateCoreAddress(newCore);
        assertEq(token.coreAddress(), newCore);
    }

    function testUpdateCoreAddressNotOwnerReverts() public {
        address newCore = address(0xDEAD);
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, address(this)));
        token.updateCoreAddress(newCore);
    }
}
