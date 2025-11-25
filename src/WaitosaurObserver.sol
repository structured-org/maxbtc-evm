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

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event ConfigUpdated(WaitosaurObserverConfig config);

    // ---------------------------------------------------------------------
    // Slots
    // ---------------------------------------------------------------------

    /// @dev keccak256(abi.encode(uint256(keccak256("maxbtc.waitosaur.observer.config")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CONFIG_STORAGE_SLOT =
        0x54b7bbce5d6b2ddbcd1f5766867ee5cd3a7cfecc2ec43a3cd750b88545115b00;

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
        if (locker_ == address(0)) revert InvalidLockerAddress();
        if (unlocker_ == address(0)) revert InvalidUnlockerAddress();
        if (oracle_ == address(0)) revert InvalidOracleAddress();
        if (bytes(asset_).length == 0) revert InvalidAsset();

        __Ownable_init(owner_);
        __UUPSUpgradeable_init();

        WaitosaurObserverConfig storage config = _config();
        config.oracle = oracle_;
        config.asset = asset_;

        _initializeRoles(locker_, unlocker_);
        _clearLock(_getState());
    }

    // ---------------------------------------------------------------------
    // Execution
    // ---------------------------------------------------------------------

    /// @dev Zero address or empty string means "do not change"
    function updateConfig(
        address newOracle,
        string calldata newAsset
    ) external onlyOwner {
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

    function _unlock(WaitosaurState storage state) internal view override {
        WaitosaurObserverConfig storage config = _config();
        uint256 spotBalance = IAumOracle(config.oracle).getSpotBalance(
            config.asset
        );

        if (spotBalance < state.lockedAmount) {
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
