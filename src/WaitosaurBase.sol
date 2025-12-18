// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    Initializable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    UUPSUpgradeable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    Ownable2StepUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

struct WaitosaurState {
    uint256 lockedAmount;
    uint256 lastLocked;
}

struct WaitosaurAccess {
    address locker;
    address unlocker;
}

abstract contract WaitosaurBase is
    Initializable,
    UUPSUpgradeable,
    Ownable2StepUpgradeable
{
    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error AlreadyLocked();
    error AlreadyUnlocked();
    error AmountZero();
    error InvalidRolesAddresses();
    error InsufficientAssetAmount();
    error Unauthorized();

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event Locked(uint256 amount);
    event Unlocked();
    event RolesUpdated(WaitosaurAccess roles);

    // ---------------------------------------------------------------------
    // Slots
    // ---------------------------------------------------------------------

    /// @dev keccak256(abi.encode(uint256(keccak256("maxbtc.waitosaur.base.state")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant STATE_STORAGE_SLOT =
        0xb625a17d914f4b51b828255a041dd3685dd0ee72e56b573af3d2e7026d744a00;
    /// @dev keccak256(abi.encode(uint256(keccak256("maxbtc.waitosaur.base.roles")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant ROLES_STORAGE_SLOT =
        0x0a2710fa198f5ddf1285643038b49c62a676636b17744ae31f3856897d341700;

    function _getState() internal pure returns (WaitosaurState storage s) {
        assembly {
            s.slot := STATE_STORAGE_SLOT
        }
    }

    function getState() external pure returns (WaitosaurState memory) {
        WaitosaurState storage state = _getState();
        return state;
    }

    function _getRoles() internal pure returns (WaitosaurAccess storage r) {
        assembly {
            r.slot := ROLES_STORAGE_SLOT
        }
    }

    function getRoles() external pure returns (WaitosaurAccess memory) {
        WaitosaurAccess storage r = _getRoles();
        return r;
    }

    function __WaitosaurBase_init(
        address owner_,
        address locker_,
        address unlocker_
    ) internal onlyInitializing {
        __Ownable_init(owner_);
        __Ownable2Step_init();
        __UUPSUpgradeable_init();

        _setRoles(locker_, unlocker_);
        _clearLock(_getState());
    }

    function _setRoles(address locker, address unlocker) internal {
        WaitosaurAccess storage r = _getRoles();
        require(
            locker != address(0) && unlocker != address(0),
            InvalidRolesAddresses()
        );

        r.locker = locker;
        r.unlocker = unlocker;

        emit RolesUpdated(r);
    }

    function updateRoles(
        address newLocker,
        address newUnlocker
    ) public onlyOwner {
        _setRoles(newLocker, newUnlocker);
    }

    function _lockBase(
        uint256 amount
    ) internal returns (WaitosaurState storage state) {
        if (amount == 0) revert AmountZero();
        state = _getState();
        if (state.lockedAmount != 0) revert AlreadyLocked();
        state.lockedAmount = amount;
        state.lastLocked = block.timestamp;

        emit Locked(amount);
    }

    function lock(uint256 amount) public {
        WaitosaurAccess memory roles = _getRoles();
        if (_msgSender() != roles.locker && _msgSender() != owner()) {
            revert Unauthorized();
        }
        _lockBase(amount);
    }

    /// @dev Only unlocker or owner is allowed.
    function unlock() external {
        WaitosaurAccess memory roles = _getRoles();
        if (_msgSender() != roles.unlocker && _msgSender() != owner())
            revert Unauthorized();
        WaitosaurState storage state = _getState();
        _ensureLocked(state);
        _unlock();
        _clearLock(state);
        emit Unlocked();
    }

    function _unlock() internal virtual {}

    function lastLocked() public view returns (uint256) {
        return _getState().lastLocked;
    }

    function lockedAmount() public view returns (uint256) {
        return _getState().lockedAmount;
    }

    function unlocked() public view returns (bool) {
        return _getState().lockedAmount == 0;
    }

    function _ensureLocked(WaitosaurState storage state) internal view {
        if (state.lockedAmount == 0) revert AlreadyUnlocked();
    }

    function _clearLock(WaitosaurState storage state) internal {
        state.lockedAmount = 0;
        state.lastLocked = 0;
    }
}
