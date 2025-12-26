// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Allowlist, IZkMe} from "../src/Allowlist.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract MockZkMe is IZkMe {
    mapping(address => bool) public approved;
    address public cooperator;

    function setCooperator(address _cooperator) external {
        cooperator = _cooperator;
    }

    function setApproved(address _approved) external {
        approved[_approved] = true;
    }

    function hasApproved(
        address _cooperator,
        address user
    ) external view returns (bool) {
        return _cooperator == cooperator && approved[user];
    }
}

contract AllowlistTest is Test {
    Allowlist private allowlist;
    MockZkMe private zkme;
    address private constant OWNER = address(0xABCD);
    address private constant USER = address(0xBEEF);
    address private constant OTHER = address(0xCAFE);

    function setUp() external {
        Allowlist impl = new Allowlist();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(Allowlist.initialize, (OWNER))
        );
        allowlist = Allowlist(address(proxy));
        zkme = new MockZkMe();
        zkme.setCooperator(OTHER);
    }

    function testAllowAndDeny() external {
        assertFalse(Allowlist(address(allowlist)).isAddressAllowed(USER));
        assertFalse(Allowlist(address(allowlist)).isAddressAllowed(OTHER));

        vm.prank(OWNER);
        allowlist.allow(_arr(USER, OTHER));
        assertTrue(Allowlist(address(allowlist)).isAddressAllowed(USER));
        assertTrue(Allowlist(address(allowlist)).isAddressAllowed(OTHER));

        vm.prank(OWNER);
        allowlist.deny(_arr(USER));
        assertFalse(Allowlist(address(allowlist)).isAddressAllowed(USER));
        assertTrue(Allowlist(address(allowlist)).isAddressAllowed(OTHER));
    }

    function testZkMeFallback() external {
        vm.prank(OWNER);
        allowlist.setZkMeSettings(address(zkme), OTHER);
        assertFalse(Allowlist(address(allowlist)).isAddressAllowed(USER));
        zkme.setApproved(USER);
        assertTrue(Allowlist(address(allowlist)).isAddressAllowed(USER));

        vm.prank(OWNER);
        // Remove zkMe settings from allowlist
        allowlist.setZkMeSettings(address(0), address(0));
        assertFalse(Allowlist(address(allowlist)).isAddressAllowed(USER));
    }

    function testOnlyOwnerGuards() external {
        address attacker = USER;
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                OwnableUpgradeable.OwnableUnauthorizedAccount.selector,
                attacker
            )
        );
        allowlist.allow(_arr(USER));

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                OwnableUpgradeable.OwnableUnauthorizedAccount.selector,
                attacker
            )
        );
        allowlist.deny(_arr(USER));

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                OwnableUpgradeable.OwnableUnauthorizedAccount.selector,
                attacker
            )
        );
        allowlist.setZkMeSettings(address(zkme), OTHER);
    }

    function testInvalidAddressReverts() external {
        vm.prank(OWNER);
        vm.expectRevert(Allowlist.ZeroAddressNotAllowed.selector);
        allowlist.allow(_arr(address(0)));

        vm.prank(OWNER);
        vm.expectRevert(Allowlist.ZeroAddressNotAllowed.selector);
        allowlist.setZkMeSettings(address(zkme), address(0));
    }

    function testTwoStepOwnershipTransfer() external {
        address newOwner = address(0x1234);
        vm.prank(OWNER);
        allowlist.transferOwnership(newOwner);
        assertEq(
            allowlist.pendingOwner(),
            newOwner,
            "pending owner was not set properly"
        );

        vm.prank(newOwner);
        allowlist.acceptOwnership();
        assertEq(allowlist.owner(), newOwner, "ownership was not transferred");
        assertEq(
            allowlist.pendingOwner(),
            address(0),
            "pending owner was not cleared"
        );
    }

    function _arr(address a) private pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _arr(
        address a,
        address b
    ) private pure returns (address[] memory arr) {
        arr = new address[](2);
        arr[0] = a;
        arr[1] = b;
    }
}
