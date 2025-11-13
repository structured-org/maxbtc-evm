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
    address internal user = address(0x1234);

    function setUp() public {
        WithdrawalToken implementation = new WithdrawalToken();
        bytes memory initData = abi.encodeCall(
            WithdrawalToken.initialize,
            (owner, "https://api.example.com/", "WithdrawalToken")
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

    function testMintByOwner() public {
        vm.prank(owner);
        token.mint(user, 1, 100, "");
        assertEq(token.balanceOf(user, 1), 100);
    }

    function testMintBatchByOwner() public {
        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        amounts[0] = 50;
        amounts[1] = 150;
        vm.prank(owner);
        token.mintBatch(user, ids, amounts, "");
        assertEq(token.balanceOf(user, 1), 50);
        assertEq(token.balanceOf(user, 2), 150);
    }

    function testMintNotOwnerReverts() public {
        vm.expectRevert(
            abi.encodeWithSignature(
                "OwnableUnauthorizedAccount(address)",
                address(this)
            )
        );
        token.mint(user, 1, 1, "");
    }

    function testMintBatchNotOwnerReverts() public {
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = 1;
        amounts[0] = 1;
        vm.expectRevert(
            abi.encodeWithSignature(
                "OwnableUnauthorizedAccount(address)",
                address(this)
            )
        );
        token.mintBatch(user, ids, amounts, "");
    }
    function testBurnByOwner() public {
        vm.prank(owner);
        token.mint(user, 1, 100, "");
        assertEq(token.balanceOf(user, 1), 100);
        vm.prank(user);
        token.burn(user, 1, 40);
        assertEq(token.balanceOf(user, 1), 60);
    }

    function testBurnBatchByOwner() public {
        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        amounts[0] = 50;
        amounts[1] = 150;
        vm.prank(owner);
        token.mintBatch(user, ids, amounts, "");
        assertEq(token.balanceOf(user, 1), 50);
        assertEq(token.balanceOf(user, 2), 150);
        uint256[] memory burnAmounts = new uint256[](2);
        burnAmounts[0] = 10;
        burnAmounts[1] = 100;
        vm.prank(user);
        token.burnBatch(user, ids, burnAmounts);
        assertEq(token.balanceOf(user, 1), 40);
        assertEq(token.balanceOf(user, 2), 50);
    }

    function testBurnNotOwnerOrApprovedReverts() public {
        vm.prank(owner);
        token.mint(user, 1, 100, "");
        address attacker = address(0xBEEF);
        vm.prank(attacker);
        vm.expectRevert();
        token.burn(user, 1, 10);
    }

    function testBurnBatchNotOwnerOrApprovedReverts() public {
        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        amounts[0] = 50;
        amounts[1] = 150;
        vm.prank(owner);
        token.mintBatch(user, ids, amounts, "");
        address attacker = address(0xBEEF);
        uint256[] memory burnAmounts = new uint256[](2);
        burnAmounts[0] = 10;
        burnAmounts[1] = 100;
        vm.prank(attacker);
        vm.expectRevert();
        token.burnBatch(user, ids, burnAmounts);
    }
}
