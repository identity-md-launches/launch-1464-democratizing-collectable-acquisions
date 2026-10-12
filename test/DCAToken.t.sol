// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DCAToken} from "../src/DCAToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract TokenFactoryProbe {
    function deploy() external returns (DCAToken) {
        return new DCAToken();
    }

    function move(DCAToken token, address to, uint256 amount) external {
        token.transfer(to, amount);
    }
}

contract DCATokenTest is Test {
    DCAToken internal token;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal spender = makeAddr("spender");

    function setUp() public {
        token = new DCAToken();
    }

    function test_MetadataAndEntireSupplyMintedOnce() public view {
        assertEq(token.name(), "Democratizing Collectable Acquisions");
        assertEq(token.symbol(), "DCA");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
    }

    function test_FactoryReceivesSupplyAndLaunchAllocationsArriveWhole() public {
        TokenFactoryProbe factory = new TokenFactoryProbe();
        DCAToken launched = factory.deploy();
        address distributor = makeAddr("distributor");
        address manager = makeAddr("manager");
        address remainder = makeAddr("remainder");
        uint256 supply = launched.totalSupply();
        assertEq(launched.balanceOf(address(factory)), supply);
        factory.move(launched, distributor, supply / 10);
        factory.move(launched, manager, supply * 88 / 100);
        factory.move(launched, remainder, supply * 2 / 100);
        assertEq(launched.balanceOf(address(factory)), 0);
        assertEq(launched.balanceOf(distributor), supply / 10);
        assertEq(launched.balanceOf(manager), supply * 88 / 100);
        assertEq(launched.balanceOf(remainder), supply * 2 / 100);
        vm.prank(distributor);
        launched.transfer(alice, supply / 10);
        assertEq(launched.balanceOf(alice), supply / 10);
    }

    function testFuzz_WalletTransfersAreUntaxed(uint256 amount) public {
        amount = bound(amount, 0, token.totalSupply());
        token.transfer(alice, amount);
        vm.prank(alice);
        assertTrue(token.transfer(bob, amount));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function test_ApprovalTransferFromAndInfiniteApproval() public {
        token.transfer(alice, 100 ether);
        vm.prank(alice);
        token.approve(spender, 40 ether);
        vm.prank(spender);
        token.transferFrom(alice, bob, 30 ether);
        assertEq(token.allowance(alice, spender), 10 ether);
        assertEq(token.balanceOf(bob), 30 ether);
        vm.prank(alice);
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        token.transferFrom(alice, bob, 70 ether);
        assertEq(token.allowance(alice, spender), type(uint256).max);
        assertEq(token.balanceOf(bob), 100 ether);
    }

    function test_InsufficientBalanceAndAllowanceRevert() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transfer(bob, 1);
        token.transfer(alice, 10 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(alice, bob, 1);
        assertEq(token.balanceOf(alice), 10 ether);
    }

    function test_ZeroRecipientRevertsAndSelfTransferPreservesBalance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        token.transfer(address(this), 10 ether);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
    }

    function test_NoMintPauseBlacklistSeizeOrUpgradePowers() public {
        token.transfer(alice, 100 ether);
        string[10] memory signatures = [
            "mint(address,uint256)",
            "issue(uint256)",
            "pause()",
            "blacklist(address)",
            "freeze(address)",
            "burnFrom(address,uint256)",
            "seize(address)",
            "upgradeTo(address)",
            "transferOwnership(address)",
            "initialize(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, 1 ether));
            assertFalse(ok, signatures[i]);
            vm.prank(bob);
            (ok,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, 1 ether));
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.balanceOf(alice), 100 ether);
        vm.prank(alice);
        token.transfer(bob, 100 ether);
        assertEq(token.balanceOf(bob), 100 ether);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }
}
