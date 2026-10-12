// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HookTestBase} from "./helpers/HookTestBase.sol";
import {PoolRouter} from "./helpers/PoolRouter.sol";
import {RestrictedFWA} from "./helpers/RestrictedFWA.sol";
import {DCAToken} from "src/DCAToken.sol";
import {DCAHook} from "src/DCAHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev An identical pool without the hook provides the price/output oracle. Both pools
/// receive the same effective swaps and liquidity changes, so their state must stay equal.
contract DCAAccountingHandler is Test {
    DCAHook public immutable hook;
    IPoolManager public immutable manager;
    RestrictedFWA public immutable fwa;
    DCAToken public immutable token;
    PoolRouter[3] public traders;
    PoolRouter public immutable control;
    PoolKey private key;
    PoolKey private referenceKey;
    bool private immutable fwa0;
    address private constant RECIPIENT = 0xCAE0B01E56cB164ce866A137d3528658b2FCBd4b;

    uint256 public expectedAccrued;
    uint256 public donated;
    uint256 public paid;
    uint256 public liquidity = 1e24;
    uint256[4] public modeCalls;
    uint256 public failedPayouts;

    constructor(DCAHook hook_, PoolRouter[3] memory traders_, PoolRouter control_) {
        hook = hook_;
        manager = hook_.poolManager();
        token = DCAToken(hook_.token());
        fwa = RestrictedFWA(hook_.FWA());
        traders = traders_;
        control = control_;
        key = hook_.getPoolKey();
        referenceKey = PoolKey(key.currency0, key.currency1, key.fee, key.tickSpacing, IHooks(address(0)));
        fwa0 = Currency.unwrap(key.currency0) == address(fwa);
    }

    function swap(uint256 actorSeed, bool buy, bool exactInput, uint256 amount) public {
        // Leave ample reserves/funding for 64-call sequences, while crossing many ticks.
        amount = bound(amount, 1, 10_000 ether);
        _swap(traders[actorSeed % traders.length], buy, exactInput, amount);
    }

    function dustSwap(uint256 actorSeed, bool buy, bool exactInput, uint256 amount) public {
        _swap(traders[actorSeed % traders.length], buy, exactInput, bound(amount, 1, 40));
    }

    function _swap(PoolRouter trader, bool buy, bool exactInput, uint256 amount) private returns (BalanceDelta delta) {
        int256 specified = exactInput ? -int256(amount) : int256(amount);
        int256 effective = specified;
        if (buy && exactInput) effective += int256(amount * 500 / 10_000);
        if (!buy && !exactInput) effective += int256((amount - 1) * 500 / 9500);
        BalanceDelta raw = control.swap(referenceKey, _params(buy, effective));
        uint256 fwaBefore = fwa.balanceOf(address(trader));
        uint256 dcaBefore = token.balanceOf(address(trader));
        delta = trader.swap(key, _params(buy, specified));

        uint256 gross = buy ? uint256(-_fwa(delta)) : uint256(_fwa(raw));
        uint256 expectedFee = gross * 500 / 10_000;
        assertEq(_dca(delta), _dca(raw), "DCA leg must equal an untaxed pool");
        assertEq(_fwa(delta), _fwa(raw) - int256(expectedFee), "only FWA bears the additional 5%");
        assertEq(int256(fwa.balanceOf(address(trader))) - int256(fwaBefore), _fwa(delta));
        assertEq(int256(token.balanceOf(address(trader))) - int256(dcaBefore), _dca(delta));
        if (exactInput) assertEq(buy ? -_fwa(delta) : -_dca(delta), int256(amount));
        else assertEq(buy ? _dca(delta) : _fwa(delta), int256(amount));
        if (buy && !exactInput) {
            // At a rounding plateau there can be two gross values with the same net.
            // The buyer must pay the smaller one, even though both give a 5% fee.
            assertLt(gross - 1 - (gross - 1) * 500 / 10_000, uint256(-_fwa(raw)));
        }
        expectedAccrued += expectedFee;
        modeCalls[(buy ? 0 : 2) + (exactInput ? 0 : 1)]++;
        assertEq(hook.pendingFees(), expectedAccrued + donated - paid, "claims match external fee oracle");
    }

    function claim(uint256 callerSeed) public {
        uint256 expected = expectedAccrued + donated - paid;
        address caller = address(traders[callerSeed % traders.length]);
        uint256 callerBefore = fwa.balanceOf(caller);
        uint256 recipientBefore = fwa.balanceOf(RECIPIENT);
        vm.prank(caller);
        assertEq(hook.claimFees(), expected);
        paid += expected;
        assertEq(fwa.balanceOf(caller), callerBefore, "claim caller receives no fee");
        assertEq(fwa.balanceOf(RECIPIENT) - recipientBefore, expected);
    }

    function donate(uint256 actorSeed, uint256 amount) public {
        amount = bound(amount, 1, 100 ether);
        traders[actorSeed % traders.length].donateClaims(Currency.wrap(address(fwa)), address(hook), amount);
        donated += amount;
    }

    function rejectedPayout(uint256 actorSeed) public {
        if (expectedAccrued + donated == paid) donate(actorSeed, 1);
        uint256 pending = expectedAccrued + donated - paid;
        uint256 reserve = fwa.balanceOf(address(manager));
        fwa.rejectRecipient(RECIPIENT);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(fwa),
                IERC20.transfer.selector,
                abi.encodeWithSelector(RestrictedFWA.PayoutRejected.selector),
                abi.encodeWithSelector(CurrencyLibrary.ERC20TransferFailed.selector)
            )
        );
        vm.prank(address(traders[actorSeed % traders.length]));
        hook.claimFees();
        assertEq(hook.pendingFees(), pending, "failed payout must preserve every claim");
        assertEq(fwa.balanceOf(address(manager)), reserve);
        assertEq(fwa.balanceOf(RECIPIENT), paid);
        fwa.rejectRecipient(address(0));
        failedPayouts++;
    }

    function rejectedPartialFill(uint256 actorSeed, bool buy) public {
        (uint160 price,,,) = StateLibrary.getSlot0(manager, key.toId());
        SwapParams memory params = _params(buy, buy ? -int256(100 ether) : int256(100 ether));
        params.sqrtPriceLimitX96 = params.zeroForOne ? price - 1 : price + 1;
        PoolRouter trader = traders[actorSeed % traders.length];
        uint256 fwaBefore = fwa.balanceOf(address(trader));
        uint256 dcaBefore = token.balanceOf(address(trader));
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(DCAHook.PartialFill.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        trader.swap(key, params);
        assertEq(fwa.balanceOf(address(trader)), fwaBefore);
        assertEq(token.balanceOf(address(trader)), dcaBefore);
        assertEq(hook.pendingFees(), expectedAccrued + donated - paid);
    }

    function roundTrip(uint256 actorSeed, uint256 amount) public {
        PoolRouter trader = traders[actorSeed % traders.length];
        amount = bound(amount, 1000, 1000 ether);
        uint256 fwaBefore = fwa.balanceOf(address(trader));
        uint256 dcaBefore = token.balanceOf(address(trader));
        BalanceDelta purchase = _swap(trader, true, true, amount);
        uint256 bought = uint256(_dca(purchase));
        assertGt(bought, 0);
        _swap(trader, false, true, bought);
        assertEq(token.balanceOf(address(trader)), dcaBefore, "round trip sells exactly the acquired tokens");
        assertLt(fwa.balanceOf(address(trader)), fwaBefore, "round trip cannot create free FWA");
    }

    function changeLiquidity(uint256 newLiquidity) public {
        newLiquidity = bound(newLiquidity, 5e23, 2e24);
        int256 change = int256(newLiquidity) - int256(liquidity);
        BalanceDelta raw = control.liquidity(referenceKey, -60_000, 60_000, change);
        BalanceDelta actual = traders[0].liquidity(key, -60_000, 60_000, change);
        assertEq(BalanceDelta.unwrap(actual), BalanceDelta.unwrap(raw), "LP principal/fees are unaffected by hook");
        assertEq(hook.pendingFees(), expectedAccrued + donated - paid);
        liquidity = newLiquidity;
    }

    function _params(bool buy, int256 amount) private view returns (SwapParams memory) {
        bool zeroForOne = buy == fwa0;
        return SwapParams(zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }

    function _fwa(BalanceDelta delta) private view returns (int256) {
        return fwa0 ? int256(delta.amount0()) : int256(delta.amount1());
    }

    function _dca(BalanceDelta delta) private view returns (int256) {
        return fwa0 ? int256(delta.amount1()) : int256(delta.amount0());
    }
}

abstract contract DCAHookStatefulBase is HookTestBase {
    DCAAccountingHandler internal handler;
    PoolRouter[3] internal traders;

    function setUp() public override {
        super.setUp();
        traders[0] = router;
        for (uint256 i = 1; i < traders.length; ++i) {
            traders[i] = new PoolRouter(manager);
            token.transfer(address(traders[i]), 10_000_000 ether);
            fwa.mint(address(traders[i]), 10_000_000 ether);
        }
        handler = new DCAAccountingHandler(hook, traders, controlRouter);
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.swap.selector;
        selectors[1] = handler.dustSwap.selector;
        selectors[2] = handler.claim.selector;
        selectors[3] = handler.donate.selector;
        selectors[4] = handler.rejectedPayout.selector;
        selectors[5] = handler.rejectedPartialFill.selector;
        selectors[6] = handler.roundTrip.selector;
        selectors[7] = handler.changeLiquidity.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_AllAccruedFwaRemainsBackedAndBelongsOnlyToRecipient() public view {
        assertEq(hook.pendingFees() + handler.paid(), handler.expectedAccrued() + handler.donated());
        assertEq(fwa.balanceOf(RECIPIENT), handler.paid());
        assertGe(fwa.balanceOf(address(manager)), hook.pendingFees());
        assertEq(fwa.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(manager.balanceOf(address(hook), uint256(uint160(address(token)))), 0, "no DCA claims");
        for (uint256 i; i < traders.length; ++i) {
            assertFalse(manager.isOperator(address(hook), address(traders[i])));
            assertEq(manager.allowance(address(hook), address(traders[i]), uint256(uint160(FWA))), 0);
        }
    }

    function invariant_BothTokensConservedAcrossAllActors() public view {
        uint256 dcaSum = token.balanceOf(address(this)) + token.balanceOf(address(manager))
            + token.balanceOf(address(controlRouter));
        uint256 fwaSum =
            fwa.balanceOf(address(manager)) + fwa.balanceOf(address(controlRouter)) + fwa.balanceOf(RECIPIENT);
        for (uint256 i; i < traders.length; ++i) {
            dcaSum += token.balanceOf(address(traders[i]));
            fwaSum += fwa.balanceOf(address(traders[i]));
        }
        assertEq(dcaSum, 1_000_000_000 ether);
        assertEq(token.totalSupply(), dcaSum);
        assertEq(fwaSum, fwa.totalSupply());
    }

    function invariant_PriceLiquidityAndMandatoryPoolFeesMatchControl() public view {
        IPoolManager pm = IPoolManager(address(manager));
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = StateLibrary.getSlot0(pm, key.toId());
        (uint160 refPrice, int24 refTick, uint24 refProtocolFee, uint24 refLpFee) =
            StateLibrary.getSlot0(pm, controlKey.toId());
        assertEq(price, refPrice);
        assertEq(tick, refTick);
        assertEq(protocolFee, refProtocolFee);
        assertEq(lpFee, refLpFee);
        assertEq(lpFee, 12_500);
        assertEq(StateLibrary.getLiquidity(pm, key.toId()), handler.liquidity());
        (uint256 growth0, uint256 growth1) = StateLibrary.getFeeGrowthGlobals(pm, key.toId());
        (uint256 refGrowth0, uint256 refGrowth1) = StateLibrary.getFeeGrowthGlobals(pm, controlKey.toId());
        assertEq(growth0, refGrowth0, "currency0 pool fee is additional to hook fee");
        assertEq(growth1, refGrowth1, "currency1 pool fee is additional to hook fee");
    }

    function invariant_ManagerIsLockedWithoutUnsettledDebts() public view {
        IPoolManager pm = IPoolManager(address(manager));
        assertFalse(TransientStateLibrary.isUnlocked(pm));
        assertEq(TransientStateLibrary.getNonzeroDeltaCount(pm), 0);
        assertEq(TransientStateLibrary.currencyDelta(pm, address(hook), Currency.wrap(FWA)), 0);
    }

    function afterInvariant() public {
        handler.claim(2);
        assertEq(hook.pendingFees(), 0, "all fees remain claimable after any sequence");
        assertEq(fwa.balanceOf(RECIPIENT), handler.expectedAccrued() + handler.donated());
        invariant_ManagerIsLockedWithoutUnsettledDebts();
    }

    function test_AllHandlerPathsAndSwapModesReachMeaningfulStates() public {
        handler.swap(0, true, true, 10_000 ether);
        handler.swap(1, true, false, 10_000 ether);
        handler.swap(2, false, true, 10_000 ether);
        handler.swap(1, false, false, 10_000 ether);
        handler.dustSwap(2, true, true, 1);
        handler.donate(2, 17 ether);
        handler.rejectedPayout(1);
        handler.changeLiquidity(5e23);
        handler.rejectedPartialFill(0, true);
        handler.rejectedPartialFill(1, false);
        handler.roundTrip(2, 100 ether);
        for (uint256 i; i < 4; ++i) {
            assertGt(handler.modeCalls(i), 0);
        }
        assertEq(handler.failedPayouts(), 1);
        invariant_AllAccruedFwaRemainsBackedAndBelongsOnlyToRecipient();
        invariant_BothTokensConservedAcrossAllActors();
        invariant_PriceLiquidityAndMandatoryPoolFeesMatchControl();
        afterInvariant();
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract DCAHookStatefulFwa0Test is DCAHookStatefulBase {
    function _fwaFirst() internal pure override returns (bool) {
        return true;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract DCAHookStatefulFwa1Test is DCAHookStatefulBase {
    function _fwaFirst() internal pure override returns (bool) {
        return false;
    }
}
