// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {WaitosaurBase, WaitosaurState} from "./WaitosaurBase.sol";

struct WaitosaurHolderConfig {
    address token;
    address receiver;
}

contract WaitosaurHolder is WaitosaurBase {
    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error InvalidTokenAddress();
    error InvalidReceiverAddress();
    error NotLocker();
    error NotUnLocker();

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event ConfigUpdated(WaitosaurHolderConfig config);

    // ---------------------------------------------------------------------
    // Slots
    // ---------------------------------------------------------------------

    /// @dev keccak256(abi.encode(uint256(keccak256("maxbtc.waitosaur.holder.config")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CONFIG_STORAGE_SLOT =
        0xd788cf889637414408102ead9bb45ec368e1e6e80911edf1852af5b5d59ad900;

    function _getWaitosaurConfig()
        private
        pure
        returns (WaitosaurHolderConfig storage $)
    {
        assembly {
            $.slot := CONFIG_STORAGE_SLOT
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
        address _unlocker,
        address _receiver
    ) public initializer {
        if (_token == address(0)) revert InvalidTokenAddress();
        if (_receiver == address(0)) revert InvalidReceiverAddress();
        if (_locker == address(0)) revert InvalidLockerAddress();
        if (_unlocker == address(0)) revert InvalidUnlockerAddress();
        if (owner_ == address(0)) revert InvalidUnlockerAddress();
        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
        WaitosaurHolderConfig storage config = _getWaitosaurConfig();
        config.receiver = _receiver;
        config.token = _token;
        _initializeRoles(_locker, _unlocker);
    }

    // ---------------------------------------------------------------------
    // Execution
    // ---------------------------------------------------------------------

    function updateConfig(address newReceiver) external onlyOwner {
        if (newReceiver == address(0)) revert InvalidReceiverAddress();
        WaitosaurHolderConfig storage config = _getWaitosaurConfig();
        config.receiver = newReceiver;
        emit ConfigUpdated(config);
    }

    // ---------------------------------------------------------------------
    // Queries
    // ---------------------------------------------------------------------

    function getConfig() public pure returns (WaitosaurHolderConfig memory) {
        WaitosaurHolderConfig storage config = _getWaitosaurConfig();
        return config;
    }

    // ---------------------------------------------------------------------
    // Overrides
    // ---------------------------------------------------------------------

    function _unlock(WaitosaurState storage state) internal override {
        WaitosaurHolderConfig storage config = _getWaitosaurConfig();
        IERC20 tokenERC20 = IERC20(config.token);

        uint256 balance = tokenERC20.balanceOf(address(this));
        if (balance < state.lockedAmount) revert InsufficientAssetAmount();
        SafeERC20.safeTransfer(tokenERC20, config.receiver, state.lockedAmount);
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}
}
