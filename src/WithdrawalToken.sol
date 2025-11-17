// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    ERC1155Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {
    Initializable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    UUPSUpgradeable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {StorageSlot} from "@openzeppelin/contracts/utils/StorageSlot.sol";

contract WithdrawalToken is
    Initializable,
    ERC1155Upgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    /// @dev keccak256(abi.encode(uint256(keccak256("maxbtc.withdrawal_token.name")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant NAME_STORAGE_SLOT =
        0x190eb2605c587c583d04f046ca87c4680dfd9f551aa34f413199ca360f03b400;
    /// @dev keccak256(abi.encode(uint256(keccak256("maxbtc.withdrawal_token.prefix")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PREFIX_STORAGE_SLOT =
        0x0d84cbc9810e57874f12de4633745d6fecec5db0f760c60f67b201951f5edc00;
    /// @dev keccak256(abi.encode(uint256(keccak256("maxbtc.withdrawal_token.core")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CORE_STORAGE_SLOT =
        0x91df784e22c2f214d982f522afd62bdd70c7787971d699d2545768e9d3a97200;

    using Strings for uint256;

    error OnlyCoreCanMintOrBurn();

    modifier onlyCore() {
        require(msg.sender == coreAddress(), OnlyCoreCanMintOrBurn());
        _;
    }

    function name() public view returns (string memory) {
        return StorageSlot.getStringSlot(NAME_STORAGE_SLOT).value;
    }

    function _setName(string memory newName) internal {
        StorageSlot.getStringSlot(NAME_STORAGE_SLOT).value = newName;
    }

    function prefix() public view returns (string memory) {
        return StorageSlot.getStringSlot(PREFIX_STORAGE_SLOT).value;
    }

    function _setPrefix(string memory newPrefix) internal {
        StorageSlot.getStringSlot(PREFIX_STORAGE_SLOT).value = newPrefix;
    }

    function coreAddress() public view returns (address) {
        return StorageSlot.getAddressSlot(CORE_STORAGE_SLOT).value;
    }

    function _setCoreAddress(address newCoreAddress) internal {
        StorageSlot.getAddressSlot(CORE_STORAGE_SLOT).value = newCoreAddress;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        address core_,
        string memory baseUri_,
        string memory name_,
        string memory prefix_
    ) public initializer {
        __ERC1155_init(baseUri_);
        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
        _setName(name_);
        _setPrefix(prefix_);
        _setCoreAddress(core_);
    }

    function symbol(uint256 id) public view returns (string memory) {
        return string.concat(prefix(), id.toString());
    }

    function mint(
        address to,
        uint256 id,
        uint256 amount,
        bytes calldata data
    ) external onlyCore {
        _mint(to, id, amount, data);
    }

    function burn(address from, uint256 id, uint256 amount) public onlyCore {
        _burn(from, id, amount);
    }

    function updateCoreAddress(address newCore) external onlyOwner {
        _setCoreAddress(newCore);
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(
        address
    ) internal view override(UUPSUpgradeable) onlyOwner {}
    // solhint-disable-previous-line no-empty-blocks
}
