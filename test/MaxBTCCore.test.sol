// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MaxBTCCore} from "../src/MaxBTCCore.sol";
import {MaxBTCERC20} from "../src/MaxBTCERC20.sol";
import {WithdrawalToken} from "../src/WithdrawalToken.sol";
import {WaitosaurHolder} from "../src/WaitosaurHolder.sol";
import {Allowlist} from "../src/Allowlist.sol";
import {Receiver} from "../src/Receiver.sol";
import {Batch} from "../src/types/CoreTypes.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

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

contract MockWaitosaurObserver {
    bool public locked;
    uint256 public lastLockedAmount;

    function setLocked(bool newLocked) external {
        locked = newLocked;
    }

    function lock(uint256 amount) external {
        require(!locked, "locked");
        locked = true;
        lastLockedAmount = amount;
    }

    function isLocked() external view returns (bool) {
        return locked;
    }

    function lockedAmount() external view returns (uint256) {
        return locked ? lastLockedAmount : 0;
    }
}

contract MaxBTCCoreTest is Test {
    MaxBTCCore private core;
    MaxBTCERC20 private maxbtc;
    WithdrawalToken private withdrawalToken;
    WaitosaurHolder private waitosaurHolder;
    Receiver private provider;
    MockERC20 private depositToken;
    Allowlist private allowlist;
    MockWaitosaurObserver private waitosaurObserver;

    address private constant USER = address(0xA11CE);
    address private constant WITHDRAWAL_MANAGER = address(0xBEEF);
    address private constant FEE_COLLECTOR = address(0xFEE);
    address private constant DEPOSIT_FORWARDER = address(0xD3F0);
    address private constant OPERATOR = address(0x0B0B);

    uint256 private constant DEPOSIT_COST = 2e16; // 2%
    uint256 private constant WITHDRAWAL_COST = 1e16; // 1%

    function setUp() external {
        MaxBTCCore coreImpl = new MaxBTCCore();
        MaxBTCERC20 maxbtcImpl = new MaxBTCERC20();
        WithdrawalToken withdrawalTokenImpl = new WithdrawalToken();
        WaitosaurHolder waitosaurHolderImpl = new WaitosaurHolder();
        provider = new Receiver(address(this));
        depositToken = new MockERC20("WBTC", "WBTC", 8);
        Allowlist allowlistImpl = new Allowlist();
        ERC1967Proxy allowlistProxy = new ERC1967Proxy(
            address(allowlistImpl),
            abi.encodeCall(Allowlist.initialize, (address(this)))
        );
        allowlist = Allowlist(address(allowlistProxy));
        waitosaurObserver = new MockWaitosaurObserver();

        ERC1967Proxy maxbtcProxy = new ERC1967Proxy(address(maxbtcImpl), "");
        ERC1967Proxy withdrawalProxy = new ERC1967Proxy(
            address(withdrawalTokenImpl),
            ""
        );
        ERC1967Proxy waitosaurProxy = new ERC1967Proxy(
            address(waitosaurHolderImpl),
            abi.encodeCall(
                WaitosaurHolder.initialize,
                (
                    address(this),
                    address(depositToken),
                    OPERATOR,
                    address(this),
                    WITHDRAWAL_MANAGER
                )
            )
        );
        waitosaurHolder = WaitosaurHolder(address(waitosaurProxy));

        ERC1967Proxy coreProxy = new ERC1967Proxy(
            address(coreImpl),
            abi.encodeCall(
                MaxBTCCore.initialize,
                (
                    address(this),
                    address(depositToken),
                    address(maxbtcProxy),
                    address(withdrawalProxy),
                    address(provider),
                    DEPOSIT_FORWARDER,
                    address(waitosaurObserver),
                    address(waitosaurHolder),
                    1 days,
                    address(allowlist),
                    FEE_COLLECTOR,
                    WITHDRAWAL_MANAGER,
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

        maxbtc.initialize(
            address(this),
            address(this), // placeholder ICS20; updated below
            "maxBTC",
            "maxBTC"
        );
        maxbtc.initializeV2(address(core));
        maxbtc.updateIcs20(OPERATOR); // allow operator-driven burns during ticks
        maxbtc.setEurekaRateLimits(1e18, 1e18); // needed for ICS20 to be allowed to mint

        withdrawalToken.initialize(
            address(this),
            address(core),
            WITHDRAWAL_MANAGER,
            "ipfs://test/",
            "Redemption",
            "rMAX-"
        );
        waitosaurHolder.updateRoles(OPERATOR, address(core));
        waitosaurHolder.updateConfig(WITHDRAWAL_MANAGER);

        allowlist.allow(_arr(USER));
        provider.publishAum(int256(1), depositToken.decimals());
    }

    function testDepositMintsWithFeeAndAllowlist() external {
        uint256 amount = 1e8; // 1 WBTC with 8 decimals
        _publishRate(2e18);
        depositToken.mint(USER, amount);

        vm.startPrank(USER);
        depositToken.approve(address(core), amount);
        core.deposit(amount, USER, 0);
        vm.stopPrank();

        uint256 expectedMint = (amount * (1e18 - DEPOSIT_COST)) / 2e18;
        assertEq(maxbtc.balanceOf(USER), expectedMint, "minted amount");
        assertEq(
            depositToken.balanceOf(address(core)),
            amount,
            "deposits held by core"
        );
    }

    function testDepositFailsWhenPaused() external {
        core.setPaused(true);
        depositToken.mint(USER, 1);
        vm.startPrank(USER);
        depositToken.approve(address(core), 1);
        vm.expectRevert(MaxBTCCore.ContractPaused.selector);
        core.deposit(1, USER, 0);
        vm.stopPrank();
    }

    function testMintByOwnerMintsToRecipient() external {
        vm.prank(address(core));
        maxbtc.mint(address(0xFACE), 0); // noop to ensure contract exists
        uint256 amount = 5e7;
        core.mintByOwner(amount, USER);
        assertEq(maxbtc.balanceOf(USER), amount, "owner mint delivered");
    }

    function testMintFeeByCollector() external {
        uint256 amount = 3e7;
        provider.publishAum(int256(1), depositToken.decimals());
        vm.prank(FEE_COLLECTOR);
        core.mintFee(amount);
        assertEq(maxbtc.balanceOf(FEE_COLLECTOR), amount, "fee minted");
    }

    function testMintFeeRevertsWhenAumNonPositive() external {
        uint256 amount = 1e7;
        provider.publishAum(int256(-1), depositToken.decimals());
        // do not publish AUM (default 0) -> should revert
        vm.prank(FEE_COLLECTOR);
        vm.expectRevert(MaxBTCCore.AumMustBePositive.selector);
        core.mintFee(amount);
    }

    function testDepositRejectsNotAllowlisted() external {
        allowlist.deny(_arr(USER));
        _publishRate(1e18);
        depositToken.mint(USER, 1e8);
        vm.startPrank(USER);
        depositToken.approve(address(core), 1e8);
        vm.expectRevert(
            abi.encodeWithSelector(MaxBTCCore.AddressNotAllowed.selector, USER)
        );
        core.deposit(1e8, USER, 0);
        vm.stopPrank();
    }

    function testDepositStaleExchangeRate() external {
        uint256 amount = 1e8;
        depositToken.mint(USER, amount);
        provider.publish(1e18, block.timestamp - 2 days);
        vm.startPrank(USER);
        depositToken.approve(address(core), amount);
        vm.expectRevert(MaxBTCCore.ExchangeRateStale.selector);
        core.deposit(amount, USER, 0);
        vm.stopPrank();
    }

    function testDepositExceedsCapReverts() external {
        core.setDepositsCap(100e8, true);
        _publishRate(1e18);
        provider.publishAum(int256(100e8), depositToken.decimals());
        depositToken.mint(USER, 1);
        vm.startPrank(USER);
        depositToken.approve(address(core), 1);
        vm.expectRevert(MaxBTCCore.DepositCapExceeded.selector);
        core.deposit(1, USER, 0);
        vm.stopPrank();
    }

    function testDepositSlippageLimit() external {
        uint256 amount = 1e8;
        _publishRate(1e18);
        depositToken.mint(USER, amount);
        vm.startPrank(USER);
        depositToken.approve(address(core), amount);
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

    function testWithdrawAndTickFinalizesWhenCovered() external {
        uint256 depositAmount = 1e8;
        _publishRate(1e18);
        depositToken.mint(USER, depositAmount);

        vm.startPrank(USER);
        depositToken.approve(address(core), depositAmount);
        core.deposit(depositAmount, USER, 0);

        uint256 burnAmount = 5e7; // 0.5 maxBTC
        maxbtc.approve(address(core), burnAmount);
        core.withdraw(burnAmount);
        vm.stopPrank();

        vm.prank(OPERATOR);
        bool finalized = core.tick();
        Batch memory processed = core.finalizedBatch(0);

        uint256 depositBeforeFees = (processed.btcRequested *
            1e18 +
            (1e18 - DEPOSIT_COST) -
            1) / (1e18 - DEPOSIT_COST);
        uint256 offsettingAfterDepositCost = (depositBeforeFees *
            (1e18 - DEPOSIT_COST)) / 1e18;
        uint256 expectedCollected = (offsettingAfterDepositCost *
            (1e18 - WITHDRAWAL_COST)) / 1e18;
        uint256 expectedCost = depositBeforeFees - expectedCollected;

        assertTrue(finalized, "finalized");
        assertEq(processed.maxBtcToBurn, burnAmount, "burned amount");
        assertEq(processed.collectedAmount, expectedCollected, "collected");
        assertEq(
            depositToken.balanceOf(WITHDRAWAL_MANAGER),
            expectedCollected,
            "withdrawal manager received"
        );
        assertEq(
            depositToken.balanceOf(FEE_COLLECTOR),
            expectedCost,
            "fee collector received"
        );

        Batch memory stored = core.finalizedBatch(processed.batchId);
        assertEq(stored.collectedAmount, expectedCollected, "finalized stored");
        assertEq(
            core.activeBatch().batchId,
            processed.batchId + 1,
            "new batch"
        );
    }

    function testPartialCoverageMovesToWithdrawingAndFinalizeLater() external {
        _publishRate(1e18);

        // Mint maxBTC directly via ICS20 mock hook.
        vm.prank(address(core));
        maxbtc.mint(USER, 2e8);
        // Fund the core with limited deposits so the batch cannot be fully covered.
        depositToken.mint(address(core), 5e7);

        vm.prank(USER);
        maxbtc.approve(address(core), type(uint256).max);
        vm.prank(USER);
        core.withdraw(2e8);

        vm.prank(OPERATOR);
        bool finalized = core.tick();
        assertFalse(finalized, "should move to withdrawing");
        (Batch memory processed, bool has) = core.withdrawingBatch();
        assertTrue(has, "withdrawing batch exists");
        uint256 expectedCollected = (5e7 * (1e18 - DEPOSIT_COST)) / 1e18;
        expectedCollected =
            (expectedCollected * (1e18 - WITHDRAWAL_COST)) /
            1e18;
        assertEq(
            processed.collectedAmount,
            expectedCollected,
            "partially covered"
        );
        assertEq(
            depositToken.balanceOf(WITHDRAWAL_MANAGER),
            expectedCollected,
            "covered portion sent"
        );

        // Off-chain bridge delivers remaining 1.5 WBTC.
        uint256 targetCollected = 2e8;
        uint256 additional = targetCollected - processed.collectedAmount;
        depositToken.mint(address(core), additional);
        vm.prank(OPERATOR);
        core.finalizeWithdrawingBatch(targetCollected);

        Batch memory stored = core.finalizedBatch(processed.batchId);
        assertEq(stored.collectedAmount, targetCollected, "final collected");
        assertEq(
            depositToken.balanceOf(WITHDRAWAL_MANAGER),
            targetCollected,
            "withdrawal manager received rest"
        );
    }

    function testFsmDepositCycleFlushesAndReturnsToIdle() external {
        uint256 depositAmount = 5e7;
        depositToken.mint(address(core), depositAmount);
        assertEq(uint8(core.contractState()), 0, "starts idle");

        vm.prank(OPERATOR);
        core.tick();
        assertEq(uint8(core.contractState()), 1, "moved to DepositEthereum");
        assertEq(
            depositToken.balanceOf(DEPOSIT_FORWARDER),
            depositAmount,
            "forwarder received flush"
        );
        // Simulate observer unlocking after external chain confirmation.
        waitosaurObserver.setLocked(false);

        vm.prank(OPERATOR);
        core.tick();
        assertEq(uint8(core.contractState()), 2, "DepositPending");

        vm.prank(OPERATOR);
        core.tick();
        assertEq(uint8(core.contractState()), 3, "DepositJlp");

        vm.prank(OPERATOR);
        core.tick();
        assertEq(uint8(core.contractState()), 0, "back to Idle");
    }

    function testDepositEthereumRevertsWhenWaitosaurLocked() external {
        uint256 depositAmount = 1e7;
        depositToken.mint(address(core), depositAmount);
        vm.prank(OPERATOR);
        core.tick(); // Idle -> DepositEthereum
        waitosaurObserver.setLocked(true);
        vm.prank(OPERATOR);
        vm.expectRevert(MaxBTCCore.WaitosaurLocked.selector);
        core.tick(); // should revert trying to go DepositPending
    }

    function testFsmWithdrawCycleCompletes() external {
        _publishRate(1e18);
        // mint maxBTC and partial deposits so the batch is not fully covered
        vm.prank(address(core));
        maxbtc.mint(USER, 2e8);
        depositToken.mint(address(core), 5e7);

        vm.prank(USER);
        maxbtc.approve(address(core), type(uint256).max);
        vm.prank(USER);
        core.withdraw(2e8);

        vm.prank(OPERATOR);
        core.tick();
        assertEq(uint8(core.contractState()), 4, "WithdrawJlp");

        vm.prank(OPERATOR);
        core.tick();
        assertEq(uint8(core.contractState()), 5, "WithdrawPending");

        vm.prank(OPERATOR);
        core.tick();
        assertEq(uint8(core.contractState()), 6, "WithdrawNeutron");

        vm.prank(OPERATOR);
        core.tick();
        assertEq(uint8(core.contractState()), 0, "back to Idle");
        Batch memory stored = core.finalizedBatch(0);
        assertGt(stored.collectedAmount, 0, "finalized batch collected");
    }

    function testWithdrawPendingProcessesWaitosaurLock() external {
        _publishRate(1e18);
        vm.prank(address(core));
        maxbtc.mint(USER, 1e8);

        uint256 lockedAmount = 3e7;
        depositToken.mint(address(waitosaurHolder), lockedAmount);
        vm.prank(OPERATOR);
        waitosaurHolder.lock(lockedAmount);

        vm.prank(USER);
        maxbtc.approve(address(core), type(uint256).max);
        vm.prank(USER);
        core.withdraw(1e8);
        vm.prank(OPERATOR);
        core.tick(); // Idle -> WithdrawJlp
        vm.prank(OPERATOR);
        core.tick(); // WithdrawJlp -> WithdrawPending

        vm.prank(OPERATOR);
        core.tick(); // WithdrawPending processes waitosaur lock
        assertEq(uint8(core.contractState()), 6, "moved to WithdrawEthereum");
        assertEq(waitosaurHolder.lockedAmount(), 0, "waitosaur unlocked");
        assertEq(
            depositToken.balanceOf(WITHDRAWAL_MANAGER),
            lockedAmount,
            "locked funds forwarded to withdrawal manager"
        );

        vm.prank(OPERATOR);
        core.tick(); // finalize -> Idle
        assertEq(uint8(core.contractState()), 0, "back to Idle");
        Batch memory finalized = core.finalizedBatch(0);
        assertEq(finalized.collectedAmount, lockedAmount, "collected updated");
    }

    function testWithdrawNotAllowlistedReverts() external {
        allowlist.deny(_arr(USER));
        vm.expectRevert(
            abi.encodeWithSelector(MaxBTCCore.AddressNotAllowed.selector, USER)
        );
        vm.prank(USER);
        core.withdraw(1);
    }

    function testWithdrawPausedReverts() external {
        core.setPaused(true);
        vm.expectRevert(MaxBTCCore.ContractPaused.selector);
        vm.prank(USER);
        core.withdraw(1);
    }

    function testTickWithoutBurnedReverts() external {
        vm.prank(OPERATOR);
        core.tick();
        assertEq(uint8(core.contractState()), 0, "remains idle");
    }

    function testFinalizeWithdrawingBatchMissingReverts() external {
        vm.prank(OPERATOR);
        vm.expectRevert(MaxBTCCore.WithdrawingBatchMissing.selector);
        core.finalizeWithdrawingBatch(1);
    }

    function testTwoStepOwnershipTransfer() external {
        address newOwner = address(0xABCD);
        core.transferOwnership(newOwner);
        assertEq(core.pendingOwner(), newOwner, "pending owner set");

        vm.prank(newOwner);
        core.acceptOwnership();
        assertEq(core.owner(), newOwner, "ownership transferred");
        assertEq(core.pendingOwner(), address(0), "pending cleared");
    }

    function _publishRate(uint256 er) private {
        provider.publish(er, block.timestamp);
        provider.publishAum(
            int256(depositToken.totalSupply()),
            depositToken.decimals()
        );
    }

    function _arr(address a) private pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }
}
