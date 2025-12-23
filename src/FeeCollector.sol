// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    ReentrancyGuardUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {
    Initializable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    UUPSUpgradeable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    Ownable2StepUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IReceiver {
    /// Returns current exchange rate and timestamp of publication.
    /// exchange rate is represented as fixed-point 1e18.
    function getLatest() external view returns (uint256 _er, uint256 _ts);
}

interface ICoreContract {
    function mintFee(uint256 amount) external;
}

contract FeeCollector is
    Initializable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    Ownable2StepUpgradeable
{
    using SafeERC20 for IERC20;

    uint256 private constant ONE = 1e18;
    uint256 private constant MIN_COLLECTION_PERIOD_SECONDS = 60 * 60; // one hour
    uint256 private constant MAX_COLLECTION_PERIOD_SECONDS = 60 * 60 * 24 * 30; // one month

    struct Config {
        address coreContract;
        address erReceiver;
        /// Percentage of APY reduction taken as protocol fee.
        /// Represented in fixed-point 1e18 (1e18 = 1.0).
        uint256 feeApyReductionPercentage;
        /// Minimal time between fee collections, in seconds.
        uint256 collectionPeriodSeconds;
        /// ERC-20 fee token (maxBTC).
        IERC20 feeToken;
    }

    struct State {
        /// Timestamp of the last successful fee collection.
        uint256 lastCollectionTimestamp;
        /// Exchange rate recorded after the last fee collection (fixed-point 1e18).
        uint256 lastExchangeRate;
    }

    // Errors
    error InvalidRecipientAddress();
    error InvalidCoreContractAddress();
    error InvalidFeeTokenAddress();
    error InvalidFeeReductionPercentage();
    error CollectionPeriodNotElapsed();
    error NegativeOrZeroApy(uint256 currentRate, uint256 lastRate);
    error InvalidZeroAmount();
    error InvalidErReceiverAddress();
    error InvalidCollectionPeriodSeconds();

    /// @notice Emitted when fees are collected and minted to the core contract.
    event FeeCollected(
        uint256 mintedAmount,
        uint256 currentExchangeRate,
        uint256 previousExchangeRate,
        uint256 totalSupplyBefore
    );

    /// @notice Emitted when the owner claims accumulated fees.
    event FeeClaimed(address indexed recipient, uint256 amount);

    /// @notice Emitted when configuration is updated.
    event ConfigUpdated(
        address coreContract,
        address erReceiver,
        uint256 feeApyReductionPercentage,
        uint64 collectionPeriodSeconds
    );

    /// @dev keccak256(abi.encode(uint256(keccak256("maxbtc.fee_collector.config")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CONFIG_STORAGE_SLOT =
        0x55a5612efb3791db0b287c4f2521a452b64dc8c1ea03edaa7b8f0870c0bd6300;

    /// @dev keccak256(abi.encode(uint256(keccak256("maxbtc.fee_collector.state")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STATE_STORAGE_SLOT =
        0x966789e57aed537e5e5c5502b1c3700bbababa9893769d9edb5dcfab993bfe00;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        address coreContract_,
        address erReceiver_,
        uint256 feeApyReductionPercentage_,
        uint64 collectionPeriodSeconds_,
        address feeToken_
    ) external initializer {
        if (coreContract_ == address(0)) revert InvalidCoreContractAddress();
        if (erReceiver_ == address(0)) revert InvalidErReceiverAddress();
        if (feeToken_ == address(0)) revert InvalidFeeTokenAddress();
        if (
            feeApyReductionPercentage_ == 0 || feeApyReductionPercentage_ >= ONE
        ) {
            revert InvalidFeeReductionPercentage();
        }
        if (
            collectionPeriodSeconds_ < MIN_COLLECTION_PERIOD_SECONDS ||
            collectionPeriodSeconds_ > MAX_COLLECTION_PERIOD_SECONDS
        ) {
            revert InvalidCollectionPeriodSeconds();
        }

        __Ownable_init(owner_);
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        Config storage config = _getConfig();
        config.coreContract = coreContract_;
        config.erReceiver = erReceiver_;
        config.feeApyReductionPercentage = feeApyReductionPercentage_;
        config.collectionPeriodSeconds = collectionPeriodSeconds_;
        config.feeToken = IERC20(feeToken_);

        (uint256 initialRate, ) = IReceiver(erReceiver_).getLatest();

        State storage st = _getState();
        st.lastCollectionTimestamp = block.timestamp;
        st.lastExchangeRate = initialRate;
    }

    function collectFee() external nonReentrant {
        Config storage config = _getConfig();
        State storage st = _getState();

        uint256 nextAllowed = st.lastCollectionTimestamp +
            config.collectionPeriodSeconds;

        if (block.timestamp < nextAllowed) {
            revert CollectionPeriodNotElapsed();
        }

        (uint256 currentRate, ) = IReceiver(config.erReceiver).getLatest();

        uint256 totalSupply = config.feeToken.totalSupply();

        if (currentRate <= st.lastExchangeRate) {
            revert NegativeOrZeroApy(currentRate, st.lastExchangeRate);
        }

        uint256 previousRate = st.lastExchangeRate;
        uint256 toMint = calculateFeeToMint(
            previousRate,
            currentRate,
            totalSupply,
            config.feeApyReductionPercentage
        );

        if (toMint == 0) {
            return;
        }

        ICoreContract(config.coreContract).mintFee(toMint);

        st.lastExchangeRate = currentRate;
        st.lastCollectionTimestamp = uint64(block.timestamp);

        emit FeeCollected(toMint, currentRate, previousRate, totalSupply);
    }

    function claim(uint256 amount, address recipient) external onlyOwner {
        if (amount == 0) revert InvalidZeroAmount();
        if (recipient == address(0)) revert InvalidRecipientAddress();

        Config storage config = _getConfig();
        config.feeToken.safeTransfer(recipient, amount);

        emit FeeClaimed(recipient, amount);
    }

    function updateConfig(
        address newCoreContract,
        address newErReceiver,
        uint256 newFeeApyReductionPercentage,
        uint64 newCollectionPeriodSeconds
    ) external onlyOwner {
        if (newCoreContract == address(0)) revert InvalidCoreContractAddress();
        if (newErReceiver == address(0)) revert InvalidErReceiverAddress();
        if (
            newFeeApyReductionPercentage == 0 ||
            newFeeApyReductionPercentage >= ONE
        ) {
            revert InvalidFeeReductionPercentage();
        }
        if (
            newCollectionPeriodSeconds < MIN_COLLECTION_PERIOD_SECONDS ||
            newCollectionPeriodSeconds > MAX_COLLECTION_PERIOD_SECONDS
        ) {
            revert InvalidCollectionPeriodSeconds();
        }

        Config storage config = _getConfig();
        config.coreContract = newCoreContract;
        config.erReceiver = newErReceiver;
        config.feeApyReductionPercentage = newFeeApyReductionPercentage;
        config.collectionPeriodSeconds = newCollectionPeriodSeconds;

        emit ConfigUpdated(
            newCoreContract,
            newErReceiver,
            newFeeApyReductionPercentage,
            newCollectionPeriodSeconds
        );
    }

    function getConfig() external pure returns (Config memory) {
        Config storage config = _getConfig();
        return config;
    }

    function getState() external pure returns (State memory) {
        State storage st = _getState();
        return st;
    }

    function _getConfig() private pure returns (Config storage s) {
        bytes32 slot = CONFIG_STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    function _getState() private pure returns (State storage s) {
        bytes32 slot = STATE_STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    function calculateFeeToMint(
        uint256 rateOld,
        uint256 rateCurrent,
        uint256 totalSupplyCurrent,
        uint256 feeReductionPercentage
    ) public pure returns (uint256) {
        if (rateCurrent <= rateOld) return 0;

        uint256 gain = rateCurrent - rateOld;
        uint256 retained = ONE - feeReductionPercentage;

        uint256 targetGain = (gain * retained) / ONE;
        uint256 rateTarget = rateOld + targetGain;
        if (rateTarget == 0) return 0;

        uint256 rateRatio = (rateCurrent * ONE) / rateTarget;
        if (rateRatio <= ONE) return 0;

        uint256 factor = rateRatio - ONE;

        uint256 feeAtomic = (factor * totalSupplyCurrent) / ONE;

        return feeAtomic;
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}
}
