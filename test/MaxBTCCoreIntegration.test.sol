// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MaxBTCCore} from "../src/MaxBTCCore.sol";
import {MaxBTCERC20} from "../src/MaxBTCERC20.sol";
import {WithdrawalToken} from "../src/WithdrawalToken.sol";
import {WithdrawalManager} from "../src/WithdrawalManager.sol";
import {WaitosaurBase} from "../src/WaitosaurBase.sol";
import {WaitosaurHolder} from "../src/WaitosaurHolder.sol";
import {WaitosaurObserver, IAumOracle} from "../src/WaitosaurObserver.sol";
import {Allowlist} from "../src/Allowlist.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {Receiver} from "../src/Receiver.sol";
import {Batch} from "../src/types/CoreTypes.sol";

/// @notice Lightweight mock ERC20 with configurable decimals for WBTC-like asset.
contract MockERC20 is ERC20 {
    uint8 private immutable _DECIMALS;

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) ERC20(name_, symbol_) {
        _DECIMALS = decimals_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public view override returns (uint8) {
        return _DECIMALS;
    }
}

contract MockAumOracle is IAumOracle {
    uint256 public balance;

    function setBalance(uint256 newBalance) external {
        balance = newBalance;
    }

    function getSpotBalance(
        string calldata /* asset */
    ) external view returns (uint256) {
        return balance;
    }
}

/// @dev Lightweight upgraded core for upgrade path test
contract CoreV2 is MaxBTCCore {
    function version() external pure returns (string memory) {
        return "v2";
    }
}

/// @notice Integration-style test that wires core, ERC20, withdrawal token, and manager together.
contract MaxBTCCoreIntegrationTest is Test {
    MaxBTCCore private core;
    MaxBTCERC20 private maxbtc;
    WithdrawalToken private withdrawalToken;
    WithdrawalManager private manager;
    WaitosaurHolder private waitosaurHolder;
    FeeCollector private feeCollector;
    WaitosaurObserver private waitosaurObserver;
    MockAumOracle private oracle;
    Receiver private provider;
    MockERC20 private wbtc;
    Allowlist private allowlist;

    address private constant USER = address(0xA11CE);
    address private constant OWNER = address(0x0B0B);
    address private constant OPERATOR = address(0x0C0C);
    address private constant DEPOSIT_FORWARDER = address(0xD00D);
    address private constant TREASURY = address(0xBADA55);
    uint256 private constant DEPOSIT_COST = 1e16; // 1%
    uint256 private constant WITHDRAWAL_COST = 1e16; // 1%
    uint256 private constant FEE_REDUCTION = 1e17; // 10%

    function setUp() external {
        MaxBTCCore coreImpl = new MaxBTCCore();
        MaxBTCERC20 maxbtcImpl = new MaxBTCERC20();
        WithdrawalToken withdrawalTokenImpl = new WithdrawalToken();
        WithdrawalManager managerImpl = new WithdrawalManager();
        WaitosaurHolder waitosaurHolderImpl = new WaitosaurHolder();
        WaitosaurObserver waitosaurObserverImpl = new WaitosaurObserver();
        FeeCollector feeCollectorImpl = new FeeCollector();

        wbtc = new MockERC20("WBTC", "WBTC", 8);
        provider = new Receiver(address(this));
        Allowlist allowlistImpl = new Allowlist();
        ERC1967Proxy allowlistProxy = new ERC1967Proxy(
            address(allowlistImpl),
            abi.encodeCall(Allowlist.initialize, (address(this)))
        );
        allowlist = Allowlist(address(allowlistProxy));
        allowlist.allow(_arr(USER));
        oracle = new MockAumOracle();
        oracle.setBalance(type(uint256).max);
        // Seed ER for fee collector baseline
        provider.publish(1e18, block.timestamp);

        // Deploy proxies (uninitialized), so we can pass addresses into core init.
        ERC1967Proxy maxbtcProxy = new ERC1967Proxy(address(maxbtcImpl), "");
        ERC1967Proxy withdrawalProxy = new ERC1967Proxy(
            address(withdrawalTokenImpl),
            ""
        );
        ERC1967Proxy managerProxy = new ERC1967Proxy(address(managerImpl), "");
        ERC1967Proxy feeCollectorProxy = new ERC1967Proxy(
            address(feeCollectorImpl),
            ""
        );

        // Initialize core with the real addresses.
        ERC1967Proxy waitosaurProxy = new ERC1967Proxy(
            address(waitosaurHolderImpl),
            abi.encodeCall(
                WaitosaurHolder.initialize,
                (
                    address(this),
                    address(wbtc),
                    OPERATOR,
                    address(this),
                    address(managerProxy)
                )
            )
        );
        waitosaurHolder = WaitosaurHolder(address(waitosaurProxy));
        ERC1967Proxy waitosaurObserverProxy = new ERC1967Proxy(
            address(waitosaurObserverImpl),
            abi.encodeCall(
                WaitosaurObserver.initialize,
                (address(this), address(this), OPERATOR, address(oracle), "BTC")
            )
        );
        waitosaurObserver = WaitosaurObserver(address(waitosaurObserverProxy));

        ERC1967Proxy coreProxy = new ERC1967Proxy(
            address(coreImpl),
            abi.encodeCall(
                MaxBTCCore.initialize,
                (
                    OWNER,
                    address(wbtc),
                    address(maxbtcProxy),
                    address(withdrawalProxy),
                    address(provider),
                    DEPOSIT_FORWARDER,
                    address(waitosaurObserver),
                    address(waitosaurHolder),
                    1 days,
                    address(allowlist),
                    address(feeCollectorProxy),
                    address(managerProxy),
                    OPERATOR,
                    DEPOSIT_COST,
                    WITHDRAWAL_COST,
                    0,
                    false
                )
            )
        );
        core = MaxBTCCore(address(coreProxy));
        maxbtc = MaxBTCERC20(address(maxbtcProxy));
        withdrawalToken = WithdrawalToken(address(withdrawalProxy));
        manager = WithdrawalManager(address(managerProxy));
        waitosaurObserver.updateRoles(address(core), OPERATOR);
        waitosaurObserver.updateConfig(address(oracle), "");
        waitosaurHolder.updateRoles(OPERATOR, address(core));
        waitosaurHolder.updateConfig(address(manager));

        // Now initialize dependent contracts with the finalized core address.
        maxbtc.initialize(address(this), address(this), "maxBTC", "maxBTC");
        maxbtc.initializeV2(address(core));
        withdrawalToken.initialize(
            address(this),
            address(core),
            address(managerProxy),
            "ipfs://base/",
            "Redemption",
            "rMAX-"
        );
        manager.initialize(
            address(this),
            address(core),
            address(wbtc),
            address(withdrawalToken),
            address(allowlist)
        );
        feeCollector = FeeCollector(address(feeCollectorProxy));
        feeCollector.initialize(
            OWNER,
            address(core),
            address(provider),
            FEE_REDUCTION,
            3600,
            address(maxbtc)
        );

        // address(this) plays role of ics20 for maxBTC ERC20 contract, hence
        // it will need some rate limits allowance to pass these tests
        maxbtc.setEurekaRateLimits(1e18, 1e18);
    }

    function testIntegrationDepositWithdrawRedeem() external {
        // Publish ER and AUM
        uint256 er = 1e18; // 1:1
        provider.publish(er, block.timestamp);
        provider.publishAum(0, wbtc.decimals());

        // User deposits 2 WBTC
        uint256 depositAmount = 2e8;
        wbtc.mint(USER, depositAmount);
        vm.startPrank(USER);
        wbtc.approve(address(core), depositAmount);
        core.deposit(depositAmount, USER, 0);
        vm.stopPrank();

        // User withdraws 1 maxBTC
        uint256 burnAmount = 1e8;
        vm.prank(USER);
        core.withdraw(burnAmount);

        // Operator processes batch; fully covered by deposits so it finalizes immediately.
        vm.prank(OPERATOR);
        bool finalized = core.tick();
        assertTrue(finalized, "batch should finalize");
        Batch memory processed = core.finalizedBatch(0);

        // Check manager received the payout and fee collector got the fee.
        uint256 expectedCollected = processed.collectedAmount;
        assertGt(expectedCollected, 0, "collected positive");
        assertEq(
            wbtc.balanceOf(address(manager)),
            expectedCollected,
            "manager funded"
        );
        assertGt(
            wbtc.balanceOf(address(feeCollector)),
            0,
            "fee collector funded"
        );

        // User redeems withdrawal token through manager
        vm.startPrank(USER);
        withdrawalToken.safeTransferFrom(
            USER,
            address(manager),
            processed.batchId,
            burnAmount,
            ""
        );
        vm.stopPrank();

        // Redemption should burn redemption tokens and send collectedAmount to the user.
        assertEq(
            withdrawalToken.totalSupply(processed.batchId),
            0,
            "redemption tokens burned"
        );
        assertEq(
            wbtc.balanceOf(USER),
            expectedCollected,
            "user received redemption payout"
        );
    }

    function testDepositCycleTicksFollowFsm() external {
        uint256 depositAmount = 5e7;
        // Fund core directly to simulate accumulated deposits
        wbtc.mint(address(core), depositAmount);

        // Idle -> DepositEthereum; locks waitosaur observer and flushes funds
        vm.prank(OPERATOR);
        core.tick();
        assertEq(uint8(core.contractState()), 1, "DepositEthereum");
        assertEq(waitosaurObserver.lockedAmount(), depositAmount);
        assertEq(wbtc.balanceOf(DEPOSIT_FORWARDER), depositAmount, "flushed");

        // Unlock observer and complete cycle back to Idle
        vm.prank(OPERATOR);
        waitosaurObserver.unlock();
        assertEq(waitosaurObserver.lockedAmount(), 0, "observer unlocked");
        vm.prank(OPERATOR);
        core.tick();
        assertEq(uint8(core.contractState()), 2, "DepositPending");
        vm.prank(OPERATOR);
        core.tick();
        assertEq(uint8(core.contractState()), 3, "DepositJlp");
        vm.prank(OPERATOR);
        core.tick();
        assertEq(uint8(core.contractState()), 0, "Idle");
    }

    function testWithdrawCycleTicksWithWaitosaurHolder() external {
        provider.publish(1e18, block.timestamp);
        provider.publishAum(0, wbtc.decimals());

        // Mint some maxBTC to user
        maxbtc.mint(USER, 2e8);
        // Provide partial deposits to core
        wbtc.mint(address(core), 5e7);

        vm.startPrank(USER);
        maxbtc.approve(address(core), type(uint256).max);
        core.withdraw(2e8);
        vm.stopPrank();

        // Idle -> WithdrawJlp
        vm.prank(OPERATOR);
        core.tick();
        assertEq(uint8(core.contractState()), 4, "WithdrawJlp");

        // WithdrawJlp -> WithdrawPending
        vm.prank(OPERATOR);
        core.tick();
        assertEq(uint8(core.contractState()), 5, "WithdrawPending");

        // Deposit some BTC into waitosaur holder and lock it to be collected.
        uint256 lockedAmount = 3e7;
        wbtc.mint(address(waitosaurHolder), lockedAmount);
        vm.prank(OPERATOR);
        waitosaurHolder.lock(lockedAmount);

        // WithdrawPending -> WithdrawEthereum; should pull locked funds
        vm.prank(OPERATOR);
        core.tick();
        assertEq(uint8(core.contractState()), 6, "WithdrawEthereum");
        // First leg was partially covered with fees applied, then lockedAmount added.
        uint256 expectedCovered = (5e7 * (1e18 - DEPOSIT_COST)) / 1e18;
        expectedCovered = (expectedCovered * (1e18 - WITHDRAWAL_COST)) / 1e18;
        uint256 expectedTotal = expectedCovered + lockedAmount;
        assertEq(
            wbtc.balanceOf(address(manager)),
            expectedTotal,
            "manager got collected + partial"
        );
        assertEq(waitosaurHolder.lockedAmount(), 0, "holder unlocked");

        // Finalize and return to Idle
        vm.prank(OPERATOR);
        core.tick();
        assertEq(uint8(core.contractState()), 0, "Idle");

        Batch memory finalized = core.finalizedBatch(0);
        assertEq(finalized.collectedAmount, expectedTotal);
    }

    function testFeeCollectorCollectsAndClaims() external {
        // Mint supply via deposit
        provider.publish(1e18, block.timestamp);
        uint256 depositAmount = 2e8;
        wbtc.mint(USER, depositAmount);
        vm.startPrank(USER);
        wbtc.approve(address(core), depositAmount);
        core.deposit(depositAmount, USER, 0);
        vm.stopPrank();
        uint256 totalSupplyBefore = maxbtc.totalSupply();

        // Advance time to satisfy collection period and increase ER
        vm.warp(block.timestamp + 3601);
        provider.publish(11e17, block.timestamp); // 1.1x ER

        provider.publishAum(int256(wbtc.totalSupply()), wbtc.decimals());
        // Collect fee (mints to feeCollector address through core.mintFee)
        vm.prank(OWNER);
        feeCollector.collectFee();
        uint256 minted = maxbtc.balanceOf(address(feeCollector));
        assertGt(minted, 0, "fee minted");
        assertEq(
            maxbtc.totalSupply(),
            totalSupplyBefore + minted,
            "supply increased by minted fee"
        );

        // Claim minted fees to treasury
        vm.prank(OWNER);
        feeCollector.claim(minted, TREASURY);
        assertEq(maxbtc.balanceOf(TREASURY), minted, "claimed to treasury");
    }

    function testAllowlistEndToEnd() external {
        allowlist.deny(_arr(USER));
        wbtc.mint(USER, 1e8);
        vm.startPrank(USER);
        wbtc.approve(address(core), 1e8);
        vm.expectRevert(
            abi.encodeWithSelector(MaxBTCCore.AddressNotAllowed.selector, USER)
        );
        core.deposit(1e8, USER, 0);
        vm.stopPrank();
    }

    function testMinReceiveSlippage() external {
        provider.publish(1e18, block.timestamp);
        uint256 amount = 1e8;
        wbtc.mint(USER, amount);
        vm.startPrank(USER);
        wbtc.approve(address(core), amount);
        uint256 minted = (amount * (1e18 - DEPOSIT_COST)) / 1e18;
        vm.expectRevert(
            abi.encodeWithSelector(
                MaxBTCCore.SlippageLimitExceeded.selector,
                minted + 1,
                minted
            )
        );
        core.deposit(amount, USER, minted + 1);
        vm.stopPrank();
    }

    function testCapAumRejection() external {
        vm.prank(OWNER);
        core.setDepositsCap(1e8, true); // cap 1 WBTC
        provider.publishAum(int256(1e8), wbtc.decimals()); // already at cap
        provider.publish(1e18, block.timestamp);
        wbtc.mint(USER, 1);
        vm.startPrank(USER);
        wbtc.approve(address(core), 1);
        vm.expectRevert(MaxBTCCore.DepositCapExceeded.selector);
        core.deposit(1, USER, 0);
        vm.stopPrank();
    }

    function testPauseAndOperatorPermissions() external {
        vm.prank(OWNER);
        core.setPaused(true);
        vm.startPrank(USER);
        wbtc.mint(USER, 1);
        wbtc.approve(address(core), 1);
        vm.expectRevert(MaxBTCCore.ContractPaused.selector);
        core.deposit(1, USER, 0);
        vm.stopPrank();

        vm.prank(OWNER);
        core.setPaused(false);
        vm.prank(OPERATOR);
        core.tick(); // operator may tick while unpaused
        address random = address(0x1234);
        vm.startPrank(random);
        vm.expectRevert(MaxBTCCore.InvalidOperatorAddress.selector);
        core.tick();
        vm.stopPrank();
    }

    function testUpgradePathKeepsState() external {
        provider.publish(1e18, block.timestamp);
        provider.publishAum(0, wbtc.decimals());
        uint256 depositAmount = 1e8;
        // Seed a deposit and withdrawal to populate storage
        wbtc.mint(USER, depositAmount);
        vm.startPrank(USER);
        wbtc.approve(address(core), depositAmount);
        core.deposit(depositAmount, USER, 0);
        core.withdraw(5e7);
        vm.stopPrank();
        vm.prank(OPERATOR);
        bool finalizedBefore = core.tick();
        assertTrue(finalizedBefore, "finalized pre-upgrade");
        Batch memory storedBefore = core.finalizedBatch(0);
        uint256 activeBatchIdBefore = core.activeBatch().batchId;
        uint256 supplyBefore = maxbtc.totalSupply();

        CoreV2 newImpl = new CoreV2();
        vm.prank(OWNER);
        core.upgradeToAndCall(address(newImpl), "");
        assertEq(CoreV2(address(core)).version(), "v2");
        assertEq(
            core.activeBatch().batchId,
            activeBatchIdBefore,
            "batch id kept"
        );
        Batch memory storedAfter = core.finalizedBatch(0);
        assertEq(
            storedAfter.collectedAmount,
            storedBefore.collectedAmount,
            "finalized batch kept"
        );

        // Post-upgrade operations still work
        wbtc.mint(USER, depositAmount);
        vm.startPrank(USER);
        wbtc.approve(address(core), depositAmount);
        core.deposit(depositAmount, USER, 0);
        vm.stopPrank();
        assertGt(
            maxbtc.totalSupply(),
            supplyBefore,
            "post-upgrade deposit works"
        );
    }

    function testMultiCycleInterleavedFsmAndLockCarryOver() external {
        provider.publish(1e18, block.timestamp);
        // Cycle 1: cover withdrawal fully and return to Idle
        wbtc.mint(USER, 2e8);
        vm.startPrank(USER);
        wbtc.approve(address(core), 2e8);
        core.deposit(2e8, USER, 0);
        core.withdraw(5e7);
        vm.stopPrank();
        vm.prank(OPERATOR);
        core.tick();
        assertEq(uint8(core.contractState()), 0, "finalized and idle");
        assertEq(core.activeBatch().batchId, 1, "batch incremented");

        // Cycle 2: leave observer locked from previous flush and ensure next tick reverts
        uint256 depositBalance = 1e8;
        wbtc.mint(address(core), depositBalance);
        vm.prank(OPERATOR);
        core.tick(); // Idle -> DepositEthereum and lock
        assertEq(uint8(core.contractState()), 1, "DepositEthereum");
        vm.prank(OPERATOR);
        vm.expectRevert(MaxBTCCore.WaitosaurLocked.selector);
        core.tick();
        // Unlock and finish cycle, batch id should advance to 2 after full cycle
        vm.prank(OPERATOR);
        waitosaurObserver.unlock();
        vm.prank(OPERATOR);
        core.tick(); // DepositPending
        vm.prank(OPERATOR);
        core.tick(); // DepositJlp
        vm.prank(OPERATOR);
        core.tick(); // Idle
        // Start a new withdrawal to advance batch id
        vm.prank(USER);
        core.withdraw(5e7);
        vm.prank(OPERATOR);
        core.tick(); // Idle -> WithdrawJlp (creates withdrawing batch id 1, active batch id 2)
        vm.prank(OPERATOR);
        core.tick(); // WithdrawPending
        vm.prank(OPERATOR);
        core.tick(); // WithdrawEthereum
        vm.prank(OPERATOR);
        core.tick(); // finalize -> Idle
        assertEq(core.activeBatch().batchId, 2, "batch incremented again");
    }

    function testFinalizeWithdrawingBatchEdgeAmounts() external {
        provider.publish(1e18, block.timestamp);
        // Mint via owner (no deposits) then trigger withdrawing batch
        vm.prank(OWNER);
        core.mintByOwner(1e8, USER);
        assertEq(maxbtc.balanceOf(USER), 1e8, "owner mint delivered");
        vm.prank(USER);
        core.withdraw(1e8);
        vm.prank(OPERATOR);
        core.tick(); // creates withdrawing batch

        // Calling finalize with same collectedAmount should succeed and keep amount
        vm.prank(OPERATOR);
        core.finalizeWithdrawingBatch(0);
        Batch memory stored = core.finalizedBatch(0);
        assertEq(stored.collectedAmount, 0, "kept collected amount");

        // No withdrawing batch after finalization
        vm.prank(OPERATOR);
        vm.expectRevert(MaxBTCCore.WithdrawingBatchMissing.selector);
        core.finalizeWithdrawingBatch(0);

        // Recreate withdrawing batch and ensure lower amount reverts
        vm.prank(OWNER);
        core.mintByOwner(1e8, USER);
        vm.prank(USER);
        core.withdraw(1e8);
        // Provide partial deposits so collectedAmount > 0
        wbtc.mint(address(core), 1e7);
        vm.prank(OPERATOR);
        core.tick();
        vm.prank(OPERATOR);
        vm.expectRevert(MaxBTCCore.InvalidAmount.selector);
        core.finalizeWithdrawingBatch(0);
    }

    function testRedemptionRoundingEdge() external {
        provider.publish(1e18, block.timestamp);
        // Mint via owner then burn large amount, tiny collected
        vm.prank(OWNER);
        core.mintByOwner(1e8, USER);
        assertEq(maxbtc.balanceOf(USER), 1e8, "owner mint delivered");
        vm.prank(USER);
        core.withdraw(1e8);
        vm.prank(OPERATOR);
        core.tick(); // create withdrawing batch
        // Finalize with tiny collected amount of 1 sat (1 wei of WBTC decimals)
        wbtc.mint(address(core), 1); // fund core for transfer
        vm.prank(OPERATOR);
        core.finalizeWithdrawingBatch(1);

        Batch memory finalized = core.finalizedBatch(0);
        assertEq(finalized.collectedAmount, 1, "tiny collected stored");

        // Redeem should pay out floor proportionally (all to user)
        vm.prank(USER);
        withdrawalToken.safeTransferFrom(USER, address(manager), 0, 1e8, "");
        assertEq(wbtc.balanceOf(USER), 1, "received tiny payout");
        assertEq(withdrawalToken.totalSupply(0), 0, "all tokens burned");
    }

    function testUpgradeKeepsConfigAndMidState() external {
        provider.publish(1e18, block.timestamp);
        // Move FSM to DepositPending before upgrade
        wbtc.mint(address(core), 1e7);
        vm.prank(OPERATOR);
        core.tick(); // DepositEthereum
        uint8 preState = uint8(core.contractState());
        CoreV2 newImpl = new CoreV2();
        vm.prank(OWNER);
        core.upgradeToAndCall(address(newImpl), "");
        assertEq(CoreV2(address(core)).version(), "v2");
        assertEq(uint8(core.contractState()), preState, "state preserved");
        uint256 forwarderBefore = wbtc.balanceOf(DEPOSIT_FORWARDER);
        uint256 extraDeposit = 5e6;
        wbtc.mint(address(core), extraDeposit);
        vm.prank(OPERATOR);
        waitosaurObserver.unlock(); // unlock observer for continued deposit flow
        vm.prank(OPERATOR);
        core.tick();
        vm.prank(OPERATOR);
        core.tick();
        vm.prank(OPERATOR);
        core.tick();
        assertEq(uint8(core.contractState()), 0, "returned idle");
        vm.prank(OPERATOR);
        core.tick(); // flush extra deposit from Idle
        assertEq(
            wbtc.balanceOf(DEPOSIT_FORWARDER) - forwarderBefore,
            extraDeposit,
            "forwarder still receives flush"
        );
    }

    function testAllowlistToggleMidSession() external {
        provider.publish(1e18, block.timestamp);
        wbtc.mint(USER, 1e8);
        vm.startPrank(USER);
        wbtc.approve(address(core), 1e8);
        core.deposit(1e8, USER, 0); // allowed
        vm.stopPrank();

        // Disallow user blocks further deposits
        allowlist.deny(_arr(USER));
        vm.startPrank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(MaxBTCCore.AddressNotAllowed.selector, USER)
        );
        core.deposit(1, USER, 0);
        vm.stopPrank();

        // Re-allow and withdraw works
        allowlist.allow(_arr(USER));
        vm.prank(USER);
        core.withdraw(5e7);
        vm.prank(OPERATOR);
        core.tick();
        Batch memory processed = core.finalizedBatch(0);
        assertGt(processed.collectedAmount, 0, "processed withdrawal");
    }

    function testPauseDuringMidFsmBlocksTick() external {
        wbtc.mint(address(core), 1e7);
        vm.prank(OPERATOR);
        core.tick(); // Idle -> DepositEthereum
        assertEq(uint8(core.contractState()), 1, "DepositEthereum");
        vm.prank(OWNER);
        core.setPaused(true);
        vm.prank(OPERATOR);
        vm.expectRevert(MaxBTCCore.ContractPaused.selector);
        core.tick();
        vm.prank(OWNER);
        core.setPaused(false);
        vm.prank(OPERATOR);
        waitosaurObserver.unlock();
        vm.prank(OPERATOR);
        core.tick(); // continue to DepositPending
        assertEq(uint8(core.contractState()), 2, "DepositPending");
    }

    function testExtremeCostsZeroAndHigh() external {
        provider.publish(1e18, block.timestamp);
        vm.prank(OWNER);
        core.setCosts(0, 0);
        wbtc.mint(USER, 1e8);
        vm.startPrank(USER);
        wbtc.approve(address(core), 1e8);
        core.deposit(1e8, USER, 1e8); // 1:1 mint
        vm.stopPrank();
        assertEq(maxbtc.balanceOf(USER), 1e8, "minted 1:1");

        // Near-limit costs still accepted
        uint256 nearMax = 999e15; // 99.9%
        vm.prank(OWNER);
        core.setCosts(nearMax, nearMax);
        uint256 amount = 1e8;
        wbtc.mint(USER, amount);
        vm.startPrank(USER);
        wbtc.approve(address(core), amount);
        uint256 minReceive = (amount * (1e18 - nearMax)) / 1e18;
        core.deposit(amount, USER, minReceive);
        vm.stopPrank();
        assertEq(
            maxbtc.balanceOf(USER),
            1e8 + minReceive,
            "minted with high fee"
        );
    }

    function testMinReceiveFailsOnWorseErAfterApproval() external {
        provider.publish(1e18, block.timestamp);
        uint256 amount = 1e8;
        wbtc.mint(USER, amount);
        uint256 minReceive = (amount * (1e18 - DEPOSIT_COST)) / 1e18;
        vm.startPrank(USER);
        wbtc.approve(address(core), amount);
        // Publish worse ER so mint amount drops
        vm.stopPrank();
        provider.publish(2e18, block.timestamp);
        vm.startPrank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                MaxBTCCore.SlippageLimitExceeded.selector,
                minReceive,
                minReceive / 2
            )
        );
        core.deposit(amount, USER, minReceive);
        vm.stopPrank();
    }

    function testWaitosaurHolderUnlockFailures() external {
        _moveToWithdrawPendingWithLock(5e7);
        // Ensure roles set correctly for unlocker
        waitosaurHolder.updateRoles(OPERATOR, address(core));
        // Drain holder balance to force insufficient balance on unlock
        vm.startPrank(address(waitosaurHolder));
        SafeERC20.safeTransfer(
            IERC20(address(wbtc)),
            address(0xdead),
            wbtc.balanceOf(address(waitosaurHolder))
        );
        vm.stopPrank();
        vm.prank(OPERATOR);
        vm.expectRevert(WaitosaurBase.InsufficientAssetAmount.selector);
        core.tick(); // WithdrawPending -> should fail unlock

        // Unauthorized unlock attempt
        address random = address(0xBADC0DE);
        vm.prank(random);
        vm.expectRevert(WaitosaurBase.Unauthorized.selector);
        waitosaurHolder.unlock();
    }

    function testCapToggleAllowsLaterDeposits() external {
        provider.publish(1e18, block.timestamp);
        vm.prank(OWNER);
        core.setDepositsCap(1e8, true); // cap 1 WBTC
        provider.publishAum(int256(1e8), wbtc.decimals()); // at cap
        wbtc.mint(USER, 1e6);
        vm.startPrank(USER);
        wbtc.approve(address(core), 1e6);
        vm.expectRevert(MaxBTCCore.DepositCapExceeded.selector);
        core.deposit(1e6, USER, 0);
        vm.stopPrank();

        // Disable cap and deposit succeeds
        vm.prank(OWNER);
        core.setDepositsCap(0, false);
        vm.startPrank(USER);
        core.deposit(1e6, USER, 0);
        vm.stopPrank();
        assertGt(maxbtc.balanceOf(USER), 0, "deposit now allowed");
    }

    function _moveToWithdrawPendingWithLock(uint256 lockAmount) private {
        provider.publish(1e18, block.timestamp);
        vm.prank(OWNER);
        core.mintByOwner(1e8, USER);
        assertEq(maxbtc.balanceOf(USER), 1e8, "owner mint delivered");
        vm.prank(USER);
        core.withdraw(1e8);
        vm.prank(OPERATOR);
        core.tick(); // Idle -> WithdrawJlp
        vm.prank(OPERATOR);
        core.tick(); // WithdrawJlp -> WithdrawPending
        wbtc.mint(address(waitosaurHolder), lockAmount);
        vm.prank(OPERATOR);
        waitosaurHolder.lock(lockAmount);
    }

    function testMultiUserWithdrawalsAndRedemptions() external {
        provider.publish(1e18, block.timestamp);
        uint256 depositAmount = 2e8;
        // Two users deposit
        address user1 = USER;
        address user2 = address(0xB0B0);
        allowlist.allow(_arr(user2));
        wbtc.mint(user1, depositAmount);
        wbtc.mint(user2, depositAmount);
        vm.startPrank(user1);
        wbtc.approve(address(core), depositAmount);
        core.deposit(depositAmount, user1, 0);
        vm.stopPrank();
        vm.startPrank(user2);
        wbtc.approve(address(core), depositAmount);
        core.deposit(depositAmount, user2, 0);
        vm.stopPrank();

        // Both withdraw
        vm.startPrank(user1);
        core.withdraw(5e7);
        vm.stopPrank();
        vm.startPrank(user2);
        core.withdraw(5e7);
        vm.stopPrank();

        // Tick should finalize (enough deposits)
        vm.prank(OPERATOR);
        core.tick();
        Batch memory finalized = core.finalizedBatch(0);
        uint256 totalSupplyRedemption = withdrawalToken.totalSupply(
            finalized.batchId
        );
        assertEq(totalSupplyRedemption, 1e8, "redemption supply");

        // Each redeems half
        vm.startPrank(user1);
        withdrawalToken.safeTransferFrom(
            user1,
            address(manager),
            finalized.batchId,
            5e7,
            ""
        );
        vm.stopPrank();
        vm.startPrank(user2);
        withdrawalToken.safeTransferFrom(
            user2,
            address(manager),
            finalized.batchId,
            5e7,
            ""
        );
        vm.stopPrank();
        assertEq(
            withdrawalToken.totalSupply(finalized.batchId),
            0,
            "all redemption burned"
        );
        // Manager transfers proportionally
        uint256 expectedUser = (finalized.collectedAmount * 5e7) / 1e8;
        assertEq(wbtc.balanceOf(user1), expectedUser);
        assertEq(wbtc.balanceOf(user2), expectedUser);
    }

    function testObserverLockedBlocksDepositTick() external {
        wbtc.mint(address(core), 1e7);
        // First tick locks observer
        vm.prank(OPERATOR);
        core.tick();
        // Second tick should revert until unlock is called
        vm.prank(OPERATOR);
        vm.expectRevert(MaxBTCCore.WaitosaurLocked.selector);
        core.tick();
    }

    function _arr(address a) private pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }
}
