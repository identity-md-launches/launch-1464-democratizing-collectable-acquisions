// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DCAToken} from "src/DCAToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @dev The model is updated from requested operations, never copied from token balances.
contract DCALedgerHandler is Test {
    DCAToken public immutable token;
    address[4] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    constructor(DCAToken token_, address[4] memory actors_) {
        token = token_;
        actors = actors_;
        expectedBalance[actors_[0]] = 1_000_000_000 ether;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) public {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        amount = bound(amount, 0, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool unlimited) public {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        amount = unlimited ? type(uint256).max : bound(amount, 0, 1_000_000_000 ether);
        _approve(owner, spender, amount);
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) public {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 allowed = expectedAllowance[owner][spender];
        uint256 available = expectedBalance[owner] < allowed ? expectedBalance[owner] : allowed;
        amount = bound(amount, 0, available);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        if (allowed != type(uint256).max) expectedAllowance[owner][spender] -= amount;
        expectedBalance[owner] -= amount;
        expectedBalance[to] += amount;
    }

    function overdraw(uint256 ownerSeed, uint256 toSeed) public {
        address owner = actors[ownerSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 held = expectedBalance[owner];
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, held, held + 1));
        vm.prank(owner);
        token.transfer(to, held + 1);
    }

    function overspendAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) public {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        amount = bound(amount, 0, expectedBalance[owner]);
        _approve(owner, spender, amount);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, amount, amount + 1)
        );
        vm.prank(spender);
        token.transferFrom(owner, actors[(ownerSeed % actors.length + 1) % actors.length], amount + 1);
    }

    /// @dev Failure occurs AFTER allowance accounting; the allowance must roll back too.
    function overdrawWithApproval(uint256 ownerSeed, uint256 spenderSeed) public {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        uint256 held = expectedBalance[owner];
        _approve(owner, spender, held + 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, held, held + 1));
        vm.prank(spender);
        token.transferFrom(owner, spender, held + 1);
    }

    function invalidReceiver(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) public {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        amount = bound(amount, 0, expectedBalance[owner]);
        _approve(owner, spender, amount);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(owner, address(0), amount);
    }

    function _approve(address owner, address spender, uint256 amount) private {
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract DCATokenStatefulTest is Test {
    DCAToken internal token;
    DCALedgerHandler internal handler;
    address[4] internal actors;

    function setUp() public {
        token = new DCAToken();
        actors =
            [makeAddr("ledger deployer"), makeAddr("ledger Alice"), makeAddr("ledger Bob"), makeAddr("ledger Carol")];
        token.transfer(actors[0], 1_000_000_000 ether);
        handler = new DCALedgerHandler(token, actors);
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.overdraw.selector;
        selectors[4] = handler.overspendAllowance.selector;
        selectors[5] = handler.overdrawWithApproval.selector;
        selectors[6] = handler.invalidReceiver.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_BalancesMatchIndependentLedgerAndEntireSupply() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            uint256 held = token.balanceOf(actors[i]);
            assertEq(held, handler.expectedBalance(actors[i]), "untaxed ledger mismatch");
            sum += held;
        }
        assertEq(sum, 1_000_000_000 ether);
        assertEq(token.totalSupply(), sum);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function invariant_AllowancesMatchApprovalsAndSuccessfulSpendsOnly() public view {
        for (uint256 i; i < actors.length; ++i) {
            for (uint256 j; j < actors.length; ++j) {
                assertEq(token.allowance(actors[i], actors[j]), handler.expectedAllowance(actors[i], actors[j]));
            }
        }
    }

    /// @dev Everyone can still move their FULL balance after an arbitrary history of failed/successful calls.
    function afterInvariant() public {
        for (uint256 i = 1; i < actors.length; ++i) {
            handler.transfer(i, 0, handler.expectedBalance(actors[i]));
        }
        invariant_BalancesMatchIndependentLedgerAndEntireSupply();
        invariant_AllowancesMatchApprovalsAndSuccessfulSpendsOnly();
        assertEq(token.balanceOf(actors[0]), 1_000_000_000 ether);
    }

    function test_LedgerExercisesFullSupplySelfTransfersAndFailureRecovery() public {
        handler.transfer(0, 1, 1_000_000_000 ether);
        handler.transfer(1, 1, 1_000_000_000 ether);
        handler.overdraw(1, 2);
        handler.approve(1, 2, 0, true);
        handler.transferFrom(1, 2, 3, 1_000_000_000 ether);
        handler.overdrawWithApproval(3, 2);
        handler.invalidReceiver(3, 2, 1);
        handler.overspendAllowance(3, 2, 1);
        handler.approve(3, 2, 0, false);
        handler.transferFrom(3, 2, 0, 0);
        afterInvariant();
    }
}
