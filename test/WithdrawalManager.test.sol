// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {WithdrawalManager, ICoreContract} from "../src/WithdrawalManager.sol";
import {WithdrawalToken} from "../src/WithdrawalToken.sol";
import {Batch} from "../src/types/CoreTypes.sol";

contract MockWBTC {
    string public name;
    string public symbol;

    uint8 public constant decimals = 8;

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

contract MockCore is ICoreContract {
    mapping(uint256 => Batch) internal _batches;

    function setCollectedAmount(uint256 batchId, uint256 amount) external {
        _batches[batchId].collectedAmount = amount;
    }

    function finalizedBatch(
        uint256 batchId
    ) external view override returns (Batch memory) {
        return _batches[batchId];
    }
}

// пример новой реализации для теста UUPS-апгрейда
contract WithdrawalManagerV2 is WithdrawalManager {
    function version() external pure returns (uint256) {
        return 2;
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
        // деплой WBTC
        wbtc = new MockWBTC("Wrapped BTC", "WBTC");

        // деплой Core (mock)
        core = new MockCore();
        // для удобства используем простое значение
        uint256 collectedAmount = 1_000_000_000; // 10 WBTC, если 8 знаков
        core.setCollectedAmount(BATCH_ID, collectedAmount);

        // деплой WithdrawalToken через UUPS proxy
        WithdrawalToken tokenImpl = new WithdrawalToken();
        bytes memory tokenInitData = abi.encodeCall(
            WithdrawalToken.initialize,
            (owner, "https://api.example.com/", "WithdrawalToken")
        );
        ERC1967Proxy tokenProxy = new ERC1967Proxy(
            address(tokenImpl),
            tokenInitData
        );
        token = WithdrawalToken(address(tokenProxy));

        // деплой WithdrawalManager через UUPS proxy
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

        // пополнить WithdrawalManager WBTC для выплат
        wbtc.mint(address(manager), collectedAmount);

        // заминтить пользователю 1 токен реденшена в батче BATCH_ID
        vm.prank(owner);
        token.mint(user, BATCH_ID, 1, "");
    }

    function testConfigInitialized() public view {
        WithdrawalManager.WithdrawalManagerConfig memory config = manager
            .getConfig();
        assertEq(config.coreContract, address(core));
        assertEq(config.wbtcContract, address(wbtc));
        assertEq(config.withdrawalTokenContract, address(token));
        assertEq(manager.owner(), owner);
    }

    function testOnERC1155ReceivedRedeemsAndBurns() public {
        uint256 managerBalanceBefore = wbtc.balanceOf(address(manager));
        uint256 userBalanceBefore = wbtc.balanceOf(user);
        uint256 paidBefore = manager.getPaidAmount(BATCH_ID);

        assertEq(managerBalanceBefore, 1_000_000_000);
        assertEq(userBalanceBefore, 0);
        assertEq(paidBefore, 0);

        // перевод 1 токена реденшена на WithdrawalManager
        vm.prank(user);
        token.safeTransferFrom(user, address(manager), BATCH_ID, 1, "");

        uint256 managerBalanceAfter = wbtc.balanceOf(address(manager));
        uint256 userBalanceAfter = wbtc.balanceOf(user);
        uint256 paidAfter = manager.getPaidAmount(BATCH_ID);

        // вся сумма из батча должна быть выплачена пользователю
        assertEq(userBalanceAfter, 1_000_000_000);
        assertEq(managerBalanceAfter, managerBalanceBefore - 1_000_000_000);
        assertEq(paidAfter, 1_000_000_000);

        // токены реденшена пользователя сожжены
        assertEq(token.balanceOf(user, BATCH_ID), 0);
        assertEq(token.totalSupply(BATCH_ID), 0);
    }

    function testOnERC1155ReceivedRevertsWhenPaused() public {
        // поставить паузу
        vm.prank(owner);
        manager.setPause(true);
        assertTrue(manager.paused());

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(WithdrawalManager.ContractPaused.selector)
        );
        token.safeTransferFrom(user, address(manager), BATCH_ID, 1, "");
    }

    function testOnERC1155ReceivedRevertsForInvalidToken() public {
        // прямой вызов без участия WithdrawalToken
        vm.expectRevert(
            abi.encodeWithSelector(
                WithdrawalManager.InvalidWithdrawalToken.selector
            )
        );
        manager.onERC1155Received(address(this), user, BATCH_ID, 1, "");
    }

    function testOnERC1155ReceivedRevertsWhenRedemptionSupplyIsZero() public {
        uint256 emptyBatchId = 42;
        core.setCollectedAmount(emptyBatchId, 1_000_000);

        // имитируем вызов от контракта WithdrawalToken, но без предварительного mint
        vm.prank(address(token));
        vm.expectRevert(
            abi.encodeWithSelector(
                WithdrawalManager.RedemptionTokenSupplyIsZero.selector
            )
        );
        manager.onERC1155Received(address(this), user, emptyBatchId, 1, "");
    }

    function testOnERC1155BatchReceivedReverts() public {
        uint256[] memory ids;
        uint256[] memory amounts;

        ids[0] = BATCH_ID;
        amounts[0] = 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                WithdrawalManager.BatchSupportNotEnabled.selector
            )
        );
        manager.onERC1155BatchReceived(address(this), user, ids, amounts, "");
    }

    function testUpdateConfigByOwner() public {
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
        vm.expectRevert(
            abi.encodeWithSignature(
                "OwnableUnauthorizedAccount(address)",
                address(this)
            )
        );
        manager.updateConfig(address(1), address(2), address(3));
    }

    function testUpdateConfigRevertsForZeroAddresses() public {
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
        vm.prank(owner);
        vm.expectEmit();
        emit WithdrawalManager.Paused();
        manager.setPause(true);
        assertTrue(manager.paused());

        vm.prank(owner);
        vm.expectEmit();
        emit WithdrawalManager.Unpaused();
        manager.setPause(false);
        assertFalse(manager.paused());
    }

    function testUpgradeToV2ByOwner() public {
        WithdrawalManagerV2 implV2 = new WithdrawalManagerV2();

        vm.prank(owner);
        manager.upgradeToAndCall(address(implV2), "");

        uint256 v = WithdrawalManagerV2(address(manager)).version();
        assertEq(v, 2);

        // конфиг после апгрейда должен сохраниться
        WithdrawalManager.WithdrawalManagerConfig memory config = manager
            .getConfig();
        assertEq(config.coreContract, address(core));
        assertEq(config.wbtcContract, address(wbtc));
        assertEq(config.withdrawalTokenContract, address(token));
    }

    function testUpgradeToV2RevertsForNonOwner() public {
        WithdrawalManagerV2 implV2 = new WithdrawalManagerV2();

        vm.expectRevert(
            abi.encodeWithSignature(
                "OwnableUnauthorizedAccount(address)",
                address(this)
            )
        );
        manager.upgradeToAndCall(address(implV2), "");
    }
}
