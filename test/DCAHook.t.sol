// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookTestBase} from "./helpers/HookTestBase.sol";
import {DCAHook} from "../src/DCAHook.sol";
import {RestrictedFWA} from "./helpers/RestrictedFWA.sol";
import {PoolRouter} from "./helpers/PoolRouter.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

abstract contract DCAHookBehavior is HookTestBase {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    function test_BuyExactInputChargesFivePercentOfFwaPaidIn() public {
        _compareSwap(true, true, 100 ether);
    }

    function test_SellExactInputChargesFivePercentOfGrossFwaOutput() public {
        _compareSwap(false, true, 100 ether);
    }

    function test_BuyExactOutputIncludesFeeInTotalFwaPaid() public {
        _compareSwap(true, false, 100 ether);
    }

    function test_SellExactOutputReceivesRequestedNetFwa() public {
        _compareSwap(false, false, 100 ether);
    }

    function testFuzz_FeeConservationAcrossSwapModes(bool buy, bool exactInput, uint256 amount) public {
        amount = bound(amount, 20, 1000 ether);
        _compareSwap(buy, exactInput, amount);
    }

    function _compareSwap(bool buy, bool exactInput, uint256 amount) internal {
        int256 specified = exactInput ? -int256(amount) : int256(amount);
        int256 controlSpecified = specified;
        if (buy && exactInput) controlSpecified += int256(amount * 500 / 10_000);
        if (!buy && !exactInput) controlSpecified += int256((amount - 1) * 500 / 9500);
        BalanceDelta raw = controlRouter.swap(controlKey, _params(buy, controlSpecified));
        uint256 pendingBefore = hook.pendingFees();
        uint256 fwaBefore = fwa.balanceOf(address(router));
        uint256 dcaBefore = token.balanceOf(address(router));
        BalanceDelta delta = router.swap(key, _params(buy, specified));
        uint256 paidFee = hook.pendingFees() - pendingBefore;
        uint256 grossFwa = buy ? uint256(-_fwaDelta(delta)) : uint256(_fwaDelta(raw));
        assertEq(paidFee, grossFwa * 500 / 10_000, "5% of actual gross FWA");
        assertEq(_dcaDelta(delta), _dcaDelta(raw), "no DCA hook fee");
        assertEq(_fwaDelta(delta), _fwaDelta(raw) - int256(paidFee));
        assertEq(int256(fwa.balanceOf(address(router))) - int256(fwaBefore), _fwaDelta(delta));
        assertEq(int256(token.balanceOf(address(router))) - int256(dcaBefore), _dcaDelta(delta));
        if (exactInput) assertEq(buy ? -_fwaDelta(delta) : -_dcaDelta(delta), int256(amount));
        else assertEq(buy ? _dcaDelta(delta) : _fwaDelta(delta), int256(amount));
        assertEq(fwa.balanceOf(address(hook)), 0, "FWA remains in manager");
        assertEq(token.balanceOf(address(hook)), 0, "hook never collects DCA");
        assertEq(fwa.balanceOf(RECIPIENT), 0, "fees retained until claim");
        assertEq(manager.balanceOf(address(hook), uint256(uint160(FWA))), hook.pendingFees());
        assertEq(IPoolManager(address(manager)).getNonzeroDeltaCount(), 0);
        assertEq(IPoolManager(address(manager)).currencyDelta(address(hook), Currency.wrap(FWA)), 0);
        (,,, uint24 lpFee) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(lpFee, 12_500, "mandatory pool fee retained");
        (uint256 growth0, uint256 growth1) = IPoolManager(address(manager)).getFeeGrowthGlobals(key.toId());
        assertGt(growth0 + growth1, 0, "pool fee accrues in addition to hook fee");
    }

    function test_PermissionlessClaimPaysOnlyFixedRecipientAndRepeatIsNoop() public {
        router.swap(key, _params(true, -100 ether));
        router.swap(key, _params(false, -20 ether));
        uint256 pending = hook.pendingFees();
        uint256 managerBefore = fwa.balanceOf(address(manager));
        address caller = makeAddr("any fee caller");
        vm.expectEmit(true, true, false, true, address(hook));
        emit DCAHook.FeesClaimed(caller, RECIPIENT, pending);
        vm.prank(caller);
        assertEq(hook.claimFees(), pending);
        assertEq(hook.pendingFees(), 0);
        assertEq(fwa.balanceOf(RECIPIENT), pending);
        assertEq(fwa.balanceOf(address(manager)), managerBefore - pending);
        assertEq(fwa.balanceOf(caller), 0);
        assertEq(hook.claimFees(), 0);
        assertEq(fwa.balanceOf(RECIPIENT), pending);
        router.swap(key, _params(true, -20 ether));
        assertEq(hook.claimFees(), 1 ether);
        assertEq(fwa.balanceOf(RECIPIENT), pending + 1 ether);
    }

    function test_ClaimBeforeFeesIsNoop() public {
        assertEq(hook.claimFees(), 0);
    }

    function test_FwaMockRejectsOrdinaryTransferButClaimSucceeds() public {
        fwa.mint(address(hook), 1 ether);
        vm.expectRevert(RestrictedFWA.InvalidTransfer.selector);
        vm.prank(address(hook));
        fwa.transfer(RECIPIENT, 1 ether);
        router.swap(key, _params(true, -100 ether));
        assertEq(hook.claimFees(), 5 ether);
        assertEq(fwa.balanceOf(RECIPIENT), 5 ether);
    }

    function test_FailedPayoutPreservesAllClaimsAndCanRetry() public {
        router.swap(key, _params(true, -100 ether));
        fwa.rejectRecipient(RECIPIENT);
        vm.expectRevert(); // PoolManager wraps the token's PayoutRejected error.
        hook.claimFees();
        assertEq(hook.pendingFees(), 5 ether);
        assertEq(fwa.balanceOf(RECIPIENT), 0);
        fwa.rejectRecipient(address(0));
        assertEq(hook.claimFees(), 5 ether);
        assertEq(hook.pendingFees(), 0);
    }

    function test_PayoutReentrancyCannotClaimTwice() public {
        router.swap(key, _params(true, -100 ether));
        fwa.setReentry(address(hook));
        assertEq(hook.claimFees(), 5 ether);
        assertTrue(fwa.reentryAttempted());
        assertFalse(fwa.reentrySucceeded());
        assertEq(fwa.reentryResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(fwa.balanceOf(RECIPIENT), 5 ether);
        assertEq(hook.pendingFees(), 0);
    }

    function test_ClaimInsideAnExistingUnlockRevertsWithoutLosingFees() public {
        router.swap(key, _params(true, -100 ether));
        vm.expectRevert(IPoolManager.AlreadyUnlocked.selector);
        router.claimInsideUnlock(hook);
        assertEq(hook.pendingFees(), 5 ether);
        assertEq(hook.claimFees(), 5 ether);
    }

    function test_ClaimIncludesDonatedFwaClaims() public {
        router.donateClaims(Currency.wrap(FWA), address(hook), 17 ether);
        router.swap(key, _params(true, -100 ether));
        assertEq(hook.claimFees(), 22 ether);
        assertEq(fwa.balanceOf(RECIPIENT), 22 ether);
    }

    function test_ClaimsAboveSignedDeltaLimitRemainClaimableInChunks() public {
        uint256 cap = (1 << 127) - 1;
        fwa.mint(address(router), 2 * cap);
        router.donateClaims(Currency.wrap(FWA), address(hook), cap);
        router.donateClaims(Currency.wrap(FWA), address(hook), cap);
        assertEq(hook.pendingFees(), 2 * cap);
        assertEq(hook.claimFees(), cap);
        assertEq(hook.pendingFees(), cap);
        assertEq(hook.claimFees(), cap);
        assertEq(hook.pendingFees(), 0);
        assertEq(fwa.balanceOf(RECIPIENT), 2 * cap);
    }

    function test_ClaimsCannotBeStolenByAnOperatorOrAllowance() public {
        router.swap(key, _params(true, -100 ether));
        assertFalse(manager.isOperator(address(hook), address(this)));
        assertEq(manager.allowance(address(hook), address(this), uint256(uint160(FWA))), 0);
        vm.expectRevert();
        manager.transferFrom(address(hook), address(this), uint256(uint160(FWA)), 1);
        assertEq(hook.pendingFees(), 5 ether);
    }

    function test_BatchedSwapsCollectOncePerSwapAndSettle() public {
        (BalanceDelta a, BalanceDelta b) = router.batchSwap(key, _params(true, -100 ether), _params(false, -10 ether));
        uint256 sellNet = uint256(_fwaDelta(b));
        uint256 sellFee = hook.pendingFees() - 5 ether;
        assertEq(sellFee, (sellNet + sellFee) / 20);
        assertEq(_fwaDelta(a), -100 ether);
        assertEq(IPoolManager(address(manager)).getNonzeroDeltaCount(), 0);
        assertEq(hook.claimFees(), 5 ether + sellFee);
    }

    function test_PartialExactInputBuyRevertsAndRollsBack() public {
        SwapParams memory params = _params(true, -100 ether);
        params.sqrtPriceLimitX96 = params.zeroForOne ? Q96 - 1 : Q96 + 1;
        uint256 balanceBefore = fwa.balanceOf(address(router));
        _expectHookError(IHooks.afterSwap.selector, DCAHook.PartialFill.selector);
        router.swap(key, params);
        assertEq(hook.pendingFees(), 0);
        assertEq(fwa.balanceOf(address(router)), balanceBefore);
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(price, Q96);
    }

    function test_PartialExactOutputSellRevertsAndRollsBack() public {
        SwapParams memory params = _params(false, 100 ether);
        params.sqrtPriceLimitX96 = params.zeroForOne ? Q96 - 1 : Q96 + 1;
        _expectHookError(IHooks.afterSwap.selector, DCAHook.PartialFill.selector);
        router.swap(key, params);
        assertEq(hook.pendingFees(), 0);
    }

    function test_PartialExactInputSellOnlyTaxesActualFwaOutput() public {
        SwapParams memory params = _params(false, -1000 ether);
        params.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(params.zeroForOne ? int24(-1) : int24(1));
        BalanceDelta delta = router.swap(key, params);
        assertLt(uint256(-_dcaDelta(delta)), 1000 ether);
        assertGt(_fwaDelta(delta), 0);
        uint256 gross = uint256(_fwaDelta(delta)) + hook.pendingFees();
        assertEq(hook.pendingFees(), gross / 20);
    }

    function test_PartialExactOutputBuyOnlyTaxesActualFwaInput() public {
        SwapParams memory params = _params(true, 1000 ether);
        params.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(params.zeroForOne ? int24(-1) : int24(1));
        BalanceDelta delta = router.swap(key, params);
        assertLt(uint256(_dcaDelta(delta)), 1000 ether);
        assertGt(_dcaDelta(delta), 0);
        assertEq(hook.pendingFees(), uint256(-_fwaDelta(delta)) / 20);
    }

    function test_DustBuyRoundsFeeDown() public {
        BalanceDelta delta = router.swap(key, _params(true, -19));
        assertEq(_fwaDelta(delta), -19);
        assertEq(hook.pendingFees(), 0);
        delta = router.swap(key, _params(true, -20));
        assertEq(_fwaDelta(delta), -20);
        assertEq(hook.pendingFees(), 1);
    }

    function test_DirectCallbacksRequireManager() public {
        SwapParams memory params = _params(true, -100 ether);
        vm.expectRevert(DCAHook.OnlyPoolManager.selector);
        hook.beforeInitialize(address(this), key, Q96);
        vm.expectRevert(DCAHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(this), key, params, "");
        vm.expectRevert(DCAHook.OnlyPoolManager.selector);
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
        vm.expectRevert(DCAHook.OnlyPoolManager.selector);
        hook.unlockCallback(abi.encode(RECIPIENT, 100 ether));
    }

    function test_CallbackFromManagerWithoutClaimReverts() public {
        vm.expectRevert(DCAHook.NoClaimInProgress.selector);
        vm.prank(address(manager));
        hook.unlockCallback("");
    }

    function test_InitializationCannotBeFrontRun() public {
        _expectHookError(IHooks.beforeInitialize.selector, DCAHook.OnlyLaunchFactory.selector);
        vm.prank(makeAddr("front runner"));
        manager.initialize(key, Q96 + 1);
    }

    function test_RejectsOtherFeeTickSpacingCurrencyAndHook() public {
        PoolKey memory wrong = key;
        wrong.fee = 3000;
        _expectHookError(IHooks.beforeInitialize.selector, DCAHook.InvalidPool.selector);
        manager.initialize(wrong, Q96);
        wrong.fee = 0;
        _expectHookError(IHooks.beforeInitialize.selector, DCAHook.InvalidPool.selector);
        manager.initialize(wrong, Q96);
        wrong.fee = 0x800000;
        _expectHookError(IHooks.beforeInitialize.selector, DCAHook.InvalidPool.selector);
        manager.initialize(wrong, Q96);
        wrong.fee = 12_500;
        wrong.tickSpacing = 10;
        _expectHookError(IHooks.beforeInitialize.selector, DCAHook.InvalidPool.selector);
        manager.initialize(wrong, Q96);
        wrong.tickSpacing = 60;
        wrong.currency0 = Currency.wrap(address(0));
        _expectHookError(IHooks.beforeInitialize.selector, DCAHook.InvalidPool.selector);
        manager.initialize(wrong, Q96);
        wrong.currency0 = key.currency0;
        wrong.hooks = IHooks(makeAddr("wrong hook"));
        vm.expectRevert(DCAHook.InvalidPool.selector);
        vm.prank(address(manager));
        hook.beforeInitialize(address(this), wrong, Q96);
    }

    function test_SwapCallbacksRejectDifferentPoolEvenFromManager() public {
        PoolKey memory wrong = key;
        wrong.fee = 3000;
        SwapParams memory params = _params(true, -100 ether);
        vm.expectRevert(DCAHook.InvalidPool.selector);
        vm.prank(address(manager));
        hook.beforeSwap(address(this), wrong, params, "");
        vm.expectRevert(DCAHook.InvalidPool.selector);
        vm.prank(address(manager));
        hook.afterSwap(address(this), wrong, params, BalanceDelta.wrap(0), "");
    }

    function test_FeeAndRecipientCannotBeChanged() public {
        assertEq(hook.FEE_BPS(), 500);
        assertEq(hook.FEE_RECIPIENT(), RECIPIENT);
        assertEq(hook.launchFactory(), address(this));
        string[6] memory functions = [
            "setFeeBps(uint256)",
            "setFeeRecipient(address)",
            "setFeeAddress(address)",
            "transferOwnership(address)",
            "setToken(address)",
            "upgradeTo(address)"
        ];
        for (uint256 i; i < functions.length; ++i) {
            (bool ok,) = address(hook).call(abi.encodeWithSignature(functions[i], makeAddr("attacker")));
            assertFalse(ok);
        }
        assertEq(hook.FEE_BPS(), 500);
        assertEq(hook.FEE_RECIPIENT(), RECIPIENT);
    }

    function test_RejectsZeroAndOutOfRangeAmounts() public {
        int256[4] memory amounts = [int256(0), type(int256).min, type(int256).max, int256(type(int128).max) + 1];
        for (uint256 i; i < amounts.length; ++i) {
            SwapParams memory params = _params(true, amounts[i]);
            vm.expectRevert(DCAHook.InvalidAmount.selector);
            vm.prank(address(manager));
            hook.beforeSwap(address(this), key, params, "");
        }
        SwapParams memory oversizedSell = _params(false, int256(type(int128).max));
        vm.expectRevert(DCAHook.InvalidAmount.selector);
        vm.prank(address(manager));
        hook.beforeSwap(address(this), key, oversizedSell, "");
        vm.expectRevert(DCAHook.InvalidAmount.selector);
        hook.feeOnNet(type(uint256).max);
    }

    function testFuzz_RoundingInverseIsMinimalAndExactlyFivePercent(uint256 net) public view {
        net = bound(net, 1, 1e35);
        uint256 fee = hook.feeOnNet(net);
        uint256 gross = net + fee;
        assertEq(fee, gross / 20);
        assertEq(gross - gross / 20, net);
        assertLt((gross - 1) - (gross - 1) / 20, net);
    }

    function test_LiquidityHasNoHookFeeAndCanBeRemoved() public {
        assertEq(hook.pendingFees(), 0);
        router.liquidity(key, -60_000, 60_000, -int256(LIQUIDITY));
        assertEq(hook.pendingFees(), 0);
    }

    function test_PermissionsMatchActualMinedAddress() public view {
        assertEq(uint160(address(hook)) & 0x3fff, 0x20cc);
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(
            p.beforeInitialize && p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta && p.afterSwapReturnDelta
        );
        assertFalse(
            p.afterInitialize || p.beforeAddLiquidity || p.afterAddLiquidity || p.beforeRemoveLiquidity
                || p.afterRemoveLiquidity || p.beforeDonate || p.afterDonate || p.afterAddLiquidityReturnDelta
                || p.afterRemoveLiquidityReturnDelta
        );
        assertEq(PoolId.unwrap(key.toId()), PoolId.unwrap(hook.poolId()));
        assertLe(address(hook).code.length, 24_576);
    }

    function test_SingleSidedLaunchSeedsWithoutFwaAndFirstBuyCanFundItsFee() public {
        router.liquidity(key, -60_000, 60_000, -int256(LIQUIDITY));
        controlRouter.liquidity(controlKey, -60_000, 60_000, -int256(LIQUIDITY));
        bool tokenIs0 = Currency.unwrap(key.currency0) == address(token);
        BalanceDelta seed = router.liquidity(
            key, tokenIs0 ? int24(0) : int24(-60_000), tokenIs0 ? int24(60_000) : int24(0), int256(LIQUIDITY)
        );
        assertEq(_fwaDelta(seed), 0, "single-sided seed requires no FWA");
        assertLt(_dcaDelta(seed), 0);
        assertEq(hook.pendingFees(), 0);
        assertLt(fwa.balanceOf(address(manager)), 5 ether, "fee exceeds pre-swap FWA reserves");
        uint256 dcaBefore = token.balanceOf(address(router));
        router.swap(key, _params(true, -100 ether));
        uint256 bought = token.balanceOf(address(router)) - dcaBefore;
        assertGt(bought, 0);
        assertEq(hook.pendingFees(), 5 ether);
        router.swap(key, _params(false, -int256(bought)));
        assertEq(token.balanceOf(address(router)), dcaBefore, "all bought DCA sold back");
        assertGt(hook.claimFees(), 5 ether);
    }
}

contract DCAHookFwaCurrency0Test is DCAHookBehavior {
    function _fwaFirst() internal pure override returns (bool) {
        return true;
    }
}

contract DCAHookFwaCurrency1Test is DCAHookBehavior {
    function _fwaFirst() internal pure override returns (bool) {
        return false;
    }
}
