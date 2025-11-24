// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @notice Minimal oracle interface used to fetch spot balance of a given asset
/// @dev In tests this will be a mock. In production it will wrap your real AUM module.
interface IAumOracle {
    function getSpotBalance(
        string calldata asset
    ) external view returns (uint256);
}

struct WaitosaurObserverConfig {
    address locker;
    address unlocker;
    address oracle;
    string asset;
}

struct WaitosaurObserverState {
    uint256 lockedAmount;
    uint256 lastLocked;
}

contract WaitosaurObserver is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable
{
    /// @dev keccak256(abi.encode(uint256(keccak256("waitosaur.observer.config")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CONFIG_STORAGE_SLOT =
        0x993660b0e8040d3181df40a933cfb886e6d37162aa2bd22e355c5ffb4a84b400;
    /// @dev keccak256(abi.encode(uint256(keccak256("waitosaur.observer.state")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STATE_STORAGE_SLOT =
        0x5ce8a9d51aebb43c4429d9cec0a99c35af643e7268ade94cdeae3829352a0500;

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error InvalidLockerAddress();
    error InvalidUnlockerAddress();
    error InvalidOracleAddress();
    error InvalidAsset();
    error Unauthorized();
    error AlreadyLocked();
    error AlreadyUnlocked();
    error AmountZero();
    error InsufficientAssetAmount();

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event Locked(uint256 amount);
    event Unlocked();
    event ConfigUpdated(
        address locker,
        address unlocker,
        address oracle,
        string asset
    );

    constructor() {
        _disableInitializers();
    }

    function _config()
        private
        pure
        returns (WaitosaurObserverConfig storage $)
    {
        assembly {
            $.slot := CONFIG_STORAGE_SLOT
        }
    }

    function _state() private pure returns (WaitosaurObserverState storage $) {
        assembly {
            $.slot := STATE_STORAGE_SLOT
        }
    }

    function initialize(
        address owner_,
        address locker_,
        address unlocker_,
        address oracle_,
        string calldata asset_
    ) public initializer {
        if (locker_ == address(0)) revert InvalidLockerAddress();
        if (unlocker_ == address(0)) revert InvalidUnlockerAddress();
        if (oracle_ == address(0)) revert InvalidOracleAddress();
        if (bytes(asset_).length == 0) revert InvalidAsset();

        __Ownable_init(owner_);
        __UUPSUpgradeable_init();

        WaitosaurObserverConfig storage config = _config();
        config.locker = locker_;
        config.unlocker = unlocker_;
        config.oracle = oracle_;
        config.asset = asset_;

        WaitosaurObserverState storage state = _state();
        _unlockState(state);
    }

    // ---------------------------------------------------------------------
    // Execution
    // ---------------------------------------------------------------------

    /// @dev Only locker or owner is allowed
    function lock(uint256 amount) external {
        WaitosaurObserverConfig storage config = _config();
        WaitosaurObserverState storage state = _state();
        if (_msgSender() != config.locker && _msgSender() != owner()) {
            revert Unauthorized();
        }
        if (state.lockedAmount != 0) revert AlreadyLocked();
        if (amount == 0) revert AmountZero();

        _lockState(state, amount, block.timestamp);

        emit Locked(amount);
    }

    /// @dev Only unlocker or owner is allowed.
    function unlock() external {
        WaitosaurObserverConfig storage config = _config();
        WaitosaurObserverState storage state = _state();
        if (_msgSender() != config.unlocker && _msgSender() != owner()) {
            revert Unauthorized();
        }
        if (state.lockedAmount == 0) revert AlreadyUnlocked();

        uint256 spotBalance = IAumOracle(config.oracle).getSpotBalance(
            config.asset
        );

        if (spotBalance < state.lockedAmount) {
            revert InsufficientAssetAmount();
        }

        _unlockState(state);

        emit Unlocked();
    }

    /// @dev Zero address or empty string means "do not change"
    function updateConfig(
        address newLocker,
        address newUnlocker,
        address newOracle,
        string calldata newAsset
    ) external onlyOwner {
        WaitosaurObserverConfig storage config = _config();
        if (newLocker != address(0)) {
            config.locker = newLocker;
        }
        if (newUnlocker != address(0)) {
            config.unlocker = newUnlocker;
        }
        if (newOracle != address(0)) {
            config.oracle = newOracle;
        }
        if (bytes(newAsset).length != 0) {
            config.asset = newAsset;
        }

        emit ConfigUpdated(
            config.locker,
            config.unlocker,
            config.oracle,
            config.asset
        );
    }

    // ---------------------------------------------------------------------
    // Queries
    // ---------------------------------------------------------------------

    function getConfig()
        external
        pure
        returns (WaitosaurObserverConfig memory)
    {
        WaitosaurObserverConfig storage config = _config();
        return config;
    }

    function getState() external pure returns (WaitosaurObserverState memory) {
        WaitosaurObserverState storage state = _state();
        return state;
    }

    function lockedAmount() external view returns (uint256) {
        return _state().lockedAmount;
    }

    function lastLocked() external view returns (uint256) {
        return _state().lastLocked;
    }

    function unlocked() external view returns (bool) {
        return _state().lockedAmount == 0;
    }

    function _lockState(
        WaitosaurObserverState storage state,
        uint256 _lockedAmount,
        uint256 _lastLocked
    ) private {
        state.lockedAmount = _lockedAmount;
        state.lastLocked = _lastLocked;
    }

    function _unlockState(WaitosaurObserverState storage state) private {
        state.lockedAmount = 0;
        state.lastLocked = 0;
    }

    // ---------------------------------------------------------------------
    // UUPS Authorization
    // ---------------------------------------------------------------------

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}
}
