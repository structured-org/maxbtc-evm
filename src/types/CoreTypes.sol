// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

struct Batch {
    uint256 batchId;
    /// If the batch is in WITHDRAWING or FINALIZED, how much BTC was requested?
    uint256 btcRequested;
    /// The amount of maxBTC burned for this batch
    uint256 maxBtcToBurn;
    /// If in FINALIZED state, how much BTC was actually collected?
    uint256 collectedAmount;
    /// Snapshot of deposits held when the batch was moved to WITHDRAWING
    /// (mirrors `collector_historical_balance` in the Rust core for reconciliation)
    uint256 collectorHistoricalBalance;
    /// Number of decimals carried by the `deposit_denom` asset
    uint256 depositDecimals;
}
