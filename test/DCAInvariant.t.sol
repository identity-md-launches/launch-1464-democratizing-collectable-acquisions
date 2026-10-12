// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HookTestBase} from "./helpers/HookTestBase.sol";
import {DCAHook} from "../src/DCAHook.sol";
import {PoolRouter} from "./helpers/PoolRouter.sol";
import {RestrictedFWA} from "./helpers/RestrictedFWA.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

contract FeeHandler is Test {
    DCAHook public immutable hook;
    PoolRouter public immutable router;
    PoolKey private key;
    uint256 public totalAccrued;
    uint256 public totalClaimed;
    uint256 public swapCount;

    constructor(DCAHook hook_, PoolRouter router_) {
        hook = hook_;
        router = router_;
        key = hook_.getPoolKey();
    }

    function swap(bool buy, bool exactInput, uint256 amount) external {
        amount = bound(amount, 20, 100 ether);
        bool fwa0 = Currency.unwrap(key.currency0) == hook.FWA();
        bool zeroForOne = buy == fwa0;
        uint256 pendingBefore = hook.pendingFees();
        BalanceDelta delta = router.swap(
            key,
            SwapParams(
                zeroForOne,
                exactInput ? -int256(amount) : int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            )
        );
        int256 fwaDelta = fwa0 ? int256(delta.amount0()) : int256(delta.amount1());
        uint256 collected = hook.pendingFees() - pendingBefore;
        uint256 gross = buy ? uint256(-fwaDelta) : uint256(fwaDelta) + collected;
        assertEq(collected, gross / 20);
        totalAccrued += collected;
        swapCount++;
    }

    function claim() external {
        uint256 expected = hook.pendingFees();
        uint256 paid = hook.claimFees();
        assertEq(paid, expected);
        totalClaimed += paid;
    }
}

abstract contract DCAInvariantBase is HookTestBase {
    FeeHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new FeeHandler(hook, router);
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = FeeHandler.swap.selector;
        selectors[1] = FeeHandler.claim.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_FeeClaimsPlusPayoutsEqualAllAccruedFees() public view {
        assertEq(hook.pendingFees() + handler.totalClaimed(), handler.totalAccrued());
        assertEq(fwa.balanceOf(RECIPIENT), handler.totalClaimed());
        assertGe(fwa.balanceOf(address(manager)), hook.pendingFees());
        assertEq(fwa.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(hook)), 0);
    }

    function invariant_ConservationOfBothTokensAndFixedSupply() public view {
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(
            token.balanceOf(address(this)) + token.balanceOf(address(router)) + token.balanceOf(address(controlRouter))
                + token.balanceOf(address(manager)),
            token.totalSupply()
        );
        assertEq(
            fwa.balanceOf(address(router)) + fwa.balanceOf(address(controlRouter)) + fwa.balanceOf(address(manager))
                + fwa.balanceOf(RECIPIENT),
            fwa.totalSupply()
        );
    }

    function invariant_TransientAccountingAlwaysSettled() public view {
        IPoolManager pm = IPoolManager(address(manager));
        assertEq(TransientStateLibrary.getNonzeroDeltaCount(pm), 0);
        assertEq(TransientStateLibrary.currencyDelta(pm, address(hook), Currency.wrap(FWA)), 0);
        assertFalse(TransientStateLibrary.isUnlocked(pm));
    }
}

contract DCAInvariantFwa0Test is DCAInvariantBase {
    function _fwaFirst() internal pure override returns (bool) {
        return true;
    }
}

contract DCAInvariantFwa1Test is DCAInvariantBase {
    function _fwaFirst() internal pure override returns (bool) {
        return false;
    }
}
