// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MaxBTCERC20} from "../src/MaxBTCERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MaxBTCERC20Test is Test {
    address private constant OWNER = address(1);
    address private constant ICS20 = address(2);
    address private constant CORE = address(3);
    address private constant ESCROW = address(4);

    MaxBTCERC20 private maxBtcErc20;

    function setUp() external {
        MaxBTCERC20 implementation = new MaxBTCERC20();
        bytes memory maxBTCERC20InitializeCall = abi.encodeCall(
            MaxBTCERC20.initialize,
            (OWNER, ICS20, "Structured maxBTC", "maxBTC")
        );
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            maxBTCERC20InitializeCall
        );
        maxBtcErc20 = MaxBTCERC20(address(proxy));
        maxBtcErc20.initializeV2(CORE);
    }

    function testMintSuccess() external {
        vm.startPrank(CORE);
        maxBtcErc20.mint(ESCROW, 100);
        assertEq(maxBtcErc20.balanceOf(ESCROW), 100);
    }

    function testMintUnauthorized() external {
        vm.startPrank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                MaxBTCERC20.CallerIsNotAllowed.selector,
                OWNER
            )
        );
        maxBtcErc20.mint(ESCROW, 100);
    }

    function testBurnSuccess() external {
        vm.startPrank(CORE);
        maxBtcErc20.mint(ESCROW, 100);
        maxBtcErc20.burn(ESCROW, 20);
        assertEq(maxBtcErc20.balanceOf(ESCROW), 80);
    }

    function testBurnUnauthorized() external {
        vm.startPrank(CORE);
        maxBtcErc20.mint(ESCROW, 100);
        vm.startPrank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                MaxBTCERC20.CallerIsNotAllowed.selector,
                OWNER
            )
        );
        maxBtcErc20.burn(ESCROW, 20);
    }

    function testMintSuccessRateLimited() external {
        vm.startPrank(OWNER);
        maxBtcErc20.setEurekaRateLimits(100, 0);
        vm.startPrank(ICS20);
        maxBtcErc20.mint(ESCROW, 100);
        assertEq(maxBtcErc20.balanceOf(ESCROW), 100);
    }

    function testMintFailureRateLimited() external {
        vm.startPrank(OWNER);
        maxBtcErc20.setEurekaRateLimits(100, 0);
        vm.startPrank(ICS20);
        vm.expectRevert(
            abi.encodeWithSelector(
                MaxBTCERC20.EurekaRateLimitsExceeded.selector,
                120,
                100
            )
        );
        maxBtcErc20.mint(ESCROW, 120);
    }

        function testBurnSuccessRateLimited() external {
        vm.startPrank(CORE);
        maxBtcErc20.mint(ESCROW, 100);
        vm.startPrank(OWNER);
        maxBtcErc20.setEurekaRateLimits(0, 100);
        vm.startPrank(ICS20);
        maxBtcErc20.burn(ESCROW, 20);
        assertEq(maxBtcErc20.balanceOf(ESCROW), 80);
    }

    function testBurnFailureRateLimited() external {
        vm.startPrank(CORE);
        maxBtcErc20.mint(ESCROW, 100);
        vm.startPrank(OWNER);
        maxBtcErc20.setEurekaRateLimits(0, 100);
        vm.startPrank(ICS20);
        vm.expectRevert(
            abi.encodeWithSelector(
                MaxBTCERC20.EurekaRateLimitsExceeded.selector,
                120,
                100
            )
        );
        maxBtcErc20.burn(ESCROW, 120);
    }
}
