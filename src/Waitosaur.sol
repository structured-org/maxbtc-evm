// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {
    Initializable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    UUPSUpgradeable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {StorageSlot} from "@openzeppelin/contracts/utils/StorageSlot.sol";

contract Waitosaur is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    // Custom errors
    error InvalidTokenAddress();
    error AlreadyUnlocked();
    error AlreadyLocked();
    error AmountZero();
    error NothingLocked();
    error InsufficientBalance();
    error NotLocker();
    error NotUnLocker();

    /// @dev keccak256(abi.encode(uint256(keccak256("maxbtc.waitosaur.erc20")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ERC20_STORAGE_SLOT =
        0x4c6a3d0251945e72f6c16332c04b1ac74bce9eac21caff42ddb44b5b6f36f600;
    /// @dev keccak256(abi.encode(uint256(keccak256("maxbtc.waitosaur.locker")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant LOCKER_STORAGE_SLOT =
        0x794332f0d73104ee1db885085af3a929b59ea9c8b4dac3526d7a1c3a586eb600;
    /// @dev keccak256(abi.encode(uint256(keccak256("maxbtc.waitosaur.unlocker")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant UNLOCKER_STORAGE_SLOT =
        0x8ea419c381c469f3563403b843e5ae95e20a2b97aba2e84c1def1317311d2c00;
    /// @dev keccak256(abi.encode(uint256(keccak256("maxbtc.waitosaur.receiver")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant RECEIVER_STORAGE_SLOT =
        0xd865fa479d4018d6ba701cc10bbc8b46de27385f50296c5b7ae3055897feeb00;
    /// @dev keccak256(abi.encode(uint256(keccak256("maxbtc.waitosaur.lockedAmount")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant LOCKED_AMOUNT_STORAGE_SLOT =
        0x8eca6ddedc0e1eaee56a7d530ebea5272dd8f101e2853a7487fc6d82b2fd6500;
    /// @dev keccak256(abi.encode(uint256(keccak256("maxbtc.waitosaur.unlocked")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant UNLOCKED_STORAGE_SLOT =
        0x627f2e206ec466bb32c8d9edddcf1eacda0c89eefc4cc77cc9f48adb1b2c1b00;

    event Locked(uint256 indexed amount);
    event Unlocked();
    event LockerUpdated(address indexed newLocker);
    event UnLockerUpdated(address indexed newUnLocker);
    event ReceiverUpdated(address indexed newReceiver);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        address _token,
        address _locker,
        address _unLocker,
        address _receiver
    ) public initializer {
        if (_token == address(0)) revert InvalidTokenAddress();
        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
        StorageSlot.getUint256Slot(LOCKED_AMOUNT_STORAGE_SLOT).value = 0;
        StorageSlot.getBooleanSlot(UNLOCKED_STORAGE_SLOT).value = true;
        StorageSlot.getAddressSlot(ERC20_STORAGE_SLOT).value = _token;
        StorageSlot.getAddressSlot(LOCKER_STORAGE_SLOT).value = _locker;
        StorageSlot.getAddressSlot(UNLOCKER_STORAGE_SLOT).value = _unLocker;
        StorageSlot.getAddressSlot(RECEIVER_STORAGE_SLOT).value = _receiver;
    }

    function lock(uint256 amount) external {
        if (msg.sender != StorageSlot.getAddressSlot(LOCKER_STORAGE_SLOT).value)
            revert NotLocker();
        if (StorageSlot.getBooleanSlot(UNLOCKED_STORAGE_SLOT).value == false)
            revert AlreadyLocked();
        if (amount == 0) revert AmountZero();
        StorageSlot.getUint256Slot(LOCKED_AMOUNT_STORAGE_SLOT).value = amount;
        StorageSlot.getBooleanSlot(UNLOCKED_STORAGE_SLOT).value = false;
        emit Locked(amount);
    }

    function unlock() external {
        if (
            msg.sender !=
            StorageSlot.getAddressSlot(UNLOCKER_STORAGE_SLOT).value
        ) revert NotUnLocker();
        if (StorageSlot.getBooleanSlot(UNLOCKED_STORAGE_SLOT).value == true)
            revert AlreadyUnlocked();
        if (StorageSlot.getUint256Slot(LOCKED_AMOUNT_STORAGE_SLOT).value == 0)
            revert NothingLocked();
        address tokenAddr = token();
        (bool success, bytes memory data) = tokenAddr.call(
            abi.encodeWithSignature("balanceOf(address)", address(this))
        );
        require(success && data.length >= 32, "balanceOf failed");
        uint256 balance = abi.decode(data, (uint256));
        if (
            balance <
            StorageSlot.getUint256Slot(LOCKED_AMOUNT_STORAGE_SLOT).value
        ) revert InsufficientBalance();
        if (
            StorageSlot.getAddressSlot(RECEIVER_STORAGE_SLOT).value ==
            address(0)
        ) revert("Receiver not set");
        StorageSlot.getBooleanSlot(UNLOCKED_STORAGE_SLOT).value = true;
        // Transfer lockedAmount to receiver
        (success, data) = tokenAddr.call(
            abi.encodeWithSignature(
                "transfer(address,uint256)",
                StorageSlot.getAddressSlot(RECEIVER_STORAGE_SLOT).value,
                StorageSlot.getUint256Slot(LOCKED_AMOUNT_STORAGE_SLOT).value
            )
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "Transfer failed"
        );
        emit Unlocked();
    }

    function updateReceiver(address newReceiver) external onlyOwner {
        StorageSlot.getAddressSlot(RECEIVER_STORAGE_SLOT).value = newReceiver;
        emit ReceiverUpdated(newReceiver);
    }

    function updateLocker(address newLocker) external onlyOwner {
        StorageSlot.getAddressSlot(LOCKER_STORAGE_SLOT).value = newLocker;
        emit LockerUpdated(newLocker);
    }

    function updateUnLocker(address newUnLocker) external onlyOwner {
        StorageSlot.getAddressSlot(UNLOCKER_STORAGE_SLOT).value = newUnLocker;
        emit UnLockerUpdated(newUnLocker);
    }

    function lockedAmount() public view returns (uint256) {
        return StorageSlot.getUint256Slot(LOCKED_AMOUNT_STORAGE_SLOT).value;
    }

    function unlocked() public view returns (bool) {
        return StorageSlot.getBooleanSlot(UNLOCKED_STORAGE_SLOT).value;
    }
    function receiver() public view returns (address) {
        return StorageSlot.getAddressSlot(RECEIVER_STORAGE_SLOT).value;
    }

    function token() public view returns (address) {
        return StorageSlot.getAddressSlot(ERC20_STORAGE_SLOT).value;
    }

    function locker() public view returns (address) {
        return StorageSlot.getAddressSlot(LOCKER_STORAGE_SLOT).value;
    }

    function unLocker() public view returns (address) {
        return StorageSlot.getAddressSlot(UNLOCKER_STORAGE_SLOT).value;
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    uint256[50] private __gap;
}
