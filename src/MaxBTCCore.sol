// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28;

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
import {
    IERC20Metadata
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {MaxBTCERC20} from "./MaxBTCERC20.sol";
import {WithdrawalToken} from "./WithdrawalToken.sol";
import {WaitosaurHolder} from "./WaitosaurHolder.sol";
import {Batch} from "./types/CoreTypes.sol";
import {IExchangeRateProvider} from "./types/IExchangeRateProvider.sol";
import {WaitosaurObserver} from "./WaitosaurObserver.sol";
import {Allowlist} from "./Allowlist.sol";

/// @notice Core settlement logic for the maxBTC protocol.
contract MaxBTCCore is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable {
    struct CoreConfig {
        address depositToken;
        address maxBtcToken;
        address withdrawalToken;
        address exchangeRateProvider;
        address depositForwarder;
        address waitosaurObserver;
        address waitosaurHolder;
        address allowlist;
        address feeCollector;
        address withdrawalManager;
        address operator;
        uint256 exchangeRateStalePeriod;
        uint256 depositCost; // 1e18 precision
        uint256 withdrawalCost; // 1e18 precision
        uint256 depositsCap; // optional, deposit token decimals
        bool capEnabled;
        bool paused;
    }

    enum ContractState {
        Idle,
        DepositEthereum,
        DepositPending,
        DepositJlp,
        WithdrawJlp,
        WithdrawPending,
        WithdrawEthereum
    }

    /// @notice Events

    event Deposit(
        address indexed depositor,
        address indexed recipient,
        uint256 depositAmount,
        uint256 maxBtcMinted
    );

    event Withdrawal(
        address indexed withdrawer,
        uint256 maxBtcBurned,
        uint256 batchId
    );

    event BatchProcessed(
        uint256 indexed batchId,
        uint256 btcRequested,
        uint256 collectedAmount,
        bool finalized
    );

    event TickIdle();
    event TickDepositEthereum();
    event TickDepositPending();
    event TickDepositJlp();
    event TickWithdrawJlp();
    event TickWithdrawPending(uint256 lockedAmount);
    event TickWithdrawEthereumFinalized(uint256 batchId);

    event WithdrawingBatchFinalized(
        uint256 indexed batchId,
        uint256 collectedAmount
    );
    event PausedUpdated(bool paused);
    event OperatorUpdated(address operator);
    event FeeCollectorUpdated(address feeCollector);
    event AllowlistUpdated(address allowlist);
    event ExchangeRateProviderUpdated(address provider);
    event WithdrawalManagerUpdated(address withdrawalManager);
    event CostsUpdated(uint256 depositCost, uint256 withdrawalCost);
    event DepositsCapUpdated(uint256 depositsCap, bool capEnabled);
    event DepositForwarderUpdated(address depositForwarder);
    event WaitosaurObserverUpdated(address waitosaurObserver);
    event WaitosaurHolderUpdated(address waitosaurHolder);
    event MintedByOwner(address indexed recipient, uint256 amount);
    event FeeMinted(address indexed to, uint256 amount);

    /// @notice Errors

    error InvalidDepositTokenAddress();
    error InvalidDepositAmount();
    error InvalidMaxBTCTokenAddress();
    error InvalidWithdrawalTokenAddress();
    error InvalidExchangeRateReceiverAddress();
    error InvalidDepositForwarderAddress();
    error InvalidWaitosaurObserverAddress();
    error InvalidWaitosaurHolderAddress();
    error InvalidAllowlistAddress();
    error InvalidFeeCollectorAddress();
    error InvalidWithdrawalManagerAddress();
    error InvalidOperatorAddress();
    error ExchangeRateStale();
    error WithdrawingBatchAlreadyExists();
    error WithdrawingBatchMissing();
    error FinalizedBatchMissing(uint256 batchId);
    error ContractPaused();
    error AddressNotAllowed(address account);
    error DepositCapExceeded();
    error InvalidRecipient();
    error InvalidAmount();
    error FeeTooHigh();
    error SlippageLimitExceeded(uint256 requested, uint256 actual);
    error WaitosaurLocked();
    error AumMustBePositive();

    /// @dev keccak256(abi.encode(uint256(keccak256("maxbtc.core.config")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CONFIG_STORAGE_SLOT =
        0xe8041c5a119ce847809f9491390b5e4b81852379983e998195264ecb0ca5b100;
    /// @dev keccak256(abi.encode(uint256(keccak256("maxbtc.core.batch_state")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BATCH_STATE_STORAGE_SLOT =
        0xcd680cc7c8e435be1f7479ad5e3bda309608af714cd2b7b35d4d58c3c8569700;
    /// @dev keccak256(abi.encode(uint256(keccak256("maxbtc.core.finalized_batches")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant FINALIZED_BATCHES_STORAGE_SLOT =
        0x6ba6b86991a1f4fd0c4351857af540e99efdf5c523d2e0e4d1a5236d81710f00;
    /// @dev keccak256(abi.encode(uint256(keccak256("maxbtc.core.fsm_state")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant FSM_STORAGE_SLOT =
        0x6bffc8143743f0d5390d797c32fc2305b8f8757da76d1c170e18732d7a87fb00;

    struct BatchState {
        Batch activeBatch;
        Batch withdrawingBatch;
        bool hasWithdrawingBatch;
    }

    struct FinalizedBatchesStorage {
        mapping(uint256 => Batch) batches;
        uint256[] finalizedBatchIds;
    }

    modifier onlyOperatorOrOwner() {
        _onlyOperatorOrOwner();
        _;
    }

    function _onlyOperatorOrOwner() internal view {
        CoreConfig storage config = _getCoreConfig();
        if (_msgSender() != owner() && _msgSender() != config.operator) {
            revert InvalidOperatorAddress();
        }
    }

    modifier notPaused() {
        _notPaused();
        _;
    }

    function _notPaused() internal view {
        CoreConfig storage config = _getCoreConfig();
        if (config.paused) {
            revert ContractPaused();
        }
    }

    modifier onlyAllowlisted(address account) {
        _onlyAllowlisted(account);
        _;
    }

    function _onlyAllowlisted(address account) internal view {
        CoreConfig storage config = _getCoreConfig();
        if (!Allowlist(config.allowlist).isAddressAllowed(account)) {
            revert AddressNotAllowed(account);
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function _getCoreConfig() private pure returns (CoreConfig storage $) {
        assembly {
            $.slot := CONFIG_STORAGE_SLOT
        }
    }

    function _state() private view returns (ContractState) {
        uint256 value;
        assembly {
            value := sload(FSM_STORAGE_SLOT)
        }
        return ContractState(value);
    }

    function _setState(ContractState newState) private {
        assembly {
            sstore(FSM_STORAGE_SLOT, newState)
        }
    }

    function initialize(
        address owner_,
        address depositToken_,
        address maxBtcToken_,
        address withdrawalToken_,
        address exchangeRateProvider_,
        address depositForwarder_,
        address waitosaurObserver_,
        address waitosaurHolder_,
        uint256 exchangeRateStalePeriod_,
        address allowlist_,
        address feeCollector_,
        address withdrawalManager_,
        address operator_,
        uint256 depositCost_,
        uint256 withdrawalCost_,
        uint256 depositsCap_,
        bool capEnabled_
    ) public initializer {
        __Ownable_init(owner_);
        __Ownable2Step_init();
        if (depositToken_ == address(0)) {
            revert InvalidDepositTokenAddress();
        }
        if (maxBtcToken_ == address(0)) {
            revert InvalidMaxBTCTokenAddress();
        }
        if (withdrawalToken_ == address(0)) {
            revert InvalidWithdrawalTokenAddress();
        }
        if (exchangeRateProvider_ == address(0)) {
            revert InvalidExchangeRateReceiverAddress();
        }
        if (depositForwarder_ == address(0)) {
            revert InvalidDepositForwarderAddress();
        }
        if (waitosaurObserver_ == address(0)) {
            revert InvalidWaitosaurObserverAddress();
        }
        if (waitosaurHolder_ == address(0)) {
            revert InvalidWaitosaurHolderAddress();
        }
        if (feeCollector_ == address(0)) {
            revert InvalidFeeCollectorAddress();
        }
        if (withdrawalManager_ == address(0)) {
            revert InvalidWithdrawalManagerAddress();
        }
        if (operator_ == address(0)) {
            revert InvalidOperatorAddress();
        }
        if (allowlist_ == address(0)) {
            revert InvalidAllowlistAddress();
        }
        if (depositCost_ >= 1e18 || withdrawalCost_ >= 1e18) {
            revert FeeTooHigh();
        }
        CoreConfig storage config = _getCoreConfig();
        config.depositToken = depositToken_;
        config.maxBtcToken = maxBtcToken_;
        config.withdrawalToken = withdrawalToken_;
        config.exchangeRateProvider = exchangeRateProvider_;
        config.depositForwarder = depositForwarder_;
        config.waitosaurObserver = waitosaurObserver_;
        config.waitosaurHolder = waitosaurHolder_;
        config.exchangeRateStalePeriod = exchangeRateStalePeriod_;
        config.allowlist = allowlist_;
        config.feeCollector = feeCollector_;
        config.withdrawalManager = withdrawalManager_;
        config.operator = operator_;
        config.depositCost = depositCost_;
        config.withdrawalCost = withdrawalCost_;
        config.depositsCap = depositsCap_;
        config.capEnabled = capEnabled_;
        config.paused = false;

        BatchState storage batchState = _getBatchState();
        batchState.activeBatch = _createNewBatch(0);
        _setState(ContractState.Idle);
    }

    function _getBatchState() private pure returns (BatchState storage $) {
        assembly {
            $.slot := BATCH_STATE_STORAGE_SLOT
        }
    }

    function _getFinalizedBatchesStorage()
        private
        pure
        returns (FinalizedBatchesStorage storage $)
    {
        assembly {
            $.slot := FINALIZED_BATCHES_STORAGE_SLOT
        }
    }

    function _depositDecimals() private view returns (uint256) {
        CoreConfig storage config = _getCoreConfig();
        return uint256(IERC20Metadata(config.depositToken).decimals());
    }

    function _createNewBatch(
        uint256 batchId
    ) private view returns (Batch memory) {
        return
            Batch({
                batchId: batchId,
                btcRequested: 0,
                maxBtcBurned: 0,
                collectedAmount: 0,
                collectorHistoricalBalance: 0,
                depositDecimals: _depositDecimals()
            });
    }

    function _activeBatch() private view returns (Batch storage) {
        BatchState storage batchState = _getBatchState();
        return batchState.activeBatch;
    }

    function activeBatch() external view returns (Batch memory) {
        Batch storage currentBatch = _activeBatch();
        return currentBatch;
    }

    function withdrawingBatch() external view returns (Batch memory, bool) {
        BatchState storage batchState = _getBatchState();
        return (batchState.withdrawingBatch, batchState.hasWithdrawingBatch);
    }

    function finalizedBatch(
        uint256 batchId
    ) public view returns (Batch memory) {
        FinalizedBatchesStorage
            storage finalized = _getFinalizedBatchesStorage();
        Batch memory batch = finalized.batches[batchId];
        if (batch.depositDecimals == 0) {
            revert FinalizedBatchMissing(batchId);
        }
        return batch;
    }

    /// @notice Returns finalized batches in range [start; start+limit)
    /// @param start Index of first batch to retrieve (returns empty array if out of range)
    /// @param limit Maximum number of batches to retrieve (defaults to 10 if 0 provided, cannot exceed 100)
    function finalizedBatches(uint256 start, uint256 limit) external view returns (Batch[] memory) {
        FinalizedBatchesStorage
            storage finalized = _getFinalizedBatchesStorage();
        uint256 length = finalized.finalizedBatchIds.length;

        if (start >= length) {
            return new Batch[](0);
        }
        if (limit == 0) {
            limit = 10;
        }
        if (limit > 100) {
            limit = 100;
        }
        if (start + limit >= length) {
            limit = length - start;
        }

        Batch[] memory batches = new Batch[](limit);
        for (uint256 i = 0; i < limit; i++) {
            uint256 batchId = finalized.finalizedBatchIds[start + i];
            batches[i] = finalized.batches[batchId];
        }
        return batches;
    }

    function _addFinalizedBatch(Batch memory batch) internal {
        FinalizedBatchesStorage
            storage finalized = _getFinalizedBatchesStorage();
        finalized.batches[batch.batchId] = batch;
        finalized.finalizedBatchIds.push(batch.batchId);
    }

    function contractState() external view returns (ContractState) {
        return _state();
    }

    function setPaused(bool newPaused) external onlyOwner {
        CoreConfig storage config = _getCoreConfig();
        config.paused = newPaused;
        emit PausedUpdated(newPaused);
    }

    function setOperator(address newOperator) external onlyOwner {
        if (newOperator == address(0)) {
            revert InvalidOperatorAddress();
        }
        CoreConfig storage config = _getCoreConfig();
        config.operator = newOperator;
        emit OperatorUpdated(newOperator);
    }

    function setFeeCollector(address newFeeCollector) external onlyOwner {
        if (newFeeCollector == address(0)) {
            revert InvalidFeeCollectorAddress();
        }
        CoreConfig storage config = _getCoreConfig();
        config.feeCollector = newFeeCollector;
        emit FeeCollectorUpdated(newFeeCollector);
    }

    function setAllowlist(address newAllowlist) external onlyOwner {
        if (newAllowlist == address(0)) {
            revert InvalidAllowlistAddress();
        }
        CoreConfig storage config = _getCoreConfig();
        config.allowlist = newAllowlist;
        emit AllowlistUpdated(newAllowlist);
    }

    function setExchangeRateProvider(
        address newExchangeRateProvider
    ) external onlyOwner {
        if (newExchangeRateProvider == address(0)) {
            revert InvalidExchangeRateReceiverAddress();
        }
        CoreConfig storage config = _getCoreConfig();
        config.exchangeRateProvider = newExchangeRateProvider;
        emit ExchangeRateProviderUpdated(newExchangeRateProvider);
    }

    function setWithdrawalManager(
        address newWithdrawalManager
    ) external onlyOwner {
        if (newWithdrawalManager == address(0)) {
            revert InvalidWithdrawalManagerAddress();
        }
        CoreConfig storage config = _getCoreConfig();
        config.withdrawalManager = newWithdrawalManager;
        emit WithdrawalManagerUpdated(newWithdrawalManager);
    }

    function setDepositForwarder(
        address newDepositForwarder
    ) external onlyOwner {
        if (newDepositForwarder == address(0)) {
            revert InvalidDepositForwarderAddress();
        }
        CoreConfig storage config = _getCoreConfig();
        config.depositForwarder = newDepositForwarder;
        emit DepositForwarderUpdated(newDepositForwarder);
    }

    function setWaitosaurObserver(
        address newWaitosaurObserver
    ) external onlyOwner {
        if (newWaitosaurObserver == address(0)) {
            revert InvalidWaitosaurObserverAddress();
        }
        CoreConfig storage config = _getCoreConfig();
        config.waitosaurObserver = newWaitosaurObserver;
        emit WaitosaurObserverUpdated(newWaitosaurObserver);
    }

    function setWaitosaurHolder(address newWaitosaurHolder) external onlyOwner {
        if (newWaitosaurHolder == address(0)) {
            revert InvalidWaitosaurHolderAddress();
        }
        CoreConfig storage config = _getCoreConfig();
        config.waitosaurHolder = newWaitosaurHolder;
        emit WaitosaurHolderUpdated(newWaitosaurHolder);
    }

    function setCosts(
        uint256 newDepositCost,
        uint256 newWithdrawalCost
    ) external onlyOwner {
        if (newDepositCost >= 1e18 || newWithdrawalCost >= 1e18) {
            revert FeeTooHigh();
        }
        CoreConfig storage config = _getCoreConfig();
        config.depositCost = newDepositCost;
        config.withdrawalCost = newWithdrawalCost;
        emit CostsUpdated(newDepositCost, newWithdrawalCost);
    }

    function setDepositsCap(uint256 newCap, bool enabled) external onlyOwner {
        CoreConfig storage config = _getCoreConfig();
        config.depositsCap = newCap;
        config.capEnabled = enabled;
        emit DepositsCapUpdated(newCap, enabled);
    }

    /// @notice Owner-only mint of maxBTC
    /// @param amount Amount of maxBTC to mint (in 1e8 units)
    /// @param recipient Recipient address to receive the freshly minted maxBTC
    function mintByOwner(
        uint256 amount,
        address recipient
    ) external onlyOwner notPaused {
        if (recipient == address(0)) {
            revert InvalidRecipient();
        }
        CoreConfig storage config = _getCoreConfig();
        MaxBTCERC20(config.maxBtcToken).mint(recipient, amount);
        emit MintedByOwner(recipient, amount);
    }

    /// @notice Fee collector mints protocol fee to itself
    /// @param amount Amount of maxBTC to mint (in 1e8 units)
    function mintFee(uint256 amount) external notPaused {
        CoreConfig storage config = _getCoreConfig();
        if (_msgSender() != config.feeCollector) {
            revert InvalidFeeCollectorAddress();
        }

        (int256 aumRaw, ) = IExchangeRateProvider(config.exchangeRateProvider)
            .getAum();
        if (aumRaw <= 0) {
            revert AumMustBePositive();
        }

        MaxBTCERC20(config.maxBtcToken).mint(_msgSender(), amount);
        emit FeeMinted(_msgSender(), amount);
    }

    function deposit(
        uint256 amount,
        address recipient,
        uint256 minReceiveAmount
    ) external notPaused onlyAllowlisted(recipient) {
        CoreConfig storage config = _getCoreConfig();
        if (recipient == address(0)) {
            revert InvalidRecipient();
        }
        if (amount == 0) {
            revert InvalidAmount();
        }

        _checkDepositCap(config, amount);

        (uint256 exchangeRate, uint256 lastUpdated) = _getExchangeRate(config);
        if (block.timestamp - lastUpdated >= config.exchangeRateStalePeriod) {
            revert ExchangeRateStale();
        }

        uint256 maxBtcToMint = _calculateMintAmount(
            amount,
            exchangeRate,
            config.depositCost
        );
        if (maxBtcToMint == 0) {
            revert InvalidAmount();
        }
        if (minReceiveAmount != 0 && maxBtcToMint < minReceiveAmount) {
            revert SlippageLimitExceeded(minReceiveAmount, maxBtcToMint);
        }

        SafeERC20.safeTransferFrom(
            IERC20(config.depositToken),
            msg.sender,
            address(this),
            amount
        );

        MaxBTCERC20(config.maxBtcToken).mint(recipient, maxBtcToMint);
        emit Deposit(msg.sender, recipient, amount, maxBtcToMint);
    }

    function withdraw(
        uint256 maxBtcAmount
    ) external notPaused onlyAllowlisted(_msgSender()) {
        CoreConfig storage config = _getCoreConfig();
        if (maxBtcAmount == 0) {
            revert InvalidAmount();
        }

        Batch storage batch = _activeBatch();
        batch.maxBtcBurned += maxBtcAmount;
        MaxBTCERC20(config.maxBtcToken).burn(_msgSender(), maxBtcAmount);
        uint256 batchId = batch.batchId;
        WithdrawalToken(config.withdrawalToken).mint(
            _msgSender(),
            batchId,
            maxBtcAmount,
            ""
        );
        emit Withdrawal(_msgSender(), maxBtcAmount, batchId);
    }

    /// @notice Processes the active batch using available deposits.
    /// @dev It offsets withdrawals with deposits, sends fees to the
    /// collector, and either finalizes or moves the batch to
    /// WITHDRAWING for off-chain settlement.
    function tick()
        external
        notPaused
        onlyOperatorOrOwner
        returns (bool finalized)
    {
        CoreConfig storage config = _getCoreConfig();
        ContractState state = _state();
        BatchState storage batchState = _getBatchState();
        Batch memory batch = batchState.activeBatch;
        uint256 depositBalance = IERC20(config.depositToken).balanceOf(
            address(this)
        );

        if (state == ContractState.Idle) {
            if (batch.maxBtcBurned > 0) {
                finalized = _processWithdrawals(
                    config,
                    batchState,
                    batch,
                    depositBalance
                );
                if (!finalized) {
                    _setState(ContractState.WithdrawJlp);
                }
                return (finalized);
            }
            if (depositBalance > 0) {
                _flushDeposits(config, depositBalance);
                _setState(ContractState.DepositEthereum);
            }
            emit TickIdle();
            return (finalized);
        }

        if (state == ContractState.DepositEthereum) {
            _ensureWaitosaurUnlocked(config);
            _setState(ContractState.DepositPending);
            emit TickDepositEthereum();
            return (false);
        }
        if (state == ContractState.DepositPending) {
            _setState(ContractState.DepositJlp);
            emit TickDepositPending();
            return (false);
        }
        if (state == ContractState.DepositJlp) {
            _setState(ContractState.Idle);
            emit TickDepositJlp();
            return (false);
        }

        if (state == ContractState.WithdrawJlp) {
            _setState(ContractState.WithdrawPending);
            emit TickWithdrawJlp();
            return (false);
        }
        if (state == ContractState.WithdrawPending) {
            WaitosaurHolder holder = WaitosaurHolder(config.waitosaurHolder);
            uint256 lockedAmount = holder.lockedAmount();
            if (lockedAmount > 0) {
                batchState.withdrawingBatch.collectedAmount += lockedAmount;
                holder.unlock();
            }
            _setState(ContractState.WithdrawEthereum);
            emit TickWithdrawPending(lockedAmount);
            return (false);
        }
        if (state == ContractState.WithdrawEthereum) {
            _finalizeWithdrawingBatch(batchState.withdrawingBatch);
            _setState(ContractState.Idle);
            finalized = true;
            emit TickWithdrawEthereumFinalized(
                batchState.withdrawingBatch.batchId
            );
            return (finalized);
        }
    }

    /// @notice Finalizes the pending withdrawing batch after off-chain settlement.
    function _finalizeWithdrawingBatch(Batch memory withdrawing) internal {
        BatchState storage batchState = _getBatchState();
        if (!batchState.hasWithdrawingBatch) {
            revert WithdrawingBatchMissing();
        }

        _addFinalizedBatch(withdrawing);
        delete batchState.withdrawingBatch;
        batchState.hasWithdrawingBatch = false;

        emit WithdrawingBatchFinalized(
            withdrawing.batchId,
            withdrawing.collectedAmount
        );
    }

    function finalizeWithdrawingBatch(
        uint256 totalCollectedAmount
    ) external notPaused onlyOperatorOrOwner {
        BatchState storage batchState = _getBatchState();
        if (!batchState.hasWithdrawingBatch) {
            revert WithdrawingBatchMissing();
        }
        Batch memory withdrawing = batchState.withdrawingBatch;
        if (totalCollectedAmount < withdrawing.collectedAmount) {
            revert InvalidAmount();
        }
        uint256 additional = totalCollectedAmount - withdrawing.collectedAmount;
        CoreConfig storage config = _getCoreConfig();
        if (additional > 0) {
            SafeERC20.safeTransfer(
                IERC20(config.depositToken),
                config.withdrawalManager,
                additional
            );
        }
        withdrawing.collectedAmount = totalCollectedAmount;
        _finalizeWithdrawingBatch(withdrawing);
        _setState(ContractState.Idle);
    }

    function _ensureWaitosaurUnlocked(CoreConfig storage config) private view {
        if (WaitosaurObserver(config.waitosaurObserver).lockedAmount() > 0) {
            revert WaitosaurLocked();
        }
    }

    function _processWithdrawals(
        CoreConfig storage config,
        BatchState storage batchState,
        Batch memory batch,
        uint256 depositBalance
    ) private returns (bool finalized) {
        (uint256 exchangeRate, uint256 lastUpdated) = _getExchangeRate(config);
        if (block.timestamp - lastUpdated >= config.exchangeRateStalePeriod) {
            revert ExchangeRateStale();
        }

        batch.btcRequested = (batch.maxBtcBurned * exchangeRate) / 1e18;

        // depositBeforeFees = ceil(btcRequested / (1 - depositCost))
        uint256 depositBeforeFees = _ceilDiv(
            batch.btcRequested * 1e18,
            1e18 - config.depositCost
        );

        // It calculates how much of the withdrawal can be offset using the deposits.
        // Compares two values: the total amount of available deposits and the calculated
        // amount of BTC withdrawals plus withdrawal costs, and takes the lesser of the two.
        // This ensures that we do not exceed the available deposits.
        uint256 offsettingAmountFull = depositBeforeFees <= depositBalance
            ? depositBeforeFees
            : depositBalance;

        uint256 offsettingAfterDepositCost = (offsettingAmountFull *
            (1e18 - config.depositCost)) / 1e18;
        uint256 offsettingAmount = (offsettingAfterDepositCost *
            (1e18 - config.withdrawalCost)) / 1e18;

        uint256 offsettingCost = offsettingAmountFull - offsettingAmount;

        batch.collectedAmount = offsettingAmount;

        if (offsettingAmount > 0) {
            SafeERC20.safeTransfer(
                IERC20(config.depositToken),
                config.withdrawalManager,
                offsettingAmount
            );
        }
        if (offsettingCost > 0) {
            SafeERC20.safeTransfer(
                IERC20(config.depositToken),
                config.feeCollector,
                offsettingCost
            );
        }

        if (depositBeforeFees <= depositBalance) {
            _addFinalizedBatch(batch);
            finalized = true;
        } else {
            if (batchState.hasWithdrawingBatch) {
                revert WithdrawingBatchAlreadyExists();
            }
            batchState.withdrawingBatch = batch;
            batchState.hasWithdrawingBatch = true;
        }

        batchState.activeBatch = _createNewBatch(batch.batchId + 1);

        emit BatchProcessed(
            batch.batchId,
            batch.btcRequested,
            batch.collectedAmount,
            finalized
        );
    }

    function _flushDeposits(
        CoreConfig storage config,
        uint256 depositBalance
    ) private {
        if (depositBalance == 0) {
            return;
        }

        WaitosaurObserver(config.waitosaurObserver).lock(depositBalance);

        SafeERC20.safeTransfer(
            IERC20(config.depositToken),
            config.depositForwarder,
            depositBalance
        );
    }

    function _checkDepositCap(
        CoreConfig storage config,
        uint256 depositAmount
    ) private view {
        if (!config.capEnabled) {
            return;
        }
        (int256 aumRaw, uint8 decimals) = IExchangeRateProvider(
            config.exchangeRateProvider
        ).getAum();
        if (aumRaw < 0) {
            revert DepositCapExceeded();
        }

        uint256 scaledAum = _scaleAmount(
            // casting to 'uint256' is safe because aumRaw is always positive
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256(aumRaw),
            decimals,
            _depositDecimals()
        );
        if (scaledAum + depositAmount > config.depositsCap) {
            revert DepositCapExceeded();
        }
    }

    function _calculateMintAmount(
        uint256 amount,
        uint256 exchangeRate,
        uint256 depositCost
    ) private pure returns (uint256) {
        if (exchangeRate == 0) {
            // We use InvalidDepositAmount here as a zero exchange rate makes any deposit invalid.
            revert InvalidDepositAmount();
        }
        uint256 amountAfterFee = (amount * (1e18 - depositCost)) / 1e18;
        return (amountAfterFee * 1e18) / exchangeRate;
    }

    function _getExchangeRate(
        CoreConfig storage config
    ) private view returns (uint256, uint256) {
        return IExchangeRateProvider(config.exchangeRateProvider).getTwaer();
    }

    function _ceilDiv(uint256 a, uint256 b) private pure returns (uint256) {
        if (b == 0) {
            revert InvalidAmount();
        }
        return a == 0 ? 0 : ((a - 1) / b) + 1;
    }

    function _scaleAmount(
        uint256 amount,
        uint256 fromDecimals,
        uint256 toDecimals
    ) private pure returns (uint256) {
        if (fromDecimals == toDecimals) {
            return amount;
        }
        if (fromDecimals < toDecimals) {
            uint256 factor = 10 ** (toDecimals - fromDecimals);
            return amount * factor;
        }
        uint256 divisor = 10 ** (fromDecimals - toDecimals);
        return amount / divisor;
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}
}
