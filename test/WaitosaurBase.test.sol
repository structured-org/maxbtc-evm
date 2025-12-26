// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {
    WaitosaurBase,
    WaitosaurState,
    WaitosaurAccess
} from "../src/WaitosaurBase.sol";

contract Waitosaur is WaitosaurBase {
    event UnlockCalled(uint256 amount);

    function initialize(
        address owner_,
        address locker_,
        address unlocker_
    ) external initializer {
        __WaitosaurBase_init(owner_, locker_, unlocker_);
    }

    function _unlock() internal override {
        WaitosaurState storage state = _getState();
        emit UnlockCalled(state.lockedAmount);
    }

    function _getInitialOracleBalance()
        internal
        view
        override
        returns (uint256)
    {
        return 0;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}

contract WaitosaurBaseTest is Test {
    Waitosaur internal waitosaur;
    address internal owner = address(0x1);
    address internal locker = address(0x2);
    address internal unlocker = address(0x3);
    address internal other = address(0x4);

    function setUp() public {
        waitosaur = new Waitosaur();
        waitosaur.initialize(owner, locker, unlocker);
    }

    function testLockByLocker() public {
        vm.prank(locker);
        waitosaur.lock(100);
        assertEq(waitosaur.lockedAmount(), 100);
        assertGt(waitosaur.lastLocked(), 0);
    }

    function testLockByOwner() public {
        vm.prank(owner);
        waitosaur.lock(50);
        assertEq(waitosaur.lockedAmount(), 50);
    }

    function testLockUnauthorizedReverts() public {
        vm.prank(other);
        vm.expectRevert(WaitosaurBase.Unauthorized.selector);
        waitosaur.lock(10);
    }

    function testLockZeroAmountReverts() public {
        vm.prank(locker);
        vm.expectRevert(WaitosaurBase.AmountZero.selector);
        waitosaur.lock(0);
    }

    function testLockAlreadyLockedReverts() public {
        vm.prank(locker);
        waitosaur.lock(1);
        vm.prank(locker);
        vm.expectRevert(WaitosaurBase.AlreadyLocked.selector);
        waitosaur.lock(1);
    }

    function testUnlockByUnlocker() public {
        vm.prank(locker);
        waitosaur.lock(5);

        vm.prank(unlocker);
        vm.expectEmit(true, true, true, true, address(waitosaur));
        emit Waitosaur.UnlockCalled(5);
        waitosaur.unlock();

        assertEq(waitosaur.lockedAmount(), 0);
        assertEq(waitosaur.lastLocked(), 0);
    }

    function testUnlockByOwnerAllowed() public {
        vm.prank(locker);
        waitosaur.lock(7);

        vm.prank(owner);
        waitosaur.unlock();

        assertEq(waitosaur.lockedAmount(), 0);
    }

    function testUnlockUnauthorizedReverts() public {
        vm.prank(locker);
        waitosaur.lock(3);

        vm.prank(other);
        vm.expectRevert(WaitosaurBase.Unauthorized.selector);
        waitosaur.unlock();
    }

    function testUnlockAlreadyUnlockedReverts() public {
        vm.prank(unlocker);
        vm.expectRevert(WaitosaurBase.AlreadyUnlocked.selector);
        waitosaur.unlock();
    }

    function testUpdateRoles() public {
        address newLocker = address(0x10);
        address newUnlocker = address(0x11);

        vm.prank(owner);
        vm.expectEmit(true, true, true, true, address(waitosaur));
        emit WaitosaurBase.RolesUpdated(
            WaitosaurAccess({locker: newLocker, unlocker: newUnlocker})
        );
        waitosaur.updateRoles(newLocker, newUnlocker);

        WaitosaurAccess memory roles = waitosaur.getRoles();
        assertEq(roles.locker, newLocker);
        assertEq(roles.unlocker, newUnlocker);
    }

    function testUpdateRolesRevertsWhenNoChange() public {
        vm.prank(owner);
        vm.expectRevert(WaitosaurBase.InvalidRolesAddresses.selector);
        waitosaur.updateRoles(address(0), address(0));
    }

    function testUpdateRolesOnlyOwner() public {
        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSignature(
                "OwnableUnauthorizedAccount(address)",
                other
            )
        );
        waitosaur.updateRoles(address(0xAA), address(0xBB));
    }

    function testTwoStepOwnershipTransfer() public {
        address newOwner = address(0xABC);
        vm.prank(owner);
        waitosaur.transferOwnership(newOwner);
        assertEq(waitosaur.pendingOwner(), newOwner, "pending owner set");

        vm.prank(newOwner);
        waitosaur.acceptOwnership();
        assertEq(waitosaur.owner(), newOwner, "ownership transferred");
        assertEq(waitosaur.pendingOwner(), address(0), "pending cleared");
    }
}
