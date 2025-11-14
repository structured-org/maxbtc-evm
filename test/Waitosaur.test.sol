// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {Test} from "forge-std/Test.sol";
import "../src/Waitosaur.sol" as waitosaurSrc;
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MockERC20 {
    string public name = "MockToken";
    string public symbol = "MTK";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address user => uint256 amount) public balanceOf;
    mapping(address owner => mapping(address spender => uint256 amount))
        public allowance;

    error InsufficientBalance();
    error InsufficientAllowance();

    function burn(address from, uint256 amount) external {
        if (balanceOf[from] < amount) revert InsufficientBalance();
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        if (balanceOf[msg.sender] < amount) revert InsufficientBalance();
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        if (balanceOf[from] < amount) revert InsufficientBalance();
        if (allowance[from][msg.sender] < amount)
            revert InsufficientAllowance();
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        return true;
    }
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

contract WaitosaurTest is Test {
    function testUnlockFailsIfLowBalance() public {
        vm.prank(locker);
        waitosaur.lock(100 ether);
        // Burn funds from contract to simulate low balance
        token.burn(address(waitosaur), 1000 ether);
        vm.prank(unLocker);
        vm.expectRevert(
            abi.encodeWithSelector(
                waitosaurSrc.Waitosaur.InsufficientBalance.selector
            )
        );
        waitosaur.unlock();
    }
    // (Removed duplicate state variables and test functions)

    waitosaurSrc.Waitosaur public waitosaur;
    MockERC20 public token;
    address public owner = address(0x1);
    address public locker = address(0x2);
    address public unLocker = address(0x3);
    address public receiver = address(0x4);
    address public user = address(0x5);

    function setUp() public {
        token = new MockERC20();
        // Deploy logic contract
        waitosaurSrc.Waitosaur logic = new waitosaurSrc.Waitosaur();
        // Prepare initializer data
        bytes memory data = abi.encodeWithSelector(
            waitosaurSrc.Waitosaur.initialize.selector,
            owner,
            address(token),
            locker,
            unLocker,
            receiver
        );
        // Deploy proxy with initializer
        ERC1967Proxy proxy = new ERC1967Proxy(address(logic), data);
        waitosaur = waitosaurSrc.Waitosaur(address(proxy));
        token.mint(address(waitosaur), 1000 ether);
    }

    function testLockAndUnlockTransfersToReceiver() public {
        vm.prank(locker);
        waitosaur.lock(100 ether);
        assertEq(token.balanceOf(address(waitosaur)), 1000 ether);
        assertEq(token.balanceOf(receiver), 0);
        assertEq(waitosaur.unlocked(), false);

        vm.prank(unLocker);
        waitosaur.unlock();
        assertEq(token.balanceOf(receiver), 100 ether);
        assertEq(token.balanceOf(address(waitosaur)), 900 ether);
    }

    function testUpdateReceiver() public {
        address newReceiver = address(0x6);
        vm.prank(owner);
        waitosaur.updateReceiver(newReceiver);
        assertEq(waitosaur.receiver(), newReceiver);
    }
}
