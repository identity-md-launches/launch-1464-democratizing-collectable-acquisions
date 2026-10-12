// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DCAToken} from "src/DCAToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract DCATokenEdgesTest is Test {
    DCAToken private token;
    address private alice;
    address private bob;
    address private spender;
    uint256 private constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        token = new DCAToken();
        alice = makeAddr("edge Alice");
        bob = makeAddr("edge Bob");
        spender = makeAddr("edge spender");
    }

    function test_ZeroTransfersFromEmptyWalletEmitEventsWithoutApprovalOrTax() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, bob, 0);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, bob, 0);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 0));
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_WholeSupplyTransferFromSelfConsumesAllowanceWithoutChangingBalance() public {
        token.transfer(alice, SUPPLY);
        vm.prank(alice);
        token.approve(spender, SUPPLY);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, alice, SUPPLY));
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.allowance(alice, spender), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1);
        vm.prank(alice);
        assertTrue(token.transfer(bob, SUPPLY));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_ApprovalReplacementRevocationAndReapprovalAreEffectiveImmediately() public {
        token.transfer(alice, 2);
        vm.prank(alice);
        token.approve(spender, type(uint256).max);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Approval(alice, spender, 1);
        vm.prank(alice);
        token.approve(spender, 1);
        assertEq(token.allowance(alice, spender), 1);
        vm.prank(alice);
        token.approve(spender, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1);
        vm.prank(alice);
        token.approve(spender, 2);
        vm.prank(spender);
        token.transferFrom(alice, bob, 2);
        assertEq(token.balanceOf(bob), 2);
        assertEq(token.allowance(alice, spender), 0);
    }

    function test_Uint256MaxTransfersFailWithoutChangingBalancesOrInfiniteAllowance() public {
        token.transfer(alice, SUPPLY);
        vm.prank(alice);
        token.approve(spender, type(uint256).max);
        bytes memory reason =
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, SUPPLY, type(uint256).max);
        vm.expectRevert(reason);
        vm.prank(alice);
        token.transfer(bob, type(uint256).max);
        vm.expectRevert(reason);
        vm.prank(spender);
        token.transferFrom(alice, bob, type(uint256).max);
        assertEq(token.allowance(alice, spender), type(uint256).max);
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_ZeroAddressesCannotBeApprovedOrUsedAsMintBurnPathsEvenForZeroAmount() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
        // OpenZeppelin rejects the zero owner while updating its allowance, before transfer validation.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.transferFrom(address(0), alice, 0);
        assertEq(token.allowance(address(this), address(0)), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
