// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28;

import {
    Initializable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    UUPSUpgradeable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {StorageSlot} from "@openzeppelin/contracts/utils/StorageSlot.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Waitosaur is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    struct WaitosaurConfig {
        address token;
        address locker;
        address unLocker;
        address receiver;
    }
    struct WaitosaurState {
        uint256 lockedAmount;
        uint256 lastLocked;
    }

    // Custom errors
    error InvalidTokenAddress();
    error InvalidReceiverAddress();
    error InvalidLockerAddress();
    error InvalidUnlockerAddress();
    error AlreadyUnlocked();
    error AlreadyLocked();
    error AmountZero();
    error NothingLocked();
    error InsufficientBalance();
    error NotLocker();
    error NotUnLocker();

    /// @dev keccak256(abi.encode(uint256(keccak256("maxbtc.waitosaur.config")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CONFIG_STORAGE_SLOT =
        0x8f3661154de8aca85dd40a286ee737a27a3b740a5d65a00dc9530f3fcf760200;
    /// @dev keccak256(abi.encode(uint256(keccak256("maxbtc.waitosaur.state")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STATE_STORAGE_SLOT =
        0xcb11509986cbc674883f88160c41f636c73566a871549bf8441ad8bc0e648300;

    event Locked(uint256 indexed amount);
    event Unlocked();
    event ConfigUpdated(WaitosaurConfig indexed config);

    function _getWaitosaurConfig()
        private
        pure
        returns (WaitosaurConfig storage $)
    {
        assembly {
            $.slot := CONFIG_STORAGE_SLOT
        }
    }

    function _getWaitosaurState()
        private
        pure
        returns (WaitosaurState storage $)
    {
        assembly {
            $.slot := STATE_STORAGE_SLOT
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        address _token,
        address _locker,
        address _unLocker,
        address _receiver
    ) public initializer {
        if (_token == address(0)) revert InvalidTokenAddress();
        if (_receiver == address(0)) revert InvalidReceiverAddress();
        if (_locker == address(0)) revert InvalidLockerAddress();
        if (_unLocker == address(0)) revert InvalidUnlockerAddress();
        if (owner_ == address(0)) revert InvalidUnlockerAddress();
        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
        WaitosaurConfig storage config = _getWaitosaurConfig();
        config.locker = _locker;
        config.unLocker = _unLocker;
        config.receiver = _receiver;
        config.token = _token;
    }

    function lock(uint256 amount) external {
        WaitosaurConfig storage config = _getWaitosaurConfig();
        if (msg.sender != config.locker) revert NotLocker();
        WaitosaurState storage state = _getWaitosaurState();
        if (state.lockedAmount > 0) revert AlreadyLocked();
        if (amount == 0) revert AmountZero();
        state.lockedAmount = amount;
        state.lastLocked = block.timestamp;
        emit Locked(amount);
    }

    function lastLocked() public view returns (uint256) {
        WaitosaurState storage state = _getWaitosaurState();
        return state.lastLocked;
    }

    function unlock() external {
        WaitosaurConfig storage config = _getWaitosaurConfig();
        if (msg.sender != config.unLocker) revert NotUnLocker();
        WaitosaurState storage state = _getWaitosaurState();
        if (state.lockedAmount == 0) revert AlreadyUnlocked();
        IERC20 tokenERC20 = IERC20(config.token);
        // Check contract balance using IERC20
        uint256 balance = tokenERC20.balanceOf(address(this));
        if (balance < state.lockedAmount) revert InsufficientBalance();
        // Transfer lockedAmount to receiver
        SafeERC20.safeTransfer(tokenERC20, config.receiver, state.lockedAmount);
        // SafeERC20 reverts on failure, so no extra return-value checks are needed.
        state.lockedAmount = 0;
        state.lastLocked = 0;
        emit Unlocked();
    }

    function updateConfig(
        address newLocker,
        address newUnLocker,
        address newReceiver
    ) external onlyOwner {
        WaitosaurConfig storage config = _getWaitosaurConfig();
        if (newLocker == address(0)) revert InvalidLockerAddress();
        if (newUnLocker == address(0)) revert InvalidUnlockerAddress();
        if (newReceiver == address(0)) revert InvalidReceiverAddress();
        config.locker = newLocker;
        config.unLocker = newUnLocker;
        config.receiver = newReceiver;
        emit ConfigUpdated(config);
    }

    function lockedAmount() public view returns (uint256) {
        WaitosaurState storage state = _getWaitosaurState();
        return state.lockedAmount;
    }

    function unlocked() public view returns (bool) {
        WaitosaurState storage state = _getWaitosaurState();
        return state.lockedAmount == 0;
    }

    function getConfig() public pure returns (WaitosaurConfig memory) {
        WaitosaurConfig storage config = _getWaitosaurConfig();
        return config;
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}
}
