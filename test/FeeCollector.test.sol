// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FeeCollector, ITwaerProvider, ICoreContract} from "../src/FeeCollector.sol"; // adjust the path if needed
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// Minimal ERC20 token used as fee token (maxBTC)
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        uint256 currentAllowance = allowance[from][msg.sender];
        require(currentAllowance >= amount, "insufficient allowance");
        allowance[from][msg.sender] = currentAllowance - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );
}

/// Mock core contract implementing ITwaerProvider + ICoreContract.
contract MockCore is ITwaerProvider, ICoreContract {
    uint256 public twaer;
    uint64 public publishedAt;

    uint256 public lastMintedAmount;

    MockERC20 public feeToken;
    address public feeRecipient;

    constructor() {
        // default rate = 1.0 * 1e18
        twaer = 1e18;
        publishedAt = uint64(block.timestamp);
    }

    function setRate(uint256 newRate) external {
        twaer = newRate;
        publishedAt = uint64(block.timestamp);
    }

    function setFeeToken(MockERC20 token, address recipient) external {
        feeToken = token;
        feeRecipient = recipient;
    }

    function getTwaer() external view override returns (uint256, uint64) {
        return (twaer, publishedAt);
    }

    function mintFee(uint256 amount) external override {
        lastMintedAmount = amount;
        if (address(feeToken) != address(0) && feeRecipient != address(0)) {
            feeToken.mint(feeRecipient, amount);
        }
    }
}

/// Simple V2 implementation to test UUPS upgrade.
contract FeeCollectorV2 is FeeCollector {
    function version() external pure returns (string memory) {
        return "v2";
    }
}

contract FeeCollectorTest is Test {
    FeeCollector internal feeCollector; // main proxy used in positive-path tests
    MockERC20 internal maxbtc;
    MockCore internal core;

    address internal owner = address(this);
    address internal other = address(0xBEEF);

    uint256 internal constant ONE = 1e18;

    // Helper to deploy a new impl + proxy and call initialize via constructor
    function _deployProxyWithInit(
        address owner_,
        address core_,
        uint256 feeApyReductionPercentage_,
        uint64 collectionPeriodSeconds_,
        address feeToken_,
        uint8 maxbtcDecimals_
    ) internal returns (FeeCollector) {
        FeeCollector impl = new FeeCollector();
        bytes memory data = abi.encodeWithSelector(
            FeeCollector.initialize.selector,
            owner_,
            core_,
            feeApyReductionPercentage_,
            collectionPeriodSeconds_,
            feeToken_,
            maxbtcDecimals_
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), data);
        return FeeCollector(address(proxy));
    }

    function setUp() public {
        maxbtc = new MockERC20("MaxBTC", "maxBTC", 6);
        core = new MockCore();

        // Main proxy for normal-path tests
        feeCollector = _deployProxyWithInit(
            owner,
            address(core),
            0.1e18, // 10% APY reduction as fee
            3600, // 1 hour collection period
            address(maxbtc),
            6 // 6 decimals for maxBTC
        );

        core.setFeeToken(maxbtc, address(feeCollector));

        FeeCollector.Config memory cfg = feeCollector.getConfig();
        FeeCollector.State memory st = feeCollector.getState();

        console2.log("Initial coreContract:", cfg.coreContract);
        console2.log(
            "Initial feeApyReductionPercentage:",
            cfg.feeApyReductionPercentage
        );
        console2.log(
            "Initial collectionPeriodSeconds:",
            cfg.collectionPeriodSeconds
        );
        console2.log("Initial maxbtcDecimals:", cfg.maxbtcDecimals);
        console2.log(
            "Initial lastCollectionTimestamp:",
            st.lastCollectionTimestamp
        );
        console2.log("Initial lastExchangeRate:", st.lastExchangeRate);
    }

    // --------------------------------------
    // Initialization edge cases (via proxy)
    // --------------------------------------

    function testInitializeRevertsOnZeroOwner() public {
        FeeCollector impl = new FeeCollector();
        bytes memory data = abi.encodeWithSelector(
            FeeCollector.initialize.selector,
            address(0), // invalid owner
            address(core),
            0.1e18,
            3600,
            address(maxbtc),
            6
        );
        vm.expectRevert(FeeCollector.InvalidOwnerAddress.selector);
        new ERC1967Proxy(address(impl), data);
    }

    function testInitializeRevertsOnZeroCoreContract() public {
        FeeCollector impl = new FeeCollector();
        bytes memory data = abi.encodeWithSelector(
            FeeCollector.initialize.selector,
            owner,
            address(0), // invalid core
            0.1e18,
            3600,
            address(maxbtc),
            6
        );
        vm.expectRevert(FeeCollector.InvalidCoreContractAddress.selector);
        new ERC1967Proxy(address(impl), data);
    }

    function testInitializeRevertsOnZeroFeeToken() public {
        FeeCollector impl = new FeeCollector();
        bytes memory data = abi.encodeWithSelector(
            FeeCollector.initialize.selector,
            owner,
            address(core),
            0.1e18,
            3600,
            address(0), // invalid token
            6
        );
        vm.expectRevert(FeeCollector.InvalidFeeTokenAddress.selector);
        new ERC1967Proxy(address(impl), data);
    }

    function testInitializeRevertsOnInvalidFeeReductionZero() public {
        FeeCollector impl = new FeeCollector();
        bytes memory data = abi.encodeWithSelector(
            FeeCollector.initialize.selector,
            owner,
            address(core),
            0, // invalid
            3600,
            address(maxbtc),
            6
        );
        vm.expectRevert(FeeCollector.InvalidFeeReductionPercentage.selector);
        new ERC1967Proxy(address(impl), data);
    }

    function testInitializeRevertsOnInvalidFeeReductionTooHigh() public {
        FeeCollector impl = new FeeCollector();
        bytes memory data = abi.encodeWithSelector(
            FeeCollector.initialize.selector,
            owner,
            address(core),
            ONE, // >= 1.0 invalid
            3600,
            address(maxbtc),
            6
        );
        vm.expectRevert(FeeCollector.InvalidFeeReductionPercentage.selector);
        new ERC1967Proxy(address(impl), data);
    }

    function testInitializeRevertsOnTooHighDecimals() public {
        FeeCollector impl = new FeeCollector();
        bytes memory data = abi.encodeWithSelector(
            FeeCollector.initialize.selector,
            owner,
            address(core),
            0.1e18,
            3600,
            address(maxbtc),
            19 // > 18 invalid
        );
        vm.expectRevert(FeeCollector.InvalidDecimalConversion.selector);
        new ERC1967Proxy(address(impl), data);
    }

    function testInitializeStoresConfigAndState() public view {
        FeeCollector.Config memory cfg = feeCollector.getConfig();
        FeeCollector.State memory st = feeCollector.getState();

        assertEq(cfg.coreContract, address(core), "coreContract mismatch");
        assertEq(
            cfg.feeApyReductionPercentage,
            0.1e18,
            "fee reduction mismatch"
        );
        assertEq(
            cfg.collectionPeriodSeconds,
            3600,
            "collection period mismatch"
        );
        assertEq(address(cfg.feeToken), address(maxbtc), "fee token mismatch");
        assertEq(cfg.maxbtcDecimals, 6, "decimals mismatch");

        (uint256 coreRate, uint64 coreTs) = core.getTwaer();
        assertEq(st.lastExchangeRate, coreRate, "lastExchangeRate mismatch");
        assertEq(
            st.lastCollectionTimestamp,
            coreTs,
            "lastCollectionTimestamp mismatch"
        );
    }

    // --------------------------------------
    // collectFee edge cases
    // --------------------------------------

    function testCollectFeeRevertsIfPeriodNotElapsed() public {
        vm.expectRevert(FeeCollector.CollectionPeriodNotElapsed.selector);
        feeCollector.collectFee();
    }

    function testCollectFeeRevertsIfApyNonPositive() public {
        vm.warp(block.timestamp + 4000);

        core.setRate(core.twaer());

        vm.expectRevert(
            abi.encodeWithSelector(
                FeeCollector.NegativeOrZeroApy.selector,
                core.twaer(),
                feeCollector.getState().lastExchangeRate
            )
        );
        feeCollector.collectFee();
    }

    function testCollectFeeNoMintWhenTotalSupplyZero() public {
        assertEq(maxbtc.totalSupply(), 0, "totalSupply should be zero");

        vm.warp(block.timestamp + 4000);

        core.setRate(core.twaer() + 0.1e18);

        uint256 prevMinted = core.lastMintedAmount();

        feeCollector.collectFee();

        assertEq(
            core.lastMintedAmount(),
            prevMinted,
            "no fee should be minted"
        );

        FeeCollector.State memory st = feeCollector.getState();
        console2.log("State after collectFee with zero supply:");
        console2.log("lastCollectionTimestamp:", st.lastCollectionTimestamp);
        console2.log("lastExchangeRate:", st.lastExchangeRate);
    }

    function testCollectFeeMintsAndUpdatesState() public {
        maxbtc.mint(address(0xCAFE), 1_000_000 * 10 ** 6);

        vm.warp(block.timestamp + 4000);

        uint256 oldRate = core.twaer();
        uint256 newRate = oldRate + 0.2e18;
        core.setRate(newRate);

        uint256 prevTotalSupply = maxbtc.totalSupply();
        uint256 prevCollectorBalance = maxbtc.balanceOf(address(feeCollector));

        feeCollector.collectFee();

        uint256 newTotalSupply = maxbtc.totalSupply();
        uint256 newCollectorBalance = maxbtc.balanceOf(address(feeCollector));
        uint256 minted = core.lastMintedAmount();

        console2.log("collectFee positive case:");
        console2.log("oldRate:", oldRate);
        console2.log("newRate:", newRate);
        console2.log("prevTotalSupply:", prevTotalSupply);
        console2.log("newTotalSupply:", newTotalSupply);
        console2.log("minted:", minted);
        console2.log(
            "collectorBalance delta:",
            newCollectorBalance - prevCollectorBalance
        );

        assertGt(minted, 0, "minted amount should be > 0");
        assertEq(
            newTotalSupply - prevTotalSupply,
            minted,
            "totalSupply increase mismatch"
        );
        assertEq(
            newCollectorBalance - prevCollectorBalance,
            minted,
            "collector balance mismatch"
        );

        FeeCollector.State memory st = feeCollector.getState();
        assertEq(
            st.lastExchangeRate,
            newRate,
            "state lastExchangeRate should be updated"
        );
        assertEq(
            st.lastCollectionTimestamp,
            uint64(block.timestamp),
            "timestamp should be updated"
        );
    }

    function testCollectFeeWhenFeeToMintZeroKeepsState() public {
        // No supply => _calculateFeeToMint returns 0 and state must not change
        FeeCollector.State memory beforeState = feeCollector.getState();

        vm.warp(block.timestamp + 4000);
        core.setRate(core.twaer() + 0.1e18);

        feeCollector.collectFee();

        FeeCollector.State memory afterState = feeCollector.getState();

        assertEq(
            afterState.lastCollectionTimestamp,
            beforeState.lastCollectionTimestamp,
            "timestamp must not change when nothing is minted"
        );
        assertEq(
            afterState.lastExchangeRate,
            beforeState.lastExchangeRate,
            "exchange rate must not change when nothing is minted"
        );
    }

    function testCollectFeeSecondCallBeforePeriodReverts() public {
        // First successful collect
        maxbtc.mint(address(0xCAFE), 1_000_000 * 10 ** 6);

        vm.warp(block.timestamp + 4000);
        uint256 oldRate = core.twaer();
        uint256 newRate = oldRate + 0.2e18;
        core.setRate(newRate);

        feeCollector.collectFee();

        // Try to collect again before collectionPeriodSeconds
        vm.warp(block.timestamp + 100);

        vm.expectRevert(FeeCollector.CollectionPeriodNotElapsed.selector);
        feeCollector.collectFee();
    }

    function testCollectFeeSecondCallAfterPeriodSucceeds() public {
        // First successful collect
        maxbtc.mint(address(0xCAFE), 1_000_000 * 10 ** 6);

        vm.warp(block.timestamp + 4000);
        uint256 rate1 = core.twaer();
        uint256 newRate1 = rate1 + 0.2e18;
        core.setRate(newRate1);
        feeCollector.collectFee();

        FeeCollector.State memory st1 = feeCollector.getState();
        uint256 minted1 = core.lastMintedAmount();
        assertGt(minted1, 0, "first collect must mint");

        // Wait longer than collectionPeriodSeconds and increase rate again
        vm.warp(block.timestamp + 3600);
        uint256 rate2 = core.twaer();
        uint256 newRate2 = rate2 + 0.3e18;
        core.setRate(newRate2);

        uint256 mintedBefore = core.lastMintedAmount();
        feeCollector.collectFee();

        FeeCollector.State memory st2 = feeCollector.getState();
        uint256 minted2 = core.lastMintedAmount();

        assertGt(
            minted2,
            mintedBefore,
            "second collect should mint additional fee"
        );
        assertGt(
            st2.lastCollectionTimestamp,
            st1.lastCollectionTimestamp,
            "lastCollectionTimestamp must increase on second collect"
        );
        assertEq(
            st2.lastExchangeRate,
            newRate2,
            "lastExchangeRate must be updated to latest rate"
        );
    }

    // --------------------------------------
    // claim() tests + access control
    // --------------------------------------

    function testClaimRevertsOnZeroAmount() public {
        vm.expectRevert(FeeCollector.InvalidZeroAmount.selector);
        feeCollector.claim(0, address(0xBEEF));
    }

    function testClaimRevertsOnZeroRecipient() public {
        vm.expectRevert(FeeCollector.InvalidOwnerAddress.selector);
        feeCollector.claim(1, address(0));
    }

    function testClaimTransfersFeeToRecipient() public {
        maxbtc.mint(address(feeCollector), 1000);

        uint256 prevCollector = maxbtc.balanceOf(address(feeCollector));
        uint256 prevRecipient = maxbtc.balanceOf(address(0xCAFE));

        feeCollector.claim(300, address(0xCAFE));

        uint256 newCollector = maxbtc.balanceOf(address(feeCollector));
        uint256 newRecipient = maxbtc.balanceOf(address(0xCAFE));

        console2.log("claim():");
        console2.log("collector before:", prevCollector);
        console2.log("collector after:", newCollector);
        console2.log("recipient before:", prevRecipient);
        console2.log("recipient after:", newRecipient);

        assertEq(
            prevCollector - newCollector,
            300,
            "collector balance decrease mismatch"
        );
        assertEq(
            newRecipient - prevRecipient,
            300,
            "recipient balance increase mismatch"
        );
    }

    function testClaimOnlyOwner() public {
        maxbtc.mint(address(feeCollector), 1000);

        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(
                OwnableUpgradeable.OwnableUnauthorizedAccount.selector,
                other
            )
        );
        feeCollector.claim(100, other);
    }

    // --------------------------------------
    // updateConfig() tests + access control
    // --------------------------------------

    function testUpdateConfigRevertsOnZeroCoreContract() public {
        vm.expectRevert(FeeCollector.InvalidCoreContractAddress.selector);
        feeCollector.updateConfig(address(0), 0.2e18, 7200);
    }

    function testUpdateConfigRevertsOnInvalidFeeReductionZero() public {
        vm.expectRevert(FeeCollector.InvalidFeeReductionPercentage.selector);
        feeCollector.updateConfig(address(core), 0, 7200);
    }

    function testUpdateConfigRevertsOnInvalidFeeReductionTooHigh() public {
        vm.expectRevert(FeeCollector.InvalidFeeReductionPercentage.selector);
        feeCollector.updateConfig(address(core), ONE, 7200);
    }

    function testUpdateConfigChangesConfigAndResetsState() public {
        MockCore newCore = new MockCore();
        newCore.setFeeToken(maxbtc, address(feeCollector));
        newCore.setRate(2e18);

        uint64 beforeTs = feeCollector.getState().lastCollectionTimestamp;

        feeCollector.updateConfig(address(newCore), 0.2e18, 10_000);

        FeeCollector.Config memory cfg = feeCollector.getConfig();
        FeeCollector.State memory st = feeCollector.getState();

        console2.log("updateConfig():");
        console2.log("new coreContract:", cfg.coreContract);
        console2.log(
            "new feeApyReductionPercentage:",
            cfg.feeApyReductionPercentage
        );
        console2.log(
            "new collectionPeriodSeconds:",
            cfg.collectionPeriodSeconds
        );
        console2.log("new lastExchangeRate:", st.lastExchangeRate);
        console2.log(
            "new lastCollectionTimestamp:",
            st.lastCollectionTimestamp
        );

        assertEq(
            cfg.coreContract,
            address(newCore),
            "coreContract not updated"
        );
        assertEq(
            cfg.feeApyReductionPercentage,
            0.2e18,
            "fee reduction not updated"
        );
        assertEq(cfg.collectionPeriodSeconds, 10_000, "period not updated");
        assertEq(
            st.lastExchangeRate,
            2e18,
            "state lastExchangeRate should be taken from new core"
        );
        assertTrue(
            st.lastCollectionTimestamp >= beforeTs,
            "timestamp should be moved forward"
        );
    }

    function testUpdateConfigOnlyOwner() public {
        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(
                OwnableUpgradeable.OwnableUnauthorizedAccount.selector,
                other
            )
        );
        feeCollector.updateConfig(address(core), 0.2e18, 7200);
    }

    // --------------------------------------
    // UUPS + proxy integration
    // --------------------------------------

    function testProxyReInitializationReverts() public {
        // We already used proxy + initialize in setUp.
        // Calling initialize again must revert with InvalidInitialization.
        vm.expectRevert(bytes("InvalidInitialization()"));
        feeCollector.initialize(
            owner,
            address(core),
            0.1e18,
            3600,
            address(maxbtc),
            6
        );
    }

    function testUUPSUpgradeOnlyOwner() public {
        FeeCollector impl = new FeeCollector();

        bytes memory data = abi.encodeWithSelector(
            FeeCollector.initialize.selector,
            owner,
            address(core),
            0.1e18,
            3600,
            address(maxbtc),
            6
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), data);
        FeeCollector proxied = FeeCollector(address(proxy));

        FeeCollectorV2 implV2 = new FeeCollectorV2();

        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(
                OwnableUpgradeable.OwnableUnauthorizedAccount.selector,
                other
            )
        );
        proxied.upgradeToAndCall(address(implV2), "");
    }

    function testUUPSUpgradeKeepsStateAndConfig() public {
        FeeCollector impl = new FeeCollector();

        bytes memory data = abi.encodeWithSelector(
            FeeCollector.initialize.selector,
            owner,
            address(core),
            0.1e18,
            3600,
            address(maxbtc),
            6
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), data);
        FeeCollector proxied = FeeCollector(address(proxy));

        FeeCollector.Config memory cfgBefore = proxied.getConfig();
        FeeCollector.State memory stBefore = proxied.getState();

        FeeCollectorV2 implV2 = new FeeCollectorV2();
        proxied.upgradeToAndCall(address(implV2), "");

        FeeCollectorV2 proxiedV2 = FeeCollectorV2(address(proxy));
        string memory ver = proxiedV2.version();
        assertEq(ver, "v2", "version should be v2 after upgrade");

        FeeCollector.Config memory cfgAfter = proxiedV2.getConfig();
        FeeCollector.State memory stAfter = proxiedV2.getState();

        assertEq(
            cfgAfter.coreContract,
            cfgBefore.coreContract,
            "coreContract must be preserved"
        );
        assertEq(
            cfgAfter.feeApyReductionPercentage,
            cfgBefore.feeApyReductionPercentage,
            "fee reduction must be preserved"
        );
        assertEq(
            cfgAfter.collectionPeriodSeconds,
            cfgBefore.collectionPeriodSeconds,
            "period must be preserved"
        );
        assertEq(
            address(cfgAfter.feeToken),
            address(cfgBefore.feeToken),
            "fee token must be preserved"
        );
        assertEq(
            cfgAfter.maxbtcDecimals,
            cfgBefore.maxbtcDecimals,
            "decimals must be preserved"
        );

        assertEq(
            stAfter.lastExchangeRate,
            stBefore.lastExchangeRate,
            "lastExchangeRate must be preserved"
        );
        assertEq(
            stAfter.lastCollectionTimestamp,
            stBefore.lastCollectionTimestamp,
            "lastCollectionTimestamp must be preserved"
        );
    }
}
