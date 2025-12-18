// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {WithdrawalManager, ICoreContract} from "../src/WithdrawalManager.sol";
import {WithdrawalToken} from "../src/WithdrawalToken.sol";
import {Batch} from "../src/types/CoreTypes.sol";

/// @notice Minimal mock ERC20 WBTC implementation used for testing
contract MockWBTC {
    string public name;
    string public symbol;

    uint8 public constant DECIMALS = 8;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }

    function mint(address to, uint256 amount) external {
        _totalSupply += amount;
        _balances[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        address from = msg.sender;
        uint256 bal = _balances[from];
        require(bal >= amount, "insufficient balance");

        unchecked {
            _balances[from] = bal - amount;
        }
        _balances[to] += amount;

        emit Transfer(from, to, amount);
        return true;
    }

    function allowance(
        address owner,
        address spender
    ) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        uint256 allowed = _allowances[from][msg.sender];
        require(allowed >= amount, "allowance");

        uint256 bal = _balances[from];
        require(bal >= amount, "insufficient");

        unchecked {
            _allowances[from][msg.sender] = allowed - amount;
            _balances[from] = bal - amount;
        }

        _balances[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

/// @notice Minimal mock of the Core contract used to feed batch data
contract MockCore is ICoreContract {
    mapping(uint256 => Batch) internal _batches;

    function setCollectedAmount(uint256 batchId, uint256 amount) external {
        _batches[batchId].collectedAmount = amount;
        _batches[batchId].batchId = batchId;
    }

    function finalizedBatch(
        uint256 batchId
    ) external view override returns (Batch memory) {
        return _batches[batchId];
    }
}

/// @notice Example upgraded implementation used to test UUPS upgrade logic and storage layout
contract WithdrawalManagerV2 is WithdrawalManager {
    // New storage variable to check that storage layout is not corrupted
    uint256 public newVar;

    function version() external pure returns (uint256) {
        return 2;
    }

    function setNewVar(uint256 v) external {
        newVar = v;
    }
}

contract WithdrawalManagerTest is Test {
    WithdrawalManager internal manager;
    WithdrawalToken internal token;
    MockWBTC internal wbtc;
    MockCore internal core;

    address internal owner = address(0xABCD);
    address internal user = address(0x1234);
    uint256 internal constant BATCH_ID = 1;

    function setUp() public {
        // Deploy mock WBTC
        wbtc = new MockWBTC("Wrapped BTC", "WBTC");

        // Deploy mock Core
        core = new MockCore();

        // Set batch collected amount for testing (10 WBTC assuming 8 decimals)
        uint256 collectedAmount = 1_000_000_000;
        core.setCollectedAmount(BATCH_ID, collectedAmount);

        // Deploy WithdrawalToken via UUPS proxy (deferred init)
        WithdrawalToken tokenImpl = new WithdrawalToken();
        ERC1967Proxy tokenProxy = new ERC1967Proxy(address(tokenImpl), "");
        token = WithdrawalToken(address(tokenProxy));

        // Deploy WithdrawalManager via UUPS proxy
        WithdrawalManager managerImpl = new WithdrawalManager();
        bytes memory managerInitData = abi.encodeCall(
            WithdrawalManager.initialize,
            (owner, address(core), address(wbtc), address(token))
        );

        ERC1967Proxy managerProxy = new ERC1967Proxy(
            address(managerImpl),
            managerInitData
        );
        manager = WithdrawalManager(address(managerProxy));

        // Now initialize withdrawal token with the manager address
        token.initialize(
            owner,
            address(core),
            address(managerProxy),
            "https://api.example.com/",
            "WithdrawalToken",
            "WRT"
        );

        // Fund WithdrawalManager with WBTC so it can redeem users
        wbtc.mint(address(manager), collectedAmount);

        // Mint 1 redemption token to the user for batch BATCH_ID
        vm.prank(address(core));
        token.mint(user, BATCH_ID, 1, "");
    }

    function testConfigInitialized() public view {
        // Verify that config was stored correctly during initialize()
        WithdrawalManager.WithdrawalManagerConfig memory config = manager
            .getConfig();
        assertEq(config.coreContract, address(core));
        assertEq(config.wbtcContract, address(wbtc));
        assertEq(config.withdrawalTokenContract, address(token));
        assertEq(manager.owner(), owner);
    }

    function testOnERC1155ReceivedRedeemsAndBurns() public {
        // Initial state before redemption
        uint256 managerBalanceBefore = wbtc.balanceOf(address(manager));
        uint256 userBalanceBefore = wbtc.balanceOf(user);
        uint256 paidBefore = manager.getPaidAmount(BATCH_ID);
        uint256 supplyBefore = token.totalSupply(BATCH_ID);

        assertEq(supplyBefore, 1);
        assertEq(managerBalanceBefore, 1_000_000_000);
        assertEq(userBalanceBefore, 0);
        assertEq(paidBefore, 0);

        // User transfers a redemption token to the manager -> triggers onERC1155Received
        vm.prank(user);
        token.safeTransferFrom(user, address(manager), BATCH_ID, 1, "");

        // State after redemption
        uint256 managerBalanceAfter = wbtc.balanceOf(address(manager));
        uint256 userBalanceAfter = wbtc.balanceOf(user);
        uint256 paidAfter = manager.getPaidAmount(BATCH_ID);
        uint256 supplyAfter = token.totalSupply(BATCH_ID);

        // For full supply redemption user receives full collected amount
        assertEq(userBalanceAfter, 1_000_000_000);
        assertEq(managerBalanceAfter, managerBalanceBefore - 1_000_000_000);
        assertEq(paidAfter, 1_000_000_000);

        // Redemption token is burned from manager, so totalSupply goes to 0 and user has 0
        assertEq(token.balanceOf(user, BATCH_ID), 0);
        assertEq(supplyAfter, 0);
    }

    function testOnERC1155ReceivedRevertsWhenPaused() public {
        // Enable pause
        vm.prank(owner);
        manager.setPause(true);
        assertTrue(manager.paused());

        // Redeeming under pause must revert
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(WithdrawalManager.ContractPaused.selector)
        );
        token.safeTransferFrom(user, address(manager), BATCH_ID, 1, "");
    }

    function testOnERC1155ReceivedRevertsForInvalidToken() public {
        // Direct call without WithdrawalToken must revert
        vm.expectRevert(
            abi.encodeWithSelector(
                WithdrawalManager.InvalidWithdrawalToken.selector
            )
        );
        manager.onERC1155Received(address(this), user, BATCH_ID, 1, "");
    }

    function testOnERC1155ReceivedRevertsWhenRedemptionSupplyIsZero() public {
        uint256 emptyBatchId = 42;

        // Set batch but do not mint redemption tokens → supply = 0
        core.setCollectedAmount(emptyBatchId, 1_000_000);

        // Call from WithdrawalToken address to pass msg.sender check
        vm.prank(address(token));
        vm.expectRevert(
            abi.encodeWithSelector(
                WithdrawalManager.RedemptionTokenSupplyIsZero.selector
            )
        );

        manager.onERC1155Received(address(this), user, emptyBatchId, 1, "");
    }

    function testOnERC1155BatchReceivedReverts() public {
        // Batch ERC1155 transfers are not supported
        uint256[] memory ids = new uint256[](BATCH_ID);
        uint256[] memory amounts = new uint256[](1);

        vm.expectRevert(
            abi.encodeWithSelector(
                WithdrawalManager.BatchSupportNotEnabled.selector
            )
        );

        manager.onERC1155BatchReceived(address(this), user, ids, amounts, "");
    }

    function testUpdateConfigByOwner() public {
        // Owner updates config successfully
        address newCore = address(0x1111);
        address newWbtc = address(0x2222);
        address newToken = address(0x3333);

        vm.prank(owner);
        manager.updateConfig(newCore, newWbtc, newToken);

        WithdrawalManager.WithdrawalManagerConfig memory config = manager
            .getConfig();
        assertEq(config.coreContract, newCore);
        assertEq(config.wbtcContract, newWbtc);
        assertEq(config.withdrawalTokenContract, newToken);
    }

    function testUpdateConfigRevertsForNonOwner() public {
        // Non-owner must not be able to update config
        vm.expectRevert(
            abi.encodeWithSignature(
                "OwnableUnauthorizedAccount(address)",
                address(this)
            )
        );
        manager.updateConfig(address(1), address(2), address(3));
    }

    function testUpdateConfigRevertsForZeroAddresses() public {
        // Zero addresses are forbidden

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                WithdrawalManager.InvalidCoreContractAddress.selector
            )
        );
        manager.updateConfig(address(0), address(2), address(3));

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                WithdrawalManager.InvalidwBTCContractAddress.selector
            )
        );
        manager.updateConfig(address(1), address(0), address(3));

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                WithdrawalManager.InvalidWithdrawalTokenContractAddress.selector
            )
        );
        manager.updateConfig(address(1), address(2), address(0));
    }

    function testPauseAndUnpauseEmitsEventsAndChangesState() public {
        // Pausing produces event and updates state
        vm.prank(owner);
        vm.expectEmit();
        emit WithdrawalManager.Paused();
        manager.setPause(true);
        assertTrue(manager.paused());

        // Unpausing produces event and restores state
        vm.prank(owner);
        vm.expectEmit();
        emit WithdrawalManager.Unpaused();
        manager.setPause(false);
        assertFalse(manager.paused());
    }

    function testUpgradeToV2ByOwner() public {
        // Owner upgrades contract implementation via UUPS
        WithdrawalManagerV2 implV2 = new WithdrawalManagerV2();

        vm.prank(owner);
        manager.upgradeToAndCall(address(implV2), "");

        // New logic must be active
        uint256 v = WithdrawalManagerV2(address(manager)).version();
        assertEq(v, 2);

        // Storage must be preserved
        WithdrawalManager.WithdrawalManagerConfig memory config = manager
            .getConfig();
        assertEq(config.coreContract, address(core));
        assertEq(config.wbtcContract, address(wbtc));
        assertEq(config.withdrawalTokenContract, address(token));
    }

    function testUpgradeToV2RevertsForNonOwner() public {
        // Non-owner upgrade must revert
        WithdrawalManagerV2 implV2 = new WithdrawalManagerV2();

        vm.expectRevert(
            abi.encodeWithSignature(
                "OwnableUnauthorizedAccount(address)",
                address(this)
            )
        );

        manager.upgradeToAndCall(address(implV2), "");
    }

    /// -----------------------------------------------------------------------
    ///  Additional tests: partial redemption, multi-user, rounding, storage
    /// -----------------------------------------------------------------------

    function testPartialRedemptionUpdatesPaidAmountAndBalances() public {
        // New batch with multi-supply redemption
        uint256 batchId = 2;
        uint256 collectedAmount = 1_000_000_000; // 10 WBTC
        core.setCollectedAmount(batchId, collectedAmount);

        address userA = address(0xAAAA);

        // Mint 10 redemption tokens to userA
        vm.prank(address(core));
        token.mint(userA, batchId, 10, "");

        // Fund manager for this batch as well
        wbtc.mint(address(manager), collectedAmount);

        uint256 paidBefore = manager.getPaidAmount(batchId);
        uint256 supplyBefore = token.totalSupply(batchId);
        uint256 value = 4; // user redeems a part of supply

        Batch memory b = core.finalizedBatch(batchId);

        uint256 availableBtc = b.collectedAmount - paidBefore;
        uint256 expectedUserBtc = (availableBtc * value) / supplyBefore;
        uint256 expectedPaidAfter = paidBefore + expectedUserBtc;

        uint256 managerBalanceBefore = wbtc.balanceOf(address(manager));
        uint256 userBalanceBefore = wbtc.balanceOf(userA);

        // Execute redemption
        vm.prank(userA);
        token.safeTransferFrom(userA, address(manager), batchId, value, "");

        uint256 managerBalanceAfter = wbtc.balanceOf(address(manager));
        uint256 userBalanceAfter = wbtc.balanceOf(userA);
        uint256 paidAfter = manager.getPaidAmount(batchId);
        uint256 supplyAfter = token.totalSupply(batchId);

        // Check balances and paidAmount according to current formula
        assertEq(
            userBalanceAfter - userBalanceBefore,
            expectedUserBtc,
            "User must receive expected BTC amount"
        );
        assertEq(
            managerBalanceBefore - managerBalanceAfter,
            expectedUserBtc,
            "Manager must pay out expected BTC amount"
        );
        assertEq(paidAfter, expectedPaidAfter, "paidAmount must match formula");
        assertEq(
            supplyAfter,
            supplyBefore - value,
            "token supply must decrease by redeemed amount"
        );
    }

    function testMultiUserSequentialRedemption() public {
        uint256 batchId = 3;
        uint256 collectedAmount = 1_000_000_000; // 10 WBTC
        core.setCollectedAmount(batchId, collectedAmount);

        address userA = address(0xAAAA);
        address userB = address(0xBBBB);

        // Mint 10 tokens total: 4 to A, 6 to B
        vm.startPrank(address(core));
        token.mint(userA, batchId, 4, "");
        token.mint(userB, batchId, 6, "");
        vm.stopPrank();

        // Fund manager for this batch
        wbtc.mint(address(manager), collectedAmount);

        Batch memory b = core.finalizedBatch(batchId);

        // First redemption: userA redeems 2
        {
            uint256 paidBefore = manager.getPaidAmount(batchId);
            uint256 supplyBefore = token.totalSupply(batchId);
            uint256 value = 2;

            uint256 availableBtc = b.collectedAmount - paidBefore;
            uint256 expectedUserBtc = (availableBtc * value) / supplyBefore;
            uint256 expectedPaidAfter = paidBefore + expectedUserBtc;

            uint256 managerBalanceBefore = wbtc.balanceOf(address(manager));
            uint256 userBalanceBefore = wbtc.balanceOf(userA);

            vm.prank(userA);
            token.safeTransferFrom(userA, address(manager), batchId, value, "");

            uint256 managerBalanceAfter = wbtc.balanceOf(address(manager));
            uint256 userBalanceAfter = wbtc.balanceOf(userA);
            uint256 paidAfter = manager.getPaidAmount(batchId);

            assertEq(
                userBalanceAfter - userBalanceBefore,
                expectedUserBtc,
                "User A must receive expected BTC amount"
            );
            assertEq(
                managerBalanceBefore - managerBalanceAfter,
                expectedUserBtc,
                "Manager must pay out expected BTC amount to A"
            );
            assertEq(
                paidAfter,
                expectedPaidAfter,
                "paidAmount must match formula after A"
            );
        }

        // Second redemption: userB redeems 3
        {
            uint256 paidBefore = manager.getPaidAmount(batchId);
            uint256 supplyBefore = token.totalSupply(batchId);
            uint256 value = 3;

            uint256 availableBtc = b.collectedAmount - paidBefore;
            uint256 expectedUserBtc = (availableBtc * value) / supplyBefore;
            uint256 expectedPaidAfter = paidBefore + expectedUserBtc;

            uint256 managerBalanceBefore = wbtc.balanceOf(address(manager));
            uint256 userBalanceBefore = wbtc.balanceOf(userB);

            vm.prank(userB);
            token.safeTransferFrom(userB, address(manager), batchId, value, "");

            uint256 managerBalanceAfter = wbtc.balanceOf(address(manager));
            uint256 userBalanceAfter = wbtc.balanceOf(userB);
            uint256 paidAfter = manager.getPaidAmount(batchId);

            assertEq(
                userBalanceAfter - userBalanceBefore,
                expectedUserBtc,
                "User B must receive expected BTC amount"
            );
            assertEq(
                managerBalanceBefore - managerBalanceAfter,
                expectedUserBtc,
                "Manager must pay out expected BTC amount to B"
            );
            assertEq(
                paidAfter,
                expectedPaidAfter,
                "paidAmount must match formula after B"
            );
        }
    }

    function testRedemptionRoundingDownToZero() public {
        uint256 batchId = 4;
        uint256 collectedAmount = 1_000_000; // 0.01 WBTC
        core.setCollectedAmount(batchId, collectedAmount);

        address tinyUser = address(0xCAFE);

        // Mint 3 tokens, user redeems 1 -> fraction = 1 / 3 => 0 in integer math
        vm.prank(address(core));
        token.mint(tinyUser, batchId, 3, "");

        // Fund manager
        wbtc.mint(address(manager), collectedAmount);

        uint256 paidBefore = manager.getPaidAmount(batchId);
        uint256 supplyBefore = token.totalSupply(batchId);
        uint256 value = 1;

        Batch memory b = core.finalizedBatch(batchId);

        uint256 availableBtc = b.collectedAmount - paidBefore;
        uint256 expectedUserBtc = (availableBtc * value) / supplyBefore;
        uint256 expectedPaidAfter = paidBefore + expectedUserBtc;

        uint256 managerBalanceBefore = wbtc.balanceOf(address(manager));

        vm.prank(tinyUser);
        token.safeTransferFrom(tinyUser, address(manager), batchId, value, "");

        uint256 managerBalanceAfter = wbtc.balanceOf(address(manager));
        uint256 userBalanceAfter = wbtc.balanceOf(tinyUser);
        uint256 paidAfter = manager.getPaidAmount(batchId);
        uint256 supplyAfter = token.totalSupply(batchId);

        assertEq(userBalanceAfter, expectedUserBtc, "User should receive BTC");
        assertEq(
            managerBalanceAfter,
            managerBalanceBefore - expectedUserBtc,
            "Manager must pay BTC"
        );

        // Token supply must decrease by burned value
        assertEq(
            supplyAfter,
            supplyBefore - value,
            "Token supply must decrease by value"
        );

        // paidAmount must not change (no BTC actually distributed)
        assertEq(
            paidAfter,
            expectedPaidAfter,
            "paidAmount must remain unchanged"
        );
    }

    function testUpgradeDoesNotCorruptPaidAmountOrConfig() public {
        // Prepare some state: partial redemption on a separate batch
        uint256 batchId = 5;
        uint256 collectedAmount = 2_000_000_000; // 20 WBTC
        core.setCollectedAmount(batchId, collectedAmount);

        address someUser = address(0xDEAD);

        // Mint 10 tokens to user
        vm.prank(address(core)); // simulate mint by core contract
        token.mint(someUser, batchId, 10, "");

        // Fund manager
        wbtc.mint(address(manager), collectedAmount);

        // Perform one redemption to set non-zero paidAmount
        uint256 value = 5;
        vm.prank(someUser);
        token.safeTransferFrom(someUser, address(manager), batchId, value, "");

        uint256 paidBeforeUpgrade = manager.getPaidAmount(batchId);
        WithdrawalManager.WithdrawalManagerConfig memory configBefore = manager
            .getConfig();

        // Upgrade to V2
        WithdrawalManagerV2 implV2 = new WithdrawalManagerV2();

        vm.prank(owner);
        manager.upgradeToAndCall(address(implV2), "");

        // After upgrade: paidAmount and config must be preserved
        uint256 paidAfterUpgrade = manager.getPaidAmount(batchId);
        WithdrawalManager.WithdrawalManagerConfig memory configAfter = manager
            .getConfig();

        assertEq(
            paidAfterUpgrade,
            paidBeforeUpgrade,
            "paidAmount must be preserved across upgrade"
        );
        assertEq(
            configAfter.coreContract,
            configBefore.coreContract,
            "coreContract must be preserved"
        );
        assertEq(
            configAfter.wbtcContract,
            configBefore.wbtcContract,
            "wbtcContract must be preserved"
        );
        assertEq(
            configAfter.withdrawalTokenContract,
            configBefore.withdrawalTokenContract,
            "withdrawalTokenContract must be preserved"
        );

        // New storage variable in V2 must work without corrupting existing storage
        WithdrawalManagerV2(address(manager)).setNewVar(123);
        uint256 newVarValue = WithdrawalManagerV2(address(manager)).newVar();
        assertEq(
            newVarValue,
            123,
            "newVar must be set correctly without storage collision"
        );
    }
}
