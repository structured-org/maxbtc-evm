// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {WaitosaurBase, WaitosaurState} from "./WaitosaurBase.sol";

/// @notice Minimal oracle interface used to fetch spot balance of a given asset
/// @dev In tests this will be a mock. In production it will wrap your real AUM module.
interface IAumOracle {
    function getSpotBalance(
        string calldata asset
    ) external view returns (uint256);
}

struct WaitosaurObserverConfig {
    address oracle;
    string asset;
}

contract WaitosaurObserver is WaitosaurBase {
    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error InvalidOracleAddress();
    error InvalidAsset();
    error ConfigCantBeUpdatedWhenLocked();

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event ConfigUpdated(WaitosaurObserverConfig config);

    // ---------------------------------------------------------------------
    // Slots
    // ---------------------------------------------------------------------

    /// @dev keccak256(abi.encode(uint256(keccak256("maxbtc.waitosaur.observer.config")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CONFIG_STORAGE_SLOT =
        0xa3610185eb222d8e74f6618d40b7c4662aee6c24d7161ae6a36cd8ec3a4c7500;

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

    function initialize(
        address owner_,
        address locker_,
        address unlocker_,
        address oracle_,
        string calldata asset_
    ) public initializer {
        if (oracle_ == address(0)) revert InvalidOracleAddress();
        if (bytes(asset_).length == 0) revert InvalidAsset();

        __WaitosaurBase_init(owner_, locker_, unlocker_);

        WaitosaurObserverConfig storage config = _config();
        config.oracle = oracle_;
        config.asset = asset_;
    }

    // ---------------------------------------------------------------------
    // Execution
    // ---------------------------------------------------------------------

    /// @notice Zero address or empty string means "do not change"
    function updateConfig(
        address newOracle,
        string calldata newAsset
    ) external onlyOwner {
        if (!unlocked()) revert ConfigCantBeUpdatedWhenLocked();
        WaitosaurObserverConfig storage config = _config();
        if (newOracle != address(0)) {
            config.oracle = newOracle;
        }
        if (bytes(newAsset).length != 0) {
            config.asset = newAsset;
        }

        emit ConfigUpdated(config);
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

    // ---------------------------------------------------------------------
    // Overrides
    // ---------------------------------------------------------------------

    function _getInitialOracleBalance()
        internal
        view
        override
        returns (uint256)
    {
        WaitosaurObserverConfig storage config = _config();
        return IAumOracle(config.oracle).getSpotBalance(config.asset);
    }

    function _unlock() internal view override(WaitosaurBase) {
        WaitosaurObserverConfig storage config = _config();
        WaitosaurState storage state = _getState();
        uint256 spotBalance = IAumOracle(config.oracle).getSpotBalance(
            config.asset
        );

        // Verify that balance increased by at least the locked amount
        // Use subtraction to avoid overflow
        if (spotBalance < state.initialOracleBalance) {
            revert OracleBalanceIncorrect();
        }
        if (spotBalance - state.initialOracleBalance < state.lockedAmount) {
            revert InsufficientAssetAmount();
        }
    }

    // ---------------------------------------------------------------------
    // UUPS Authorization
    // ---------------------------------------------------------------------

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}
}
