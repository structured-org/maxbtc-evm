// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {
    WaitosaurObserver,
    WaitosaurObserverConfig,
    IAumOracle
} from "../src/WaitosaurObserver.sol";
import {
    WaitosaurBase,
    WaitosaurState,
    WaitosaurAccess
} from "../src/WaitosaurBase.sol";

/// @notice Simple mock oracle returning a preset balance
contract MockAumOracle is IAumOracle {
    uint256 private _balance;
    uint256 public _timestamp;

    constructor() {
        _timestamp = block.timestamp;
    }

    function setSpotBalance(uint256 newBalance) external {
        _balance = newBalance;
        _timestamp = block.timestamp;
    }

    /// @notice Always returns the preset balance (ignores the asset name)
    function getSpotBalance(
        string calldata
    ) external view override returns (uint256, uint256) {
        return (_balance, _timestamp);
    }
}

contract WaitosaurObserverV2 is WaitosaurObserver {
    uint256 public newVar;

    function version() external pure returns (uint256) {
        return 2;
    }

    function setNewVar(uint256 v) external {
        newVar = v;
    }
}

contract WaitosaurObserverTest is Test {
    WaitosaurObserver internal impl;
    WaitosaurObserver internal observer;
    MockAumOracle internal oracle;
    ERC1967Proxy internal proxy;

    address internal owner = address(0x1);
    address internal locker = address(0x2);
    address internal unlocker = address(0x3);
    string internal asset = "BTC";

    function _deployUninitializedProxy() private returns (WaitosaurObserver) {
        WaitosaurObserver freshImpl = new WaitosaurObserver();
        ERC1967Proxy freshProxy = new ERC1967Proxy(address(freshImpl), "");
        return WaitosaurObserver(address(freshProxy));
    }

    function setUp() public {
        vm.startPrank(owner);

        impl = new WaitosaurObserver();
        oracle = new MockAumOracle();

        proxy = new ERC1967Proxy(address(impl), "");
        observer = WaitosaurObserver(address(proxy));

        observer.initialize(
            owner,
            locker,
            unlocker,
            address(oracle),
            asset,
            3600
        );

        vm.stopPrank();
    }

    // -------------------------------------------------------------
    // Initialization tests
    // -------------------------------------------------------------

    function testInitialConfigAndState() public view {
        WaitosaurObserverConfig memory cfg = observer.getConfig();
        assertEq(cfg.oracle, address(oracle));
        assertEq(cfg.asset, asset);
        assertEq(cfg.stalenessThreshold, 3600);

        WaitosaurState memory st = observer.getState();
        assertEq(st.lockedAmount, 0);
        assertEq(st.lastLocked, 0);

        WaitosaurAccess memory roles = observer.getRoles();
        assertEq(roles.locker, locker);
        assertEq(roles.unlocker, unlocker);
    }

    function testInitializeZeroLockerReverts() public {
        WaitosaurObserver fresh = _deployUninitializedProxy();
        vm.prank(owner);
        vm.expectRevert(WaitosaurBase.InvalidRolesAddresses.selector);
        fresh.initialize(
            owner,
            address(0),
            unlocker,
            address(oracle),
            asset,
            3600
        );
    }

    function testInitializeZeroUnlockerReverts() public {
        WaitosaurObserver fresh = _deployUninitializedProxy();
        vm.prank(owner);
        vm.expectRevert(WaitosaurBase.InvalidRolesAddresses.selector);
        fresh.initialize(
            owner,
            locker,
            address(0),
            address(oracle),
            asset,
            3600
        );
    }

    function testInitializeZeroOracleReverts() public {
        WaitosaurObserver fresh = _deployUninitializedProxy();
        vm.prank(owner);
        vm.expectRevert(WaitosaurObserver.InvalidOracleAddress.selector);
        fresh.initialize(owner, locker, unlocker, address(0), asset, 3600);
    }

    function testInitializeEmptyAssetReverts() public {
        WaitosaurObserver fresh = _deployUninitializedProxy();
        vm.prank(owner);
        vm.expectRevert(WaitosaurObserver.InvalidAsset.selector);
        fresh.initialize(owner, locker, unlocker, address(oracle), "", 3600);
    }

    function testInitializeTwiceReverts() public {
        WaitosaurObserver fresh = _deployUninitializedProxy();
        vm.prank(owner);
        fresh.initialize(owner, locker, unlocker, address(oracle), asset, 3600);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        fresh.initialize(owner, locker, unlocker, address(oracle), asset, 3600);
    }

    // -------------------------------------------------------------
    // Lock tests
    // -------------------------------------------------------------

    function testLockByLocker() public {
        uint256 amount = 1000e18;

        vm.prank(locker);
        observer.lock(amount);

        assertEq(observer.lockedAmount(), amount);
        assertGt(observer.lastLocked(), 0);
    }

    function testLockByOwner() public {
        uint256 amount = 500e18;

        vm.prank(owner);
        observer.lock(amount);

        assertEq(observer.lockedAmount(), amount);
    }

    function testLockZeroAmountReverts() public {
        vm.prank(locker);
        vm.expectRevert(WaitosaurBase.AmountZero.selector);
        observer.lock(0);
    }

    function testLockAlreadyLockedReverts() public {
        vm.prank(locker);
        observer.lock(100);

        vm.prank(locker);
        vm.expectRevert(WaitosaurBase.AlreadyLocked.selector);
        observer.lock(50);
    }

    function testLockUnauthorizedReverts() public {
        address attacker = address(0x99);
        vm.prank(attacker);
        vm.expectRevert(WaitosaurBase.Unauthorized.selector);
        observer.lock(100);
    }

    // -------------------------------------------------------------
    // Unlock tests
    // -------------------------------------------------------------

    function testUnlockSuccess() public {
        uint256 amount = 1000e18;

        vm.prank(locker);
        observer.lock(amount);

        oracle.setSpotBalance(amount + 1);

        vm.prank(unlocker);
        observer.unlock();

        assertEq(observer.lockedAmount(), 0);
        assertEq(observer.lastLocked(), 0);
    }

    function testUnlockByOwnerAllowed() public {
        uint256 amount = 1000e18;

        vm.prank(locker);
        observer.lock(amount);

        oracle.setSpotBalance(amount);

        vm.prank(owner);
        observer.unlock();

        assertEq(observer.lockedAmount(), 0);
    }

    function testUnlockInsufficientBalanceReverts() public {
        uint256 amount = 1000e18;

        vm.prank(locker);
        observer.lock(amount);

        oracle.setSpotBalance(amount - 1);

        vm.prank(unlocker);
        vm.expectRevert(WaitosaurBase.InsufficientAssetAmount.selector);
        observer.unlock();
    }

    function testUnlockAlreadyUnlockedReverts() public {
        vm.prank(unlocker);
        vm.expectRevert(WaitosaurBase.AlreadyUnlocked.selector);
        observer.unlock();
    }

    function testUnlockUnauthorizedReverts() public {
        uint256 amount = 1000e18;

        vm.prank(locker);
        observer.lock(amount);

        oracle.setSpotBalance(amount);

        address attacker = address(0x99);
        vm.prank(attacker);
        vm.expectRevert(WaitosaurBase.Unauthorized.selector);
        observer.unlock();
    }

    // -------------------------------------------------------------
    // Staleness tests
    // -------------------------------------------------------------

    function testInitializeRevertsOnStaleOracleData() public {
        // Create a mock oracle with stale data
        MockAumOracle staleOracle = new MockAumOracle();
        staleOracle.setSpotBalance(1000e18);

        // Warp time forward to make the oracle data stale
        vm.warp(block.timestamp + 7200); // 2 hours later

        WaitosaurObserver fresh = _deployUninitializedProxy();
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                WaitosaurObserver.StaleOracleData.selector,
                staleOracle._timestamp(),
                block.timestamp,
                3600
            )
        );
        fresh.initialize(
            owner,
            locker,
            unlocker,
            address(staleOracle),
            asset,
            3600
        );
    }

    function testUnlockRevertsOnStaleOracleData() public {
        uint256 amount = 1000e18;

        vm.prank(locker);
        observer.lock(amount);

        oracle.setSpotBalance(amount);
        uint256 oracleTimestamp = oracle._timestamp();

        // Warp time forward to make the oracle data stale
        vm.warp(block.timestamp + 7200); // 2 hours later, exceeds 1 hour threshold

        vm.prank(unlocker);
        vm.expectRevert(
            abi.encodeWithSelector(
                WaitosaurObserver.StaleOracleData.selector,
                oracleTimestamp,
                block.timestamp,
                3600
            )
        );
        observer.unlock();
    }

    function testUnlockSucceedsWithFreshOracleData() public {
        uint256 amount = 1000e18;

        vm.prank(locker);
        observer.lock(amount);

        // Move forward but keep data fresh
        vm.warp(block.timestamp + 1800); // 30 minutes later, within threshold
        oracle.setSpotBalance(amount);

        vm.prank(unlocker);
        observer.unlock();

        assertEq(observer.lockedAmount(), 0);
        assertEq(observer.lastLocked(), 0);
    }

    function testUnlockUnauthorizedCheckedBeforeStaleness() public {
        uint256 amount = 1000e18;

        vm.prank(locker);
        observer.lock(amount);

        oracle.setSpotBalance(amount);

        // Warp time forward to make the oracle data stale
        vm.warp(block.timestamp + 7200); // 2 hours later

        // Unauthorized user should get Unauthorized error, not StaleOracleData
        address attacker = address(0x99);
        vm.prank(attacker);
        vm.expectRevert(WaitosaurBase.Unauthorized.selector);
        observer.unlock();
    }

    // -------------------------------------------------------------
    // Config update tests
    // -------------------------------------------------------------

    function testUpdateConfig() public {
        address newOracle = address(0x12);
        string memory newAsset = "ETH";

        vm.prank(owner);
        observer.updateConfig(newOracle, newAsset, 7200);

        WaitosaurObserverConfig memory cfg = observer.getConfig();
        assertEq(cfg.oracle, newOracle);
        assertEq(cfg.asset, newAsset);
        assertEq(cfg.stalenessThreshold, 7200);
    }

    function testPartialUpdateConfigKeepsOld() public {
        vm.prank(owner);
        observer.updateConfig(address(0), "", 0);

        WaitosaurObserverConfig memory cfg = observer.getConfig();
        assertEq(cfg.oracle, address(oracle));
        assertEq(cfg.asset, asset);
        assertEq(cfg.stalenessThreshold, 3600);
    }

    function testUpdateConfigRevertsWhenLocked() public {
        vm.prank(locker);
        observer.lock(1 ether);

        vm.prank(owner);
        vm.expectRevert(
            WaitosaurObserver.ConfigCantBeUpdatedWhenLocked.selector
        );
        observer.updateConfig(address(0x12), "ETH", 0);
    }

    // -------------------------------------------------------------
    // Roles update tests
    // -------------------------------------------------------------

    function testUpdateRoles() public {
        address newLocker = address(0xA11CE);
        address newUnlocker = address(0xB0B);

        vm.prank(owner);
        observer.updateRoles(newLocker, newUnlocker);

        WaitosaurAccess memory roles = observer.getRoles();
        assertEq(roles.locker, newLocker);
        assertEq(roles.unlocker, newUnlocker);
    }

    function testUpdateRolesRevertsNoChange() public {
        address newLocker = address(0xA11CE);
        address newUnlocker = address(0xB0B);

        vm.prank(owner);
        vm.expectRevert(WaitosaurBase.InvalidRolesAddresses.selector);
        observer.updateRoles(newLocker, address(0));

        vm.prank(owner);
        vm.expectRevert(WaitosaurBase.InvalidRolesAddresses.selector);
        observer.updateRoles(address(0), newUnlocker);

        WaitosaurAccess memory roles = observer.getRoles();
        assertEq(roles.locker, locker);
        assertEq(roles.unlocker, unlocker);
    }

    // -------------------------------------------------------------
    // Upgrade tests
    // -------------------------------------------------------------

    function testUpgradeToV2ByOwner() public {
        // Set some state before upgrade
        vm.prank(locker);
        observer.lock(111);

        WaitosaurObserverV2 implV2 = new WaitosaurObserverV2();

        vm.prank(owner);
        observer.upgradeToAndCall(address(implV2), "");

        // New logic active
        uint256 v = WaitosaurObserverV2(address(observer)).version();
        assertEq(v, 2);

        // Storage preserved
        WaitosaurObserverConfig memory cfg = observer.getConfig();
        assertEq(cfg.oracle, address(oracle));
        assertEq(cfg.asset, asset);

        WaitosaurAccess memory roles = observer.getRoles();
        assertEq(roles.locker, locker);
        assertEq(roles.unlocker, unlocker);

        WaitosaurState memory st = observer.getState();
        assertEq(st.lockedAmount, 111);
        assertGt(st.lastLocked, 0);
    }

    function testUpgradeToV2RevertsForNonOwner() public {
        WaitosaurObserverV2 implV2 = new WaitosaurObserverV2();

        vm.expectRevert(
            abi.encodeWithSignature(
                "OwnableUnauthorizedAccount(address)",
                address(this)
            )
        );

        observer.upgradeToAndCall(address(implV2), "");
    }
}
