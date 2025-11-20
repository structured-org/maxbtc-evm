// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ITwaerProvider {
    /// Returns current exchange rate (twaer) and timestamp of publication.
    /// twaer is represented as fixed-point 1e18.
    function getTwaer()
        external
        view
        returns (uint256 twaer, uint64 publishedAt);
}

interface ICoreContract {
    function mintFee(uint256 amount) external;
}

contract FeeCollector is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    using SafeERC20 for IERC20;

    uint256 private constant ONE = 1e18;

    struct Config {
        address coreContract;
        /// Percentage of APY reduction taken as protocol fee.
        /// Represented in fixed-point 1e18 (1e18 = 1.0).
        uint256 feeApyReductionPercentage;
        /// Minimal time between fee collections, in seconds.
        uint64 collectionPeriodSeconds;
        /// ERC-20 fee token (maxBTC).
        IERC20 feeToken;
        /// Number of decimals of maxBTC (must be <= 18).
        uint8 maxbtcDecimals;
    }

    struct State {
        /// Timestamp of the last successful fee collection.
        uint64 lastCollectionTimestamp;
        /// Exchange rate recorded after the last fee collection (fixed-point 1e18).
        uint256 lastExchangeRate;
    }

    // Errors
    error InvalidOwnerAddress();
    error InvalidRecipientAddress();
    error InvalidCoreContractAddress();
    error InvalidFeeTokenAddress();
    error InvalidFeeReductionPercentage();
    error InvalidDecimalConversion();
    error CollectionPeriodNotElapsed();
    error NegativeOrZeroApy(uint256 currentRate, uint256 lastRate);
    error InvalidZeroAmount();

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
        uint256 feeApyReductionPercentage_,
        uint64 collectionPeriodSeconds_,
        address feeToken_,
        uint8 maxbtcDecimals_
    ) external initializer {
        if (owner_ == address(0)) revert InvalidOwnerAddress();
        if (coreContract_ == address(0)) revert InvalidCoreContractAddress();
        if (feeToken_ == address(0)) revert InvalidFeeTokenAddress();
        if (
            feeApyReductionPercentage_ == 0 || feeApyReductionPercentage_ >= ONE
        ) {
            revert InvalidFeeReductionPercentage();
        }
        if (maxbtcDecimals_ > 18) revert InvalidDecimalConversion();

        __Ownable_init(owner_);
        __UUPSUpgradeable_init();

        Config storage config = _getConfig();
        config.coreContract = coreContract_;
        config.feeApyReductionPercentage = feeApyReductionPercentage_;
        config.collectionPeriodSeconds = collectionPeriodSeconds_;
        config.feeToken = IERC20(feeToken_);
        config.maxbtcDecimals = maxbtcDecimals_;

        (uint256 initialRate, ) = ITwaerProvider(coreContract_).getTwaer();

        State storage st = _getState();
        st.lastCollectionTimestamp = uint64(block.timestamp);
        st.lastExchangeRate = initialRate;
    }

    function collectFee() external {
        Config storage config = _getConfig();
        State storage st = _getState();

        uint256 nextAllowed = uint256(st.lastCollectionTimestamp) +
            uint256(config.collectionPeriodSeconds);

        if (block.timestamp < nextAllowed) {
            revert CollectionPeriodNotElapsed();
        }

        (uint256 currentRate, ) = ITwaerProvider(config.coreContract)
            .getTwaer();

        uint256 totalSupply = config.feeToken.totalSupply();

        if (currentRate <= st.lastExchangeRate) {
            revert NegativeOrZeroApy(currentRate, st.lastExchangeRate);
        }

        uint256 toMint = calculateFeeToMint(
            st.lastExchangeRate,
            currentRate,
            totalSupply,
            config.feeApyReductionPercentage,
            config.maxbtcDecimals
        );

        if (toMint == 0) {
            return;
        }

        ICoreContract(config.coreContract).mintFee(toMint);

        st.lastCollectionTimestamp = uint64(block.timestamp);
        st.lastExchangeRate = currentRate;
    }

    function claim(uint256 amount, address recipient) external onlyOwner {
        if (amount == 0) revert InvalidZeroAmount();
        if (recipient == address(0)) revert InvalidRecipientAddress();

        Config storage config = _getConfig();
        config.feeToken.safeTransfer(recipient, amount);
    }

    function updateConfig(
        address newCoreContract,
        uint256 newFeeApyReductionPercentage,
        uint64 newCollectionPeriodSeconds
    ) external onlyOwner {
        if (newCoreContract == address(0)) revert InvalidCoreContractAddress();
        if (
            newFeeApyReductionPercentage == 0 ||
            newFeeApyReductionPercentage >= ONE
        ) {
            revert InvalidFeeReductionPercentage();
        }

        Config storage config = _getConfig();
        config.coreContract = newCoreContract;
        config.feeApyReductionPercentage = newFeeApyReductionPercentage;
        config.collectionPeriodSeconds = newCollectionPeriodSeconds;

        (uint256 initialRate, ) = ITwaerProvider(newCoreContract).getTwaer();

        State storage st = _getState();
        st.lastCollectionTimestamp = uint64(block.timestamp);
        st.lastExchangeRate = initialRate;
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
        uint256 feeReductionPercentage,
        uint8 maxbtcDecimals
    ) public pure returns (uint256) {
        if (rateCurrent <= rateOld) return 0;
        if (maxbtcDecimals > 18) revert InvalidDecimalConversion();

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
