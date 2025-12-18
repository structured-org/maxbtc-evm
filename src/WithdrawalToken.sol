// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    ERC1155Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import {
    ERC1155SupplyUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC1155/extensions/ERC1155SupplyUpgradeable.sol";
import {
    Ownable2StepUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
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
    ERC1155SupplyUpgradeable,
    Ownable2StepUpgradeable,
    UUPSUpgradeable
{
    event ConfigSettingUpdated(string field, string newValue);

    struct WithdrawalTokenConfig {
        address coreContract;
        address withdrawalManagerContract;
        string name;
        string prefix;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("maxbtc.withdrawal_token.config")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CONFIG_STORAGE_SLOT =
        0x2ffbc5c5fd0856976bf4c1b8549b1dcedc1c604f212a684521a94c9f1a146900;

    using Strings for uint256;

    error OnlyCoreCanMint();
    error OnlyWithdrawalManagerCanBurn();
    error InvalidCoreContractAddress();
    error InvalidWithdrawalManagerContractAddress();
    error InvalidName();
    error InvalidPrefix();

    modifier onlyCore() {
        _onlyCore();
        _;
    }

    modifier onlyWithdrawalManager() {
        _onlyWithdrawalManager();
        _;
    }

    function _onlyCore() internal view {
        require(
            _msgSender() == _getWithdrawalTokenConfig().coreContract,
            OnlyCoreCanMint()
        );
    }

    function _onlyWithdrawalManager() internal view {
        require(
            _msgSender() ==
                _getWithdrawalTokenConfig().withdrawalManagerContract,
            OnlyWithdrawalManagerCanBurn()
        );
    }

    function _getWithdrawalTokenConfig()
        private
        pure
        returns (WithdrawalTokenConfig storage $)
    {
        assembly {
            $.slot := CONFIG_STORAGE_SLOT
        }
    }

    function name() public view returns (string memory) {
        return _getWithdrawalTokenConfig().name;
    }

    function _setName(string memory newName) internal {
        _getWithdrawalTokenConfig().name = newName;
    }

    function prefix() public view returns (string memory) {
        return _getWithdrawalTokenConfig().prefix;
    }

    function _setPrefix(string memory newPrefix) internal {
        _getWithdrawalTokenConfig().prefix = newPrefix;
    }

    function updateConfig(
        address newCoreContract,
        string memory newName,
        string memory newPrefix,
        address newWithdrawalManagerContract
    ) external onlyOwner {
        WithdrawalTokenConfig storage config = _getWithdrawalTokenConfig();
        if (newCoreContract == address(0)) revert InvalidCoreContractAddress();
        if (newWithdrawalManagerContract == address(0))
            revert InvalidWithdrawalManagerContractAddress();
        if (bytes(newName).length == 0) revert InvalidName();
        if (bytes(newPrefix).length == 0) revert InvalidPrefix();

        config.coreContract = newCoreContract;
        config.name = newName;
        config.prefix = newPrefix;
        config.withdrawalManagerContract = newWithdrawalManagerContract;
        emit ConfigSettingUpdated(
            "coreContract",
            string(abi.encodePacked(newCoreContract))
        );
        emit ConfigSettingUpdated("name", newName);
        emit ConfigSettingUpdated("prefix", newPrefix);
        emit ConfigSettingUpdated(
            "withdrawalManagerContract",
            string(abi.encodePacked(newWithdrawalManagerContract))
        );
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        address core_,
        address withdrawalManagerContract_,
        string memory baseUri_,
        string memory name_,
        string memory prefix_
    ) public initializer {
        __ERC1155_init(baseUri_);
        __Ownable_init(owner_);
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
        WithdrawalTokenConfig storage config = _getWithdrawalTokenConfig();

        if (core_ == address(0)) revert InvalidCoreContractAddress();
        if (withdrawalManagerContract_ == address(0))
            revert InvalidWithdrawalManagerContractAddress();
        if (bytes(name_).length == 0) revert InvalidName();
        if (bytes(prefix_).length == 0) revert InvalidPrefix();
        config.coreContract = core_;
        config.name = name_;
        config.prefix = prefix_;
        config.withdrawalManagerContract = withdrawalManagerContract_;
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

    function burn(
        address from,
        uint256 id,
        uint256 amount
    ) public onlyWithdrawalManager {
        address operator = _msgSender();
        require(
            operator == from || isApprovedForAll(from, operator),
            ERC1155MissingApprovalForAll(operator, from)
        );
        _burn(from, id, amount);
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(
        address
    ) internal view override(UUPSUpgradeable) onlyOwner {}

    function _update(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values
    ) internal override(ERC1155SupplyUpgradeable, ERC1155Upgradeable) {
        super._update(from, to, ids, values);
    }
}
