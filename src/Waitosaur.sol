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

interface iERC20 {
    function balanceOf(address account) external view returns (uint256);
}

contract Waitosaur is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    // Custom errors
    error InvalidTokenAddress();
    error AlreadyUnlocked();
    error AmountZero();
    error NothingLocked();
    error InsufficientBalance();
    error NotLocker();
    error NotUnLocker();

    iERC20 public TOKEN;
    uint256 public lockedAmount;
    bool public unlocked;

    address public locker;
    address public unLocker;
    address public receiver;

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
        TOKEN = iERC20(_token);
        locker = _locker;
        unLocker = _unLocker;
        receiver = _receiver;
    }

    function lock(uint256 amount) external {
        if (msg.sender != locker) revert NotLocker();
        if (unlocked) revert AlreadyUnlocked();
        if (amount == 0) revert AmountZero();
        lockedAmount = amount;
        emit Locked(amount);
    }

    function unlock() external {
        if (msg.sender != unLocker) revert NotUnLocker();
        if (unlocked) revert AlreadyUnlocked();
        if (lockedAmount == 0) revert NothingLocked();
        uint256 balance = TOKEN.balanceOf(address(this));
        if (balance < lockedAmount) revert InsufficientBalance();
        if (receiver == address(0)) revert("Receiver not set");
        unlocked = true;
        // Transfer lockedAmount to receiver
        (bool success, bytes memory data) = address(TOKEN).call(
            abi.encodeWithSignature(
                "transfer(address,uint256)",
                receiver,
                lockedAmount
            )
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "Transfer failed"
        );
        emit Unlocked();
    }
    function updateReceiver(address newReceiver) external onlyOwner {
        receiver = newReceiver;
        emit ReceiverUpdated(newReceiver);
    }

    function updateLocker(address newLocker) external onlyOwner {
        locker = newLocker;
        emit LockerUpdated(newLocker);
    }

    function updateUnLocker(address newUnLocker) external onlyOwner {
        unLocker = newUnLocker;
        emit UnLockerUpdated(newUnLocker);
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}
}
