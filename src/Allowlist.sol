// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    Initializable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    UUPSUpgradeable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    Ownable2StepUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

/// @notice Minimal external interface for ZKMe-like approval checker.
interface IZkMe {
    function hasApproved(
        address cooperator,
        address user
    ) external view returns (bool);
}

/// @notice Simple allowlist contract with optional ZKMe fallback, adapted from the Rust implementation.
contract Allowlist is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable {
    struct ZkMeSettings {
        address contractAddr;
        address cooperator;
        bool enabled;
    }

    struct AllowlistStorage {
        mapping(address => bool) allowed;
        ZkMeSettings zkMe;
    }

    // keccak256(abi.encode(uint256(keccak256("maxbtc.allowlist.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ALLOWLIST_STORAGE_SLOT =
        0x726794df19ef5494e47a09cfc5a29af7f99de86be3f96230f62fe88e31729e00;

    event AddressAllowed(address indexed account);
    event AddressDenied(address indexed account);
    event ZkMeSettingsUpdated(
        address contractAddr,
        address cooperator,
        bool enabled
    );
    event ZkMeSettingsReset();

    error ZeroAddressNotAllowed();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_) public initializer {
        __Ownable_init(owner_);
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
    }

    function _getStorage() private pure returns (AllowlistStorage storage $) {
        assembly {
            $.slot := ALLOWLIST_STORAGE_SLOT
        }
    }

    function allow(address[] calldata accounts) external onlyOwner {
        uint256 len = accounts.length;
        for (uint256 i = 0; i < len; i++) {
            address account = accounts[i];
            if (account == address(0)) {
                revert ZeroAddressNotAllowed();
            }
            _getStorage().allowed[account] = true;
            emit AddressAllowed(account);
        }
    }

    function deny(address[] calldata accounts) external onlyOwner {
        uint256 len = accounts.length;
        for (uint256 i = 0; i < len; i++) {
            address account = accounts[i];
            if (account == address(0)) {
                revert ZeroAddressNotAllowed();
            }
            delete _getStorage().allowed[account];
            emit AddressDenied(account);
        }
    }

    function setZkMeSettings(
        address contractAddr,
        address cooperator
    ) external onlyOwner {
        if (contractAddr == address(0) && cooperator == address(0)) {
            _getStorage().zkMe = ZkMeSettings({
                contractAddr: address(0),
                cooperator: address(0),
                enabled: false
            });
            emit ZkMeSettingsReset();
        } else {
            if (contractAddr == address(0) || cooperator == address(0)) {
                revert ZeroAddressNotAllowed();
            }
            _getStorage().zkMe = ZkMeSettings({
                contractAddr: contractAddr,
                cooperator: cooperator,
                enabled: true
            });

            emit ZkMeSettingsUpdated(contractAddr, cooperator, true);
        }
    }

    function isAddressAllowed(address account) external view returns (bool) {
        AllowlistStorage storage $ = _getStorage();
        if ($.allowed[account]) {
            return true;
        }
        if ($.zkMe.enabled) {
            return
                IZkMe($.zkMe.contractAddr).hasApproved(
                    $.zkMe.cooperator,
                    account
                );
        }
        return false;
    }

    function zkMeSettings() external view returns (ZkMeSettings memory) {
        return _getStorage().zkMe;
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}
}
