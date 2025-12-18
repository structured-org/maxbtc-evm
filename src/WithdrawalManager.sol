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
import {
    ERC1155HolderUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC1155/utils/ERC1155HolderUpgradeable.sol";
import {StorageSlot} from "@openzeppelin/contracts/utils/StorageSlot.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Batch} from "./types/CoreTypes.sol";
import {WithdrawalToken} from "./WithdrawalToken.sol";

interface ICoreContract {
    function finalizedBatch(uint256) external view returns (Batch memory);
}

contract WithdrawalManager is
    Initializable,
    UUPSUpgradeable,
    ERC1155HolderUpgradeable,
    Ownable2StepUpgradeable
{
    struct WithdrawalManagerConfig {
        address coreContract;
        address wbtcContract;
        address withdrawalTokenContract;
    }

    struct PaidAmountStorage {
        mapping(uint256 => uint256) values;
    }

    // Custom errors
    error InvalidCoreContractAddress();
    error InvalidwBTCContractAddress();
    error InvalidWithdrawalTokenContractAddress();
    error BatchSupportNotEnabled();
    error InvalidWithdrawalToken();
    error ContractPaused();
    error RedemptionTokenSupplyIsZero();

    /// @dev keccak256(abi.encode(uint256(keccak256("maxbtc.withdrawal_manager.config")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CONFIG_STORAGE_SLOT =
        0x586b8ebd4b221736eefae7cfa16e8ed3b4ce4c3890765b521ad826b0ffedfd00;
    /// @dev keccak256(abi.encode(uint256(keccak256("maxbtc.withdrawal_manager.paid_amount")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PAID_AMOUNT_STORAGE_SLOT =
        0x8ee28e9cbcd498a9bd31513552accc39c2806ab50852fb31c37d622919337900;
    /// @dev keccak256(abi.encode(uint256(keccak256("maxbtc.withdrawal_manager.pause")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PAUSE_STORAGE_SLOT =
        0x67e38bbcda9028a2e19a608178c5c2c77532c8eeaf31e6b94ce02f730b76ac00;

    event Paused();
    event Unpaused();
    event ConfigUpdated(WithdrawalManagerConfig config);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        address _coreContract,
        address _wbtcContract,
        address _withdrawalTokenContract
    ) public initializer {
        if (_coreContract == address(0)) revert InvalidCoreContractAddress();
        if (_wbtcContract == address(0)) revert InvalidwBTCContractAddress();
        if (_withdrawalTokenContract == address(0))
            revert InvalidWithdrawalTokenContractAddress();
        __Ownable_init(owner_);
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
        WithdrawalManagerConfig storage config = _getWithdrawalManagerConfig();
        config.coreContract = _coreContract;
        config.wbtcContract = _wbtcContract;
        config.withdrawalTokenContract = _withdrawalTokenContract;
    }

    function onERC1155Received(
        address /*operator*/,
        address from,
        uint256 batchId,
        uint256 value,
        bytes memory /*data*/
    ) public override returns (bytes4) {
        require(!paused(), ContractPaused());

        WithdrawalManagerConfig storage config = _getWithdrawalManagerConfig();

        require(
            _msgSender() == address(config.withdrawalTokenContract),
            InvalidWithdrawalToken()
        );

        Batch memory finalizedBatch = ICoreContract(config.coreContract)
            .finalizedBatch(batchId);

        WithdrawalToken withdrawalToken = WithdrawalToken(
            config.withdrawalTokenContract
        );

        uint256 redemptionTokenSupply = withdrawalToken.totalSupply(batchId);
        if (redemptionTokenSupply == 0) {
            revert RedemptionTokenSupplyIsZero();
        }

        uint256 batchPaidAmount = getPaidAmount(batchId);
        uint256 availableBtc = finalizedBatch.collectedAmount - batchPaidAmount;
        uint256 userBtc = (availableBtc * value) / redemptionTokenSupply;

        batchPaidAmount += userBtc;
        _setPaidAmount(batchId, batchPaidAmount);

        withdrawalToken.burn(address(this), batchId, value);

        SafeERC20.safeTransfer(IERC20(config.wbtcContract), from, userBtc);

        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] memory,
        uint256[] memory,
        bytes memory
    ) public pure override returns (bytes4) {
        revert BatchSupportNotEnabled();
    }

    function updateConfig(
        address newCoreContract,
        address newWbtcContract,
        address newWithdrawalTokenContract
    ) external onlyOwner {
        WithdrawalManagerConfig storage config = _getWithdrawalManagerConfig();
        if (newCoreContract == address(0)) revert InvalidCoreContractAddress();
        if (newWbtcContract == address(0)) revert InvalidwBTCContractAddress();
        if (newWithdrawalTokenContract == address(0))
            revert InvalidWithdrawalTokenContractAddress();
        config.coreContract = newCoreContract;
        config.wbtcContract = newWbtcContract;
        config.withdrawalTokenContract = newWithdrawalTokenContract;
        emit ConfigUpdated(config);
    }

    function _getWithdrawalManagerConfig()
        private
        pure
        returns (WithdrawalManagerConfig storage $)
    {
        assembly {
            $.slot := CONFIG_STORAGE_SLOT
        }
    }

    function _paidAmount() internal pure returns (PaidAmountStorage storage $) {
        assembly {
            $.slot := PAID_AMOUNT_STORAGE_SLOT
        }
    }

    function _setPaidAmount(uint256 batchId, uint256 value) internal {
        _paidAmount().values[batchId] = value;
    }

    function getPaidAmount(uint256 batchId) public view returns (uint256) {
        return _paidAmount().values[batchId];
    }

    function paused() public view returns (bool) {
        return StorageSlot.getBooleanSlot(PAUSE_STORAGE_SLOT).value;
    }

    function setPause(bool newPauseState) external onlyOwner {
        StorageSlot.getBooleanSlot(PAUSE_STORAGE_SLOT).value = newPauseState;
        if (newPauseState) {
            emit Paused();
        } else {
            emit Unpaused();
        }
    }

    function getConfig() public pure returns (WithdrawalManagerConfig memory) {
        WithdrawalManagerConfig storage config = _getWithdrawalManagerConfig();
        return config;
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}
}
