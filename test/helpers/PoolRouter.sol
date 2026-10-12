// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {DCAHook} from "../../src/DCAHook.sol";

/// @dev Test-only trader/LP. Funds are held by the router to expose exact balance changes.
contract PoolRouter is IUnlockCallback {
    using SafeERC20 for IERC20;

    IPoolManager public immutable manager;
    uint256 public lastClaimAmount;

    enum Action {
        Swap,
        Liquidity,
        Claim,
        MintClaims,
        BatchSwap
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams memory params) external returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(Action.Swap, abi.encode(key, params))), (BalanceDelta));
    }

    function batchSwap(PoolKey memory key, SwapParams memory first, SwapParams memory second)
        external
        returns (BalanceDelta, BalanceDelta)
    {
        return abi.decode(
            manager.unlock(abi.encode(Action.BatchSwap, abi.encode(key, first, second))), (BalanceDelta, BalanceDelta)
        );
    }

    function liquidity(PoolKey memory key, int24 lower, int24 upper, int256 amount) external returns (BalanceDelta) {
        return abi.decode(
            manager.unlock(
                abi.encode(Action.Liquidity, abi.encode(key, ModifyLiquidityParams(lower, upper, amount, 0)))
            ),
            (BalanceDelta)
        );
    }

    function claimInsideUnlock(DCAHook hook) external {
        manager.unlock(abi.encode(Action.Claim, abi.encode(hook)));
    }

    function donateClaims(Currency currency, address recipient, uint256 amount) external {
        manager.unlock(abi.encode(Action.MintClaims, abi.encode(currency, recipient, amount)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (Action action, bytes memory payload) = abi.decode(data, (Action, bytes));
        if (action == Action.Claim) {
            DCAHook hook = abi.decode(payload, (DCAHook));
            lastClaimAmount = hook.claimFees();
            return "";
        }
        if (action == Action.MintClaims) {
            (Currency currency, address recipient, uint256 amount) = abi.decode(payload, (Currency, address, uint256));
            manager.mint(recipient, currency.toId(), amount);
            _settle(currency, -int128(int256(amount)));
            return "";
        }
        PoolKey memory key;
        BalanceDelta delta;
        if (action == Action.Swap) {
            SwapParams memory params;
            (key, params) = abi.decode(payload, (PoolKey, SwapParams));
            delta = manager.swap(key, params, "");
        } else if (action == Action.BatchSwap) {
            SwapParams memory first;
            SwapParams memory second;
            (key, first, second) = abi.decode(payload, (PoolKey, SwapParams, SwapParams));
            BalanceDelta a = manager.swap(key, first, "");
            BalanceDelta b = manager.swap(key, second, "");
            delta = a + b;
            _settle(key.currency0, delta.amount0());
            _settle(key.currency1, delta.amount1());
            return abi.encode(a, b);
        } else {
            ModifyLiquidityParams memory params;
            (key, params) = abi.decode(payload, (PoolKey, ModifyLiquidityParams));
            (delta,) = manager.modifyLiquidity(key, params, "");
        }
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 delta) private {
        if (delta < 0) {
            manager.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransfer(address(manager), uint256(-int256(delta)));
            manager.settle();
        } else if (delta > 0) {
            manager.take(currency, address(this), uint256(int256(delta)));
        }
    }
}
