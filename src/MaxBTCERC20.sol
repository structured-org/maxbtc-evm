// SPDX-License-Identifier: MIT
// Copyright (c) 2024 COSMOS
// Copyright (c) 2025 Structured
// Modifications by Structured:
//   - rename contract to MaxBTCERC20
//   - set decimals() to 8
//   - remove decimals() @dev docstring
//   - add rate limiting
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

    /// @notice Eureka rate limits have been exceeded
    /// @param requested Requested amount of tokens to burn/mint
    /// @param limit Allowed amount of tokens to burn/mint
    error EurekaRateLimitsExceeded(uint256 requested, uint256 limit);

    event ConfigUpdated(address indexed updater, address ics20, address core);
    event EurekaRateLimitsUpdated(address indexed updater, uint256 inbound, uint256 outbound);

    struct Config {
        address ics20;
        address core;
    }

    struct EurekaRateLimits {
        uint256 inbound;
        uint256 outbound;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("maxbtc.erc20.config")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CONFIG_STORAGE_SLOT =
        0x60e64ce940b41f99536b34ed9aceefb0cc4425527635a944fc8718b4d4247c00;
    
    /// @dev keccak256(abi.encode(uint256(keccak256("maxbtc.erc20.eureka_rate_limits")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant EUREKA_RATE_LIMITS_STORAGE_SLOT =
        0x0c0a639720c50dc80b2345d9f91f51f558d5705b1c2adac963da80931ff78500;

    function _getConfig() private pure returns (Config storage $) {
        assembly {
            $.slot := CONFIG_STORAGE_SLOT
        }
    }

    function _getEurekaRateLimits() private pure returns (EurekaRateLimits storage $) {
        assembly {
            $.slot := EUREKA_RATE_LIMITS_STORAGE_SLOT
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
        Config storage config = _getConfig();
        config.ics20 = ics20_;
        config.core = core_;
    }

    /// @notice Returns the ICS20 contract address
    /// @return The ICS20 contract address
    function ics20() external view returns (address) {
        Config storage config = _getConfig();
        return config.ics20;
    }

    /// @notice Returns the Core contract address
    /// @return The Core contract address
    function core() external view returns (address) {
        Config storage config = _getConfig();
        return config.core;
    }

    /// @inheritdoc ERC20Upgradeable
    function decimals() public pure override(ERC20Upgradeable) returns (uint8) {
        return 8;
    }

    /// @notice Returns Eureka rate limits
    /// @return inbound Mint rate limit
    /// @return outbound Burn rate limit
    function eurekaRateLimits() public view returns (uint256 inbound, uint256 outbound) {
        EurekaRateLimits storage rateLimits = _getEurekaRateLimits();
        return (rateLimits.inbound, rateLimits.outbound);
    }

    /// @inheritdoc IMintableAndBurnable
    function mint(address mintAddress, uint256 amount) external {
        Config storage config = _getConfig();

        if (_msgSender() == config.ics20) {
            EurekaRateLimits storage rateLimits = _getEurekaRateLimits();
            if (amount > rateLimits.inbound) {
                revert EurekaRateLimitsExceeded(amount, rateLimits.inbound);
            }

            rateLimits.inbound -= amount;
        } else if (_msgSender() != config.core) {
            revert CallerIsNotAllowed(_msgSender());
        }

        _mint(mintAddress, amount);
    }

    /// @inheritdoc IMintableAndBurnable
    function burn(address mintAddress, uint256 amount) external {
        Config storage config = _getConfig();

        if (_msgSender() == config.ics20) {
            EurekaRateLimits storage rateLimits = _getEurekaRateLimits();
            if (amount > rateLimits.outbound) {
                revert EurekaRateLimitsExceeded(amount, rateLimits.outbound);
            }

            rateLimits.outbound -= amount;
        } else if (_msgSender() != config.core) {
            revert CallerIsNotAllowed(_msgSender());
        }

        _burn(mintAddress, amount);
    }

    /// @notice Allows token owner to update config
    /// @param ics20_ The ICS20 contract address
    /// @param core_ The Core contract address
    function updateConfig(address ics20_, address core_) external onlyOwner {
        Config storage config = _getConfig();
        config.ics20 = ics20_;
        config.core = core_;
        emit ConfigUpdated(_msgSender(), ics20_, core_);
    }

    /// @notice Allows token owner to set Eureka rate limits
    /// @param inbound Mint rate limit
    /// @param outbound Burn rate limit
    function setEurekaRateLimits(uint256 inbound, uint256 outbound) external onlyOwner {
        EurekaRateLimits storage rateLimits = _getEurekaRateLimits();
        rateLimits.inbound = inbound;
        rateLimits.outbound = outbound;
        emit EurekaRateLimitsUpdated(_msgSender(), inbound, outbound);
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(
        address
    ) internal view override(UUPSUpgradeable) onlyOwner {}

    // solhint-disable-previous-line no-empty-blocks

    /// @notice prevents `owner` from renouncing ownership and potentially locking assets forever
    /// @dev overrides OwnableUpgradeable's renounceOwnership to always revert
    function renounceOwnership() public pure override {
        revert("Renouncing ownership disabled!");
    }
}
