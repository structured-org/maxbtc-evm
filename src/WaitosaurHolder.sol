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

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event ConfigUpdated(WaitosaurHolderConfig config);

    // ---------------------------------------------------------------------
    // Slots
    // ---------------------------------------------------------------------

    /// @dev keccak256(abi.encode(uint256(keccak256("maxbtc.waitosaur.holder.config")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CONFIG_STORAGE_SLOT =
        0x47c6d7e4919fbb673f9a86f2f237d78da7840dcd981fb6622bf1c417e3fed700;

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
        address token_,
        address locker_,
        address unlocker_,
        address receiver_
    ) public initializer {
        if (token_ == address(0)) revert InvalidTokenAddress();
        if (receiver_ == address(0)) revert InvalidReceiverAddress();

        __WaitosaurBase_init(owner_, locker_, unlocker_);

        WaitosaurHolderConfig storage config = _getWaitosaurConfig();
        config.receiver = receiver_;
        config.token = token_;
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

    function _unlock() internal override(WaitosaurBase) {
        WaitosaurHolderConfig storage config = _getWaitosaurConfig();
        WaitosaurState storage state = _getState();
        IERC20 tokenERC20 = IERC20(config.token);

        uint256 balance = tokenERC20.balanceOf(address(this));
        if (balance < state.lockedAmount) revert InsufficientAssetAmount();
        SafeERC20.safeTransfer(tokenERC20, config.receiver, state.lockedAmount);
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}
}
