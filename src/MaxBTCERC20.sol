// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Structured
pragma solidity ^0.8.28;

import {IMintableAndBurnable} from "./IMintableAndBurnable.sol";
import {
    ERC20Upgradeable
} from "@openzeppelin-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    UUPSUpgradeable
} from "@openzeppelin-contracts/proxy/utils/UUPSUpgradeable.sol";
import {
    Ownable2StepUpgradeable
} from "@openzeppelin-upgradeable/access/Ownable2StepUpgradeable.sol";
import {StorageSlot} from "@openzeppelin/contracts/utils/StorageSlot.sol";

contract MaxBTCERC20 is
    IMintableAndBurnable,
    UUPSUpgradeable,
    ERC20Upgradeable,
    Ownable2StepUpgradeable
{
    /// @notice Caller is not allowed
    /// @param caller The address of the caller
    error CallerIsNotAllowed(address caller);

    /// @notice Eureka rate limits have been exceeded
    /// @param requested Requested amount of tokens to burn/mint
    /// @param limit Allowed amount of tokens to burn/mint
    error EurekaRateLimitsExceeded(uint256 requested, uint256 limit);

    event CoreUpdated(address updater, address core);
    event Ics20Updated(address updater, address ics20);
    event EurekaRateLimitsUpdated(
        address updater,
        uint256 inbound,
        uint256 outbound
    );

    struct EurekaRateLimits {
        uint256 inbound;
        uint256 outbound;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("maxbtc.erc20.core")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CORE_STORAGE_SLOT =
        0x1a525db5f4ee3f4aae3d32883fec6ee50966e3b8edc8c18b2a88f8c47a4d0600;

    /// @notice ERC-7201 slot for the ICS20 contract address
    /// @dev keccak256(abi.encode(uint256(keccak256("maxbtc.erc20.ics20")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ICS20_STORAGE_SLOT =
        0xaa9b9403d129a09996409713bb21f8632c135ae1789678b7128d16411b23e500;

    /// @dev keccak256(abi.encode(uint256(keccak256("maxbtc.erc20.eureka_rate_limits")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant EUREKA_RATE_LIMITS_STORAGE_SLOT =
        0x0c0a639720c50dc80b2345d9f91f51f558d5705b1c2adac963da80931ff78500;

    function _getEurekaRateLimits()
        private
        pure
        returns (EurekaRateLimits storage $)
    {
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
    /// @param name_ The name of the token
    /// @param symbol_ The symbol of the token
    function initialize(
        address owner_,
        address ics20_,
        string calldata name_,
        string calldata symbol_
    ) external initializer {
        __ERC20_init(name_, symbol_);
        __Ownable_init(owner_);

        StorageSlot.getAddressSlot(ICS20_STORAGE_SLOT).value = ics20_;
    }

    /// @notice Migrates the MaxBTCERC20 contract to V2
    /// @param core_ The Core contract address
    function initializeV2(address core_) external reinitializer(2) {
        __Ownable2Step_init();
        StorageSlot.getAddressSlot(CORE_STORAGE_SLOT).value = core_;
    }

    /// @notice Returns the ICS20 contract address
    /// @return The ICS20 contract address
    function ics20() public view returns (address) {
        return StorageSlot.getAddressSlot(ICS20_STORAGE_SLOT).value;
    }

    /// @notice Returns the Core contract address
    /// @return The Core contract address
    function core() public view returns (address) {
        return StorageSlot.getAddressSlot(CORE_STORAGE_SLOT).value;
    }

    /// @inheritdoc ERC20Upgradeable
    function decimals() public pure override(ERC20Upgradeable) returns (uint8) {
        return 8;
    }

    /// @notice Returns Eureka rate limits
    /// @return inbound Mint rate limit
    /// @return outbound Burn rate limit
    function eurekaRateLimits()
        public
        view
        returns (uint256 inbound, uint256 outbound)
    {
        EurekaRateLimits storage rateLimits = _getEurekaRateLimits();
        return (rateLimits.inbound, rateLimits.outbound);
    }

    /// @inheritdoc IMintableAndBurnable
    function mint(address mintAddress, uint256 amount) external {
        if (_msgSender() == ics20()) {
            EurekaRateLimits storage rateLimits = _getEurekaRateLimits();
            if (amount > rateLimits.inbound) {
                revert EurekaRateLimitsExceeded(amount, rateLimits.inbound);
            }

            rateLimits.inbound -= amount;
        } else if (_msgSender() != core()) {
            revert CallerIsNotAllowed(_msgSender());
        }

        _mint(mintAddress, amount);
    }

    /// @inheritdoc IMintableAndBurnable
    function burn(address mintAddress, uint256 amount) external {
        if (_msgSender() == ics20()) {
            EurekaRateLimits storage rateLimits = _getEurekaRateLimits();
            if (amount > rateLimits.outbound) {
                revert EurekaRateLimitsExceeded(amount, rateLimits.outbound);
            }

            rateLimits.outbound -= amount;
        } else if (_msgSender() != core()) {
            revert CallerIsNotAllowed(_msgSender());
        }

        _burn(mintAddress, amount);
    }

    /// @notice Allows token owner to update ICS20
    /// @param ics20_ The ICS20 contract address
    function updateIcs20(address ics20_) external onlyOwner {
        StorageSlot.getAddressSlot(ICS20_STORAGE_SLOT).value = ics20_;
        emit Ics20Updated(_msgSender(), ics20_);
    }

    /// @notice Allows token owner to update Core
    /// @param core_ The Core contract address
    function updateCore(address core_) external onlyOwner {
        StorageSlot.getAddressSlot(CORE_STORAGE_SLOT).value = core_;
        emit CoreUpdated(_msgSender(), core_);
    }

    /// @notice Allows token owner to set Eureka rate limits
    /// @param inbound Mint rate limit
    /// @param outbound Burn rate limit
    function setEurekaRateLimits(
        uint256 inbound,
        uint256 outbound
    ) external onlyOwner {
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
