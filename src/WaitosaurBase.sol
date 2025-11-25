// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

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
    OwnableUpgradeable
{
    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error AlreadyLocked();
    error AlreadyUnlocked();
    error AmountZero();
    error InvalidLockerAddress();
    error InvalidUnlockerAddress();
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

    /// @dev keccak256(abi.encode(uint256(keccak256("maxbtc.waitosaur.state")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant STATE_STORAGE_SLOT_HOLDER =
        0xcb11509986cbc674883f88160c41f636c73566a871549bf8441ad8bc0e648300;
    /// @dev keccak256(abi.encode(uint256(keccak256("maxbtc.waitosaur.roles")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant ROLES_STORAGE_SLOT =
        0x8dd083a75f3aab575c55c6c418ff7b8be832ed2ed0de8227f52af67507e54500;

    function _getState() internal pure returns (WaitosaurState storage s) {
        assembly {
            s.slot := STATE_STORAGE_SLOT_HOLDER
        }
    }

    function getState() external view returns (WaitosaurState memory) {
        WaitosaurState storage state = _getState();
        return
            WaitosaurState({
                lockedAmount: state.lockedAmount,
                lastLocked: state.lastLocked
            });
    }

    function _getRoles() internal pure returns (WaitosaurAccess storage r) {
        assembly {
            r.slot := ROLES_STORAGE_SLOT
        }
    }

    function _initializeRoles(address locker, address unlocker) internal {
        WaitosaurAccess storage r = _getRoles();
        r.locker = locker;
        r.unlocker = unlocker;
        emit RolesUpdated(r);
    }

    function _setRoles(address locker, address unlocker) internal {
        WaitosaurAccess storage r = _getRoles();
        if (locker != address(0)) {
            r.locker = locker;
        }
        if (unlocker != address(0)) {
            r.unlocker = unlocker;
        }
        emit RolesUpdated(r);
    }

    function getRoles() public pure returns (WaitosaurAccess memory) {
        WaitosaurAccess storage r = _getRoles();
        return r;
    }

    function updateRoles(
        address newLocker,
        address newUnlocker
    ) public onlyOwner {
        if (newLocker == address(0) && newUnlocker == address(0)) {
            revert InvalidLockerAddress();
        }
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
    }

    function lock(uint256 amount) public {
        WaitosaurAccess storage roles = _getRoles();
        if (_msgSender() != roles.locker && _msgSender() != owner()) {
            revert Unauthorized();
        }
        _lockBase(amount);
        emit Locked(amount);
    }

    /// @dev Only unlocker or owner is allowed.
    function unlock() external {
        WaitosaurAccess storage roles = _getRoles();
        if (_msgSender() != roles.unlocker && _msgSender() != owner())
            revert Unauthorized();
        WaitosaurState storage state = _getState();
        _ensureLocked(state);
        _unlock(state);
        _clearLock(state);
        emit Unlocked();
    }

    function _unlock(WaitosaurState storage state) internal virtual {}

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
