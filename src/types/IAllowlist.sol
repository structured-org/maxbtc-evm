// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Minimal allowlist interface mirroring the CosmWasm allowlist query.
interface IAllowlist {
    function isAddressAllowed(address account) external view returns (bool);
}
