// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    ERC1155Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import {
    ERC1155BurnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC1155/extensions/ERC1155BurnableUpgradeable.sol";
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
    ERC1155BurnableUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    /// @dev keccak256(abi.encode(uint256(keccak256("maxbtc.withdrawal_token.name")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant NAME_STORAGE_SLOT =
        0x190eb2605c587c583d04f046ca87c4680dfd9f551aa34f413199ca360f03b400;

    using Strings for uint256;

    function name() public view returns (string memory) {
        return StorageSlot.getStringSlot(NAME_STORAGE_SLOT).value;
    }

    function _setName(string memory newName) internal {
        StorageSlot.getStringSlot(NAME_STORAGE_SLOT).value = newName;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        string memory baseUri_,
        string memory name_
    ) public initializer {
        __ERC1155_init(baseUri_);
        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
        _setName(name_);
    }

    function symbol(uint256 id) public pure returns (string memory) {
        return string(abi.encodePacked("WRT-", id.toString()));
    }

    function mint(
        address to,
        uint256 id,
        uint256 amount,
        bytes calldata data
    ) external onlyOwner {
        _mint(to, id, amount, data);
    }

    function mintBatch(
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure {
        revert("mintBatch is disabled");
    }

    function burn(
        address from,
        uint256 id,
        uint256 amount
    ) public override onlyOwner {
        _burn(from, id, amount);
    }

    function burnBatch(
        address,
        uint256[] memory,
        uint256[] memory
    ) public pure override {
        revert("burnBatch is disabled");
    }

    error InvalidImplementation();

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(
        address
    ) internal view override(UUPSUpgradeable) onlyOwner {}
    // solhint-disable-previous-line no-empty-blocks

    uint256[50] private __gap;
}
