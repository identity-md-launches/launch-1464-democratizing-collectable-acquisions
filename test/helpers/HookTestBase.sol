// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DCAToken} from "../../src/DCAToken.sol";
import {DCAHook} from "../../src/DCAHook.sol";
import {HookMiner} from "../../src/HookMiner.sol";
import {RestrictedFWA} from "./RestrictedFWA.sol";
import {PoolRouter} from "./PoolRouter.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";

abstract contract HookTestBase is Test {
    address internal constant FWA = 0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845;
    address internal constant RECIPIENT = 0xCAE0B01E56cB164ce866A137d3528658b2FCBd4b;
    uint160 internal constant Q96 = 79228162514264337593543950336;
    uint256 internal constant LIQUIDITY = 1e24;

    PoolManager internal manager;
    DCAToken internal token;
    DCAHook internal hook;
    RestrictedFWA internal fwa;
    PoolRouter internal router;
    PoolRouter internal controlRouter;
    PoolKey internal key;
    PoolKey internal controlKey;

    function _fwaFirst() internal pure virtual returns (bool);

    function setUp() public virtual {
        manager = new PoolManager(address(this));
        RestrictedFWA implementation = new RestrictedFWA(address(manager));
        vm.etch(FWA, address(implementation).code);
        fwa = RestrictedFWA(FWA);
        token = _deployToken(_fwaFirst());
        hook = _deployHook(IPoolManager(address(manager)), address(token));
        key = hook.getPoolKey();
        assertEq(Currency.unwrap(key.currency0) == FWA, _fwaFirst());
        controlKey = PoolKey(key.currency0, key.currency1, key.fee, key.tickSpacing, IHooks(address(0)));
        router = new PoolRouter(manager);
        controlRouter = new PoolRouter(manager);
        token.transfer(address(router), 100_000_000 ether);
        token.transfer(address(controlRouter), 100_000_000 ether);
        fwa.mint(address(router), 1e30);
        fwa.mint(address(controlRouter), 1e30);
        manager.initialize(key, Q96);
        manager.initialize(controlKey, Q96);
        router.liquidity(key, -60_000, 60_000, int256(LIQUIDITY));
        controlRouter.liquidity(controlKey, -60_000, 60_000, int256(LIQUIDITY));
    }

    function _deployToken(bool fwaFirst) internal returns (DCAToken deployed) {
        bytes32 hash = keccak256(type(DCAToken).creationCode);
        for (uint256 i; i < 100; ++i) {
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), hash)))));
            if ((FWA < predicted) == fwaFirst) return new DCAToken{salt: bytes32(i)}();
        }
        revert("token address search exhausted");
    }

    function _deployHook(IPoolManager manager_, address token_) internal returns (DCAHook deployed) {
        bytes32 hash = keccak256(abi.encodePacked(type(DCAHook).creationCode, abi.encode(manager_, token_)));
        (bytes32 salt, address predicted) = HookMiner.find(address(this), hash, 0, 1_000_000);
        deployed = new DCAHook{salt: salt}(manager_, token_);
        assertEq(address(deployed), predicted);
    }

    function _params(bool buy, int256 amount) internal view returns (SwapParams memory params) {
        bool zeroForOne = buy == (Currency.unwrap(key.currency0) == FWA);
        params = SwapParams(zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }

    function _fwaDelta(BalanceDelta delta) internal view returns (int256) {
        return Currency.unwrap(key.currency0) == FWA ? int256(delta.amount0()) : int256(delta.amount1());
    }

    function _dcaDelta(BalanceDelta delta) internal view returns (int256) {
        return Currency.unwrap(key.currency0) == FWA ? int256(delta.amount1()) : int256(delta.amount0());
    }

    function _expectHookError(bytes4 callback, bytes4 reason) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                callback,
                abi.encodeWithSelector(reason),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }
}
