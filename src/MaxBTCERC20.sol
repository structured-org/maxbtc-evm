// SPDX-License-Identifier: MIT
// Copyright (c) 2024 COSMOS
// Copyright (c) 2025 Structured
// Modifications by Structured:
//   - rename contract to MaxBTCERC20
//   - set decimals() to 8
//   - remove decimals() @dev docstring
//   - replace config with dedicated ICS20 storage slot
//   - disable renounceOwnership()
pragma solidity ^0.8.28;

import {IMintableAndBurnable} from "./IMintableAndBurnable.sol";
import {ERC20Upgradeable} from "@openzeppelin-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin-contracts/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin-upgradeable/access/OwnableUpgradeable.sol";

contract MaxBTCERC20 is
    IMintableAndBurnable,
    UUPSUpgradeable,
    ERC20Upgradeable,
    OwnableUpgradeable
{
    /// @notice Caller is not allowed
    /// @param caller The address of the caller
    error CallerIsNotAllowed(address caller);

    struct TokenConfig {
        address ics20;
        address core;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("maxbtc.erc20.config")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CONFIG_STORAGE_SLOT =
        0x60e64ce940b41f99536b34ed9aceefb0cc4425527635a944fc8718b4d4247c00;

    function _getCoreConfig() private pure returns (TokenConfig storage $) {
        assembly {
            $.slot := CONFIG_STORAGE_SLOT
        }
    }

    /// @dev This contract is meant to be deployed by a proxy, so the constructor is not used
    // natlint-disable-next-line MissingNotice
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the MaxBTCERC20 contract
    /// @param owner_ The owner of the contract, allowing it to be upgraded
    /// @param ics20_ The ICS20 contract address
    /// @param core_ The Core contract address
    /// @param name_ The name of the token
    /// @param symbol_ The symbol of the token
    function initialize(
        address owner_,
        address ics20_,
        address core_,
        string calldata name_,
        string calldata symbol_
    ) external initializer {
        __ERC20_init(name_, symbol_);
        __Ownable_init(owner_);
        TokenConfig storage config = _getCoreConfig();
        config.ics20 = ics20_;
        config.core = core_;
    }

    /// @notice Returns the ICS20 contract address
    /// @return The ICS20 contract address
    function ics20() external view returns (address) {
        TokenConfig storage config = _getCoreConfig();
        return config.ics20;
    }

    /// @notice Returns the Core contract address
    /// @return The Core contract address
    function core() external view returns (address) {
        TokenConfig storage config = _getCoreConfig();
        return config.core;
    }

    /// @inheritdoc ERC20Upgradeable
    function decimals() public pure override(ERC20Upgradeable) returns (uint8) {
        return 8;
    }

    /// @inheritdoc IMintableAndBurnable
    function mint(address mintAddress, uint256 amount) external allowed {
        _mint(mintAddress, amount);
    }

    /// @inheritdoc IMintableAndBurnable
    function burn(address mintAddress, uint256 amount) external allowed {
        _burn(mintAddress, amount);
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(
        address
    ) internal view override(UUPSUpgradeable) onlyOwner {}

    // solhint-disable-previous-line no-empty-blocks

    /// @notice prevents `owner` from renouncing ownership and potentially locking assets forever
    /// @dev overrides OwnableUpgradeable's renounceOwnership to always revert
    function renounceOwnership() public view override onlyOwner {
        revert("Renouncing ownership disabled!");
    }

    /// @notice Modifier to check if the caller is the ICS20 contract
    modifier allowed() {
        _allowed();
        _;
    }

    function _allowed() internal view {
        TokenConfig storage config = _getCoreConfig();
        require(
            _msgSender() == config.ics20 || _msgSender() == config.core,
            CallerIsNotAllowed(_msgSender())
        );
    }
}
