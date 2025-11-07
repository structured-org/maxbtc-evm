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

import { IMintableAndBurnable } from "./IMintableAndBurnable.sol";
import { ERC20Upgradeable } from "@openzeppelin-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin-contracts/proxy/utils/UUPSUpgradeable.sol";
import { OwnableUpgradeable } from "@openzeppelin-upgradeable/access/OwnableUpgradeable.sol";
import { StorageSlot } from "@openzeppelin/contracts/utils/StorageSlot.sol";

contract MaxBTCERC20 is IMintableAndBurnable, UUPSUpgradeable, ERC20Upgradeable, OwnableUpgradeable {
    /// @notice Caller is not the ICS20 contract
    /// @param caller The address of the caller
    error CallerIsNotICS20(address caller);

    /// @notice ERC-7201 slot for the ICS20 contract address
    /// @dev keccak256(abi.encode(uint256(keccak256("maxbtc.erc20.ics20")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ICS20_STORAGE_SLOT = 0xaa9b9403d129a09996409713bb21f8632c135ae1789678b7128d16411b23e500;

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
    )
        external
        initializer
    {
        __ERC20_init(name_, symbol_);
        __Ownable_init(owner_);

        StorageSlot.getAddressSlot(ICS20_STORAGE_SLOT).value = ics20_;
    }

    /// @notice Returns the ICS20 contract address
    /// @return The ICS20 contract address
    function ics20() external view returns (address) {
        return StorageSlot.getAddressSlot(ICS20_STORAGE_SLOT).value;
    }

    /// @inheritdoc ERC20Upgradeable
    function decimals() public pure override(ERC20Upgradeable) returns (uint8) {
        return 8;
    }

    /// @inheritdoc IMintableAndBurnable
    function mint(address mintAddress, uint256 amount) external onlyICS20 {
        _mint(mintAddress, amount);
    }

    /// @inheritdoc IMintableAndBurnable
    function burn(address mintAddress, uint256 amount) external onlyICS20 {
        _burn(mintAddress, amount);
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal view override(UUPSUpgradeable) onlyOwner { }
    // solhint-disable-previous-line no-empty-blocks

    /// @notice prevents `owner` from renouncing ownership and potentially locking assets forever
    /// @dev overrides OwnableUpgradeable's renounceOwnership to always revert
    function renounceOwnership() public view override onlyOwner {
        revert("Renouncing ownership disabled!");
    }

    /// @notice Modifier to check if the caller is the ICS20 contract
    modifier onlyICS20() {
        require(_msgSender() == StorageSlot.getAddressSlot(ICS20_STORAGE_SLOT).value, CallerIsNotICS20(_msgSender()));
        _;
    }
}
