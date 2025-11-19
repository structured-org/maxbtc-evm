// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Exchange rate provider interface used by MaxBTCCore.
/// @dev Mirrors the Rust core contract queries `GetTwaer` and `GetAum`.
interface IExchangeRateProvider {
    /// @return er The time weighted average exchange rate, scaled to 1e18
    /// @return timestamp The timestamp of the last publication
    function getTwaer() external view returns (uint256 er, uint256 timestamp);

    /// @return er The latest exchange rate, scaled to 1e18
    /// @return timestamp The timestamp of the last publication
    function getLatest() external view returns (uint256 er, uint256 timestamp);

    /// @return aum Total assets under management in the deposit token denomination
    /// @return decimals Number of decimals for the returned AUM value
    function getAum() external view returns (int256 aum, uint8 decimals);
}
