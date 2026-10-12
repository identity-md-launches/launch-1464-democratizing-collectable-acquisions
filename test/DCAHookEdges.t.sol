// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookTestBase} from "./helpers/HookTestBase.sol";
import {DCAHook} from "src/DCAHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

abstract contract DCAHookEdgesBase is HookTestBase {
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    uint256 private constant CAP = uint256(uint128(type(int128).max));

    function test_FeeRoundingPinnedBoundaries() public view {
        uint256[10] memory gross = [uint256(0), 1, 18, 19, 20, 21, 38, 39, 40, 41];
        uint256[10] memory expected = [uint256(0), 0, 0, 0, 1, 1, 1, 1, 2, 2];
        for (uint256 i; i < gross.length; ++i) {
            assertEq(hook.feeOnGross(gross[i]), expected[i]);
        }
        assertEq(hook.feeOnNet(0), 0);
        assertEq(hook.feeOnNet(1), 0);
        assertEq(hook.feeOnNet(19), 0);
        assertEq(hook.feeOnNet(20), 1);
        assertEq(hook.feeOnNet(38), 1);
        assertEq(hook.feeOnNet(39), 2);
        assertEq(hook.feeOnNet(40), 2);
    }

    function testFuzz_GrossFeeHasBoundedRemainderOverEntireUint256Domain(uint256 gross) public view {
        uint256 fee = hook.feeOnGross(gross);
        // No gross*500 intermediate: this property remains meaningful at uint256.max.
        assertLe(fee, type(uint256).max / 20);
        assertLe(fee * 20, gross);
        assertLt(gross - fee * 20, 20);
    }

    function testFuzz_NetInversionIsExactAndMinimalThroughSignedBoundary(uint256 net) public view {
        net = bound(net, 1, CAP - CAP / 20);
        uint256 fee = hook.feeOnNet(net);
        uint256 gross = net + fee;
        assertLe(gross, CAP);
        assertEq(gross - hook.feeOnGross(gross), net);
        assertLt(gross - 1 - hook.feeOnGross(gross - 1), net);
    }

    function test_LargestRepresentableNetAcceptedAndNextWeiRejected() public {
        uint256 maxNet = CAP - CAP / 20;
        assertEq(maxNet + hook.feeOnNet(maxNet), CAP);
        vm.expectRevert(DCAHook.InvalidAmount.selector);
        hook.feeOnNet(maxNet + 1);
        vm.expectRevert(DCAHook.InvalidAmount.selector);
        hook.feeOnNet(CAP + 1);
        assertEq(hook.feeOnGross(type(uint256).max), type(uint256).max / 20);
    }

    function test_BeforeSwapAcceptsSignedEdgesWithoutNarrowingOrPoolFeeOverride() public {
        SwapParams memory buy = _params(true, -int256(CAP));
        vm.prank(address(manager));
        (bytes4 selector, BeforeSwapDelta delta, uint24 feeOverride) = hook.beforeSwap(address(router), key, buy, "");
        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(int256(delta.getSpecifiedDelta()), int256(CAP / 20));
        assertEq(delta.getUnspecifiedDelta(), 0);
        assertEq(feeOverride, 0);

        uint256 net = CAP - CAP / 20;
        SwapParams memory sell = _params(false, int256(net));
        vm.prank(address(manager));
        (, delta, feeOverride) = hook.beforeSwap(address(router), key, sell, "");
        assertEq(int256(delta.getSpecifiedDelta()) + int256(net), int256(CAP));
        assertEq(feeOverride, 0);
    }

    function test_AllInvalidAmountEdgesRejectedByBothCallbacks() public {
        int256[7] memory amounts = [
            int256(0),
            -int256(CAP) - 1,
            int256(CAP) + 1,
            type(int256).min,
            type(int256).min + 1,
            type(int256).max - 1,
            type(int256).max
        ];
        for (uint256 i; i < amounts.length; ++i) {
            for (uint256 direction; direction < 2; ++direction) {
                SwapParams memory params = _params(direction == 0, amounts[i]);
                vm.expectRevert(DCAHook.InvalidAmount.selector);
                vm.prank(address(manager));
                hook.beforeSwap(address(router), key, params, "");
                vm.expectRevert(DCAHook.InvalidAmount.selector);
                vm.prank(address(manager));
                hook.afterSwap(address(router), key, params, BalanceDelta.wrap(0), "");
            }
        }
        assertEq(hook.pendingFees(), 0);
    }

    function test_AfterSwapRejectsWrongFwaSignsForAllFourModes() public {
        for (uint256 mode; mode < 4; ++mode) {
            bool buy = mode < 2;
            bool exactInput = mode % 2 == 0;
            SwapParams memory params = _params(buy, exactInput ? -int256(100) : int256(100));
            int128 wrongFwa = buy ? int128(1) : int128(-1);
            BalanceDelta delta =
                Currency.unwrap(key.currency0) == FWA ? toBalanceDelta(wrongFwa, 0) : toBalanceDelta(0, wrongFwa);
            vm.expectRevert(DCAHook.UnexpectedDelta.selector);
            vm.prank(address(manager));
            hook.afterSwap(address(router), key, params, delta, "");
        }
        assertEq(hook.pendingFees(), 0);
    }

    function testFuzz_SenderAndHookDataCannotChangeFixedBuyFee(address sender, bytes calldata hookData) public {
        SwapParams memory params = _params(true, -100 ether);
        vm.prank(address(manager));
        (bytes4 selector, BeforeSwapDelta delta, uint24 feeOverride) = hook.beforeSwap(sender, key, params, hookData);
        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(delta.getSpecifiedDelta(), 5 ether);
        assertEq(delta.getUnspecifiedDelta(), 0);
        assertEq(feeOverride, 0);
        assertEq(hook.pendingFees(), 0, "beforeSwap alone cannot create a claim");
    }

    function test_FailedSecondSwapRollsBackFirstSwapAndItsFees() public {
        uint256 beforeFwa = fwa.balanceOf(address(router));
        uint256 beforeDca = token.balanceOf(address(router));
        uint256 reserveFwa = fwa.balanceOf(address(manager));
        uint256 reserveDca = token.balanceOf(address(manager));
        SwapParams memory sell = _params(false, 100 ether);
        // Reverse almost to the original price after buying with 95 FWA. It cannot output 100 FWA.
        sell.sqrtPriceLimitX96 = sell.zeroForOne ? Q96 + 1 : Q96 - 1;
        SwapParams memory buy = _params(true, -100 ether);
        _expectHookError(IHooks.afterSwap.selector, DCAHook.PartialFill.selector);
        router.batchSwap(key, buy, sell);
        assertEq(hook.pendingFees(), 0);
        assertEq(fwa.balanceOf(address(router)), beforeFwa);
        assertEq(token.balanceOf(address(router)), beforeDca);
        assertEq(fwa.balanceOf(address(manager)), reserveFwa);
        assertEq(token.balanceOf(address(manager)), reserveDca);
        (uint160 price,,,) = StateLibrary.getSlot0(manager, key.toId());
        assertEq(price, Q96);
        (uint256 growth0, uint256 growth1) = StateLibrary.getFeeGrowthGlobals(manager, key.toId());
        assertEq(growth0, 0);
        assertEq(growth1, 0);
        assertFalse(TransientStateLibrary.isUnlocked(manager));
        assertEq(TransientStateLibrary.getNonzeroDeltaCount(manager), 0);
        router.swap(key, buy);
        assertEq(hook.claimFees(), 5 ether, "a reverted batch leaves future claims usable");
    }

    function test_FwaClaimIgnoresUnrelatedCurrencyClaims() public {
        router.donateClaims(Currency.wrap(address(token)), address(hook), 31 ether);
        assertEq(hook.pendingFees(), 0);
        assertEq(hook.claimFees(), 0);
        router.donateClaims(Currency.wrap(FWA), address(hook), 17 ether);
        assertEq(hook.pendingFees(), 17 ether);
        assertEq(hook.claimFees(), 17 ether);
        assertEq(fwa.balanceOf(RECIPIENT), 17 ether);
        assertEq(token.balanceOf(RECIPIENT), 0);
        assertEq(manager.balanceOf(address(hook), uint256(uint160(address(token)))), 31 ether);
    }

    function test_RemovingAllLiquidityCannotConsumeAccruedFees() public {
        router.swap(key, _params(true, -100 ether));
        router.swap(key, _params(false, -10 ether));
        uint256 fees = hook.pendingFees();
        router.liquidity(key, -60_000, 60_000, -int256(LIQUIDITY));
        controlRouter.liquidity(controlKey, -60_000, 60_000, -int256(LIQUIDITY));
        assertEq(StateLibrary.getLiquidity(manager, key.toId()), 0);
        assertEq(hook.pendingFees(), fees);
        assertGe(fwa.balanceOf(address(manager)), fees);
        assertEq(hook.claimFees(), fees);
        assertEq(fwa.balanceOf(RECIPIENT), fees);
    }

    function test_InitializedTickCrossingChargesFwaAndPreservesPoolFees() public {
        router.liquidity(key, -60, 60, int256(LIQUIDITY));
        controlRouter.liquidity(controlKey, -60, 60, int256(LIQUIDITY));
        // Cross the concentrated position's initialized tick in each direction.
        _compareAcrossTick(true, 10_000 ether);
        _compareAcrossTick(false, 30_000 ether);
        assertGt(hook.claimFees(), 500 ether);
    }

    function _compareAcrossTick(bool buy, uint256 amount) private {
        uint256 effective = buy ? amount - amount * 500 / 10_000 : amount;
        BalanceDelta raw = controlRouter.swap(controlKey, _params(buy, -int256(effective)));
        uint256 beforeFees = hook.pendingFees();
        BalanceDelta actual = router.swap(key, _params(buy, -int256(amount)));
        uint256 fee = (buy ? amount : uint256(_fwaDelta(raw))) * 500 / 10_000;
        assertEq(hook.pendingFees() - beforeFees, fee);
        assertEq(_dcaDelta(actual), _dcaDelta(raw));
        assertEq(_fwaDelta(actual), _fwaDelta(raw) - int256(fee));
        (uint160 price, int24 tick,,) = StateLibrary.getSlot0(manager, key.toId());
        (uint160 refPrice, int24 refTick,,) = StateLibrary.getSlot0(manager, controlKey.toId());
        assertEq(price, refPrice);
        assertEq(tick, refTick);
        assertTrue(tick < -60 || tick > 60, "must actually cross an initialized liquidity boundary");
        assertEq(StateLibrary.getLiquidity(manager, key.toId()), LIQUIDITY);
        (uint256 growth0, uint256 growth1) = StateLibrary.getFeeGrowthGlobals(manager, key.toId());
        (uint256 refGrowth0, uint256 refGrowth1) = StateLibrary.getFeeGrowthGlobals(manager, controlKey.toId());
        assertEq(growth0, refGrowth0);
        assertEq(growth1, refGrowth1);
    }
}

/// forge-config: default.fuzz.runs = 1000
contract DCAHookEdgesFwa0Test is DCAHookEdgesBase {
    function _fwaFirst() internal pure override returns (bool) {
        return true;
    }
}

/// forge-config: default.fuzz.runs = 1000
contract DCAHookEdgesFwa1Test is DCAHookEdgesBase {
    function _fwaFirst() internal pure override returns (bool) {
        return false;
    }
}
