// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import "../src/WaitosaurHolder.sol" as waitosaurSrc;
import {WaitosaurBase, WaitosaurAccess} from "../src/WaitosaurBase.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MockERC20 {
    string public name = "MockToken";
    string public symbol = "MTK";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address user => uint256 amount) private _balanceOf;

    // For compatibility with Waitosaur's low-level call and for direct access
    function balanceOf(address user) external view returns (uint256) {
        return _balanceOf[user];
    }

    mapping(address owner => mapping(address spender => uint256 amount))
        public allowance;

    error InsufficientBalance();
    error InsufficientAllowance();

    function burn(address from, uint256 amount) external {
        if (_balanceOf[from] < amount) revert InsufficientBalance();
        _balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (_balanceOf[msg.sender] < amount) revert InsufficientBalance();
        _balanceOf[msg.sender] -= amount;
        _balanceOf[to] += amount;
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        if (_balanceOf[from] < amount) revert InsufficientBalance();
        if (allowance[from][msg.sender] < amount) {
            revert InsufficientAllowance();
        }
        _balanceOf[from] -= amount;
        _balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        return true;
    }

    function mint(address to, uint256 amount) external {
        _balanceOf[to] += amount;
        totalSupply += amount;
    }
}

contract WaitosaurHolderTest is Test {
    waitosaurSrc.WaitosaurHolder public waitosaur;
    MockERC20 public token;
    address public owner = address(0x1);
    address public locker = address(0x2);
    address public unLocker = address(0x3);
    address public receiver = address(0x4);
    address public user = address(0x5);

    function setUp() public {
        token = new MockERC20();
        // Deploy logic contract
        waitosaurSrc.WaitosaurHolder logic = new waitosaurSrc.WaitosaurHolder();
        // Prepare initializer data
        bytes memory data = abi.encodeWithSelector(
            waitosaurSrc.WaitosaurHolder.initialize.selector,
            owner,
            address(token),
            locker,
            unLocker,
            receiver
        );
        // Deploy proxy with initializer
        ERC1967Proxy proxy = new ERC1967Proxy(address(logic), data);
        waitosaur = waitosaurSrc.WaitosaurHolder(address(proxy));
        token.mint(address(waitosaur), 1000 ether);
    }

    function testLockAndUnlockTransfersToReceiver() public {
        vm.prank(locker);
        waitosaur.lock(100 ether);
        assertEq(token.balanceOf(address(waitosaur)), 1000 ether);
        assertEq(token.balanceOf(receiver), 0);
        assertEq(waitosaur.unlocked(), false);

        vm.prank(unLocker);
        waitosaur.unlock();
        assertEq(token.balanceOf(receiver), 100 ether);
        assertEq(token.balanceOf(address(waitosaur)), 900 ether);
    }

    function testLastLockedIsSetOnLock() public {
        vm.prank(locker);
        uint256 before = block.timestamp;
        waitosaur.lock(100 ether);
        uint256 lockedTs = waitosaur.lastLocked();
        // Should be >= before and <= now
        assertGe(lockedTs, before);
        assertLe(lockedTs, block.timestamp);
    }

    function testUnlockFailsIfLowBalance() public {
        vm.prank(locker);
        waitosaur.lock(100 ether);
        // Burn funds from contract to simulate low balance
        token.burn(address(waitosaur), 1000 ether);
        vm.prank(unLocker);
        vm.expectRevert(
            abi.encodeWithSelector(
                WaitosaurBase.InsufficientAssetAmount.selector
            )
        );
        waitosaur.unlock();
    }

    function testOwnerCanUpdateConfig() public {
        address newLocker = address(0x10);
        address newUnLocker = address(0x11);
        address newReceiver = address(0x12);
        vm.prank(owner);
        waitosaur.updateRoles(newLocker, newUnLocker);
        vm.prank(owner);
        waitosaur.updateConfig(newReceiver);
        (address tokenAddr, address receiverAddr) = (
            waitosaur.getConfig().token,
            waitosaur.getConfig().receiver
        );
        WaitosaurAccess memory roles = waitosaur.getRoles();
        assertEq(roles.locker, newLocker);
        assertEq(roles.unlocker, newUnLocker);
        assertEq(receiverAddr, newReceiver);
        assertEq(tokenAddr, address(token));
    }

    function testNonOwnerCannotUpdateConfig() public {
        address newReceiver = address(0x12);
        vm.prank(locker);
        vm.expectRevert(
            abi.encodeWithSignature(
                "OwnableUnauthorizedAccount(address)",
                locker
            )
        );
        waitosaur.updateConfig(newReceiver);
    }

    function testUpdateConfigZeroAddressesRevert() public {
        vm.prank(owner);
        vm.expectRevert(
            waitosaurSrc.WaitosaurHolder.InvalidReceiverAddress.selector
        );
        waitosaur.updateConfig(address(0));

        vm.prank(owner);
        vm.expectRevert(WaitosaurBase.InvalidRolesAddresses.selector);
        waitosaur.updateRoles(address(0), address(0));
    }

    function testConfigUpdatedEventEmitted() public {
        address newLocker = address(0x20);
        address newUnLocker = address(0x21);
        address newReceiver = address(0x22);
        vm.prank(owner);
        vm.expectEmit(true, true, true, true, address(waitosaur));
        emit WaitosaurBase.RolesUpdated(
            WaitosaurAccess({locker: newLocker, unlocker: newUnLocker})
        );
        waitosaur.updateRoles(newLocker, newUnLocker);

        vm.prank(owner);
        vm.expectEmit(true, true, true, true, address(waitosaur));
        emit waitosaurSrc.WaitosaurHolder.ConfigUpdated(
            waitosaurSrc.WaitosaurHolderConfig({
                token: address(token),
                receiver: newReceiver
            })
        );
        waitosaur.updateConfig(newReceiver);
    }

    function testUpdateConfigRevertsWhenLocked() public {
        vm.prank(locker);
        waitosaur.lock(1 ether);

        vm.prank(owner);
        vm.expectRevert(
            waitosaurSrc.WaitosaurHolder.ConfigCantBeUpdatedWhenLocked.selector
        );
        waitosaur.updateConfig(address(0x99));
    }

    function testNewConfigUsedForLockUnlock() public {
        address newLocker = address(0x30);
        address newUnLocker = address(0x31);
        address newReceiver = address(0x32);
        vm.prank(owner);
        waitosaur.updateRoles(newLocker, newUnLocker);
        vm.prank(owner);
        waitosaur.updateConfig(newReceiver);

        // Old locker should fail
        vm.prank(locker);
        vm.expectRevert(WaitosaurBase.Unauthorized.selector);
        waitosaur.lock(1 ether);

        // New locker should succeed
        vm.prank(newLocker);
        waitosaur.lock(1 ether);
        assertEq(waitosaur.lockedAmount(), 1 ether);

        // Old unLocker should fail
        vm.prank(unLocker);
        vm.expectRevert(WaitosaurBase.Unauthorized.selector);
        waitosaur.unlock();

        // New unLocker should succeed
        vm.prank(newUnLocker);
        waitosaur.unlock();
        assertEq(token.balanceOf(newReceiver), 1 ether);
    }
}
