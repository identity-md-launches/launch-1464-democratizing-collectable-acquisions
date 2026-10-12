// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DCAToken} from "./DCAToken.sol";
import {DCAHook} from "./DCAHook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

/// @notice One-transaction Ethereum mainnet launch of DCA paired with FWA.
/// @dev `launch` creates the 1,000,000,000 DCA supply in this contract, deploys the mined 5% FWA fee
/// hook, opens the DCA/FWA pool at a 2,000,000 FWA market cap, and seeds it single-sided with 88% of the
/// supply as permanently locked liquidity. The other 12% goes to the owner (the operator).
/// Every token this contract moves is its own balance: it never pulls tokens from another account.
contract DCAMainnetLauncher is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    address public constant FWA = 0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845;
    /// @notice Receives the hook's 5% FWA fee (via DCAHook) and this position's LP fees (via collectFees).
    address public constant FEE_RECIPIENT = 0xCAE0B01E56cB164ce866A137d3528658b2FCBd4b;
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 public constant POOL_BPS = 8_800;
    uint256 public constant POOL_AMOUNT = TOTAL_SUPPLY * POOL_BPS / 10_000;
    /// @notice Opening price is OPENING_MARKET_CAP_FWA / TOTAL_SUPPLY = 0.002 FWA per DCA.
    uint256 public constant OPENING_MARKET_CAP_FWA = 2_000_000e18;
    uint24 public constant POOL_FEE = 12_500;
    int24 public constant TICK_SPACING = 60;
    bytes32 public constant TOKEN_SALT = keccak256("DCA mainnet token");
    uint256 private constant Q96 = 1 << 96;

    enum Action {
        None,
        Seed,
        Collect
    }

    address public immutable owner;
    IPoolManager public immutable poolManager;

    DCAToken public token;
    DCAHook public hook;
    int24 public tickLower;
    int24 public tickUpper;
    uint128 public liquidity;

    Action private _action;

    error ZeroAddress();
    error Unauthorized();
    error AlreadyLaunched();
    error NotLaunched();
    error ContractNotDeployed(address account);
    error OnlyPoolManager();
    error NoActionInProgress();
    error UnexpectedDelta();
    error UnexpectedDeployment();

    event Launched(
        address indexed token,
        address indexed hook,
        PoolId indexed poolId,
        uint160 sqrtPriceX96,
        int24 tick,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 pooled,
        uint256 toOwner
    );
    event LiquidityFeesCollected(address indexed caller, address indexed recipient, uint256 dca, uint256 fwa);

    /// @param owner_ The operator and signer who alone may call `launch` and receives the 12% remainder.
    /// @param poolManager_ Uniswap v4 PoolManager on Ethereum mainnet.
    /// @dev No external calls or code checks; both are checked on first use in `launch`.
    constructor(address owner_, IPoolManager poolManager_) {
        if (owner_ == address(0) || address(poolManager_) == address(0)) revert ZeroAddress();
        owner = owner_;
        poolManager = poolManager_;
    }

    /// @notice The address `launch` deploys DCA to.
    function predictToken() public view returns (address) {
        return _create2Address(TOKEN_SALT, keccak256(type(DCAToken).creationCode));
    }

    /// @notice The init code hash to mine a hook salt against, with this contract as CREATE2 deployer.
    function hookInitCodeHash() public view returns (bytes32) {
        return keccak256(bytes.concat(type(DCAHook).creationCode, abi.encode(poolManager, predictToken())));
    }

    /// @notice The hook address for `salt`; it must satisfy `address & 0x3fff == 0x20cc`.
    function predictHook(bytes32 salt) external view returns (address) {
        return _create2Address(salt, hookInitCodeHash());
    }

    function dcaIsCurrency0() public view returns (bool) {
        return predictToken() < FWA;
    }

    /// @notice floor(sqrt(currency1 / currency0) * 2**96) for a 2,000,000 FWA market cap.
    function openingSqrtPriceX96(bool dcaIsCurrency0_) public pure returns (uint160) {
        uint256 ratioX192 = dcaIsCurrency0_
            ? FullMath.mulDiv(1 << 192, OPENING_MARKET_CAP_FWA, TOTAL_SUPPLY)
            : FullMath.mulDiv(1 << 192, TOTAL_SUPPLY, OPENING_MARKET_CAP_FWA);
        return _sqrt(ratioX192).toUint160();
    }

    /// @notice The single-sided DCA range: from the first usable tick at or beyond the opening price
    /// to the edge of the price range, so that seeding needs no FWA.
    function positionRange(int24 tick, bool dcaIsCurrency0_) public pure returns (int24 lower, int24 upper) {
        // Round down to a multiple of the spacing (Solidity's % keeps the sign of the dividend).
        int24 remainder = tick % TICK_SPACING;
        if (remainder < 0) remainder += TICK_SPACING;
        int24 aligned = tick - remainder;
        if (dcaIsCurrency0_) {
            (lower, upper) = (aligned + TICK_SPACING, TickMath.maxUsableTick(TICK_SPACING));
        } else {
            (lower, upper) = (TickMath.minUsableTick(TICK_SPACING), aligned);
        }
    }

    /// @notice Liquidity that POOL_AMOUNT DCA buys in [lower, upper], rounded down.
    function liquidityFor(int24 lower, int24 upper, bool dcaIsCurrency0_) public pure returns (uint128) {
        uint256 sqrtA = TickMath.getSqrtPriceAtTick(lower);
        uint256 sqrtB = TickMath.getSqrtPriceAtTick(upper);
        if (dcaIsCurrency0_) {
            return FullMath.mulDiv(POOL_AMOUNT, FullMath.mulDiv(sqrtA, sqrtB, Q96), sqrtB - sqrtA).toUint128();
        }
        return FullMath.mulDiv(POOL_AMOUNT, Q96, sqrtB - sqrtA).toUint128();
    }

    /// @notice DCA the position takes from this contract, rounded up exactly as the PoolManager does.
    function pooledAmount(int24 lower, int24 upper, uint128 liquidity_, bool dcaIsCurrency0_)
        public
        pure
        returns (uint256)
    {
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(upper);
        return dcaIsCurrency0_
            ? SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, liquidity_, true)
            : SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, liquidity_, true);
    }

    /// @notice Create DCA, deploy its hook, open the pool at a 2M FWA market cap and seed 88% of supply.
    /// @param hookSalt CREATE2 salt mined off-chain against `hookInitCodeHash()`.
    /// @dev Atomic: a wrong salt or any failure reverts everything and the call can be retried.
    /// The whole outcome is computed and recorded first; each external result is then checked against it.
    function launch(bytes32 hookSalt) external nonReentrant returns (DCAToken deployedToken, DCAHook deployedHook) {
        if (msg.sender != owner) revert Unauthorized();
        if (address(hook) != address(0)) revert AlreadyLaunched();
        if (address(poolManager).code.length == 0) revert ContractNotDeployed(address(poolManager));
        if (FWA.code.length == 0) revert ContractNotDeployed(FWA);

        address expectedToken = predictToken();
        address expectedHook = _create2Address(hookSalt, hookInitCodeHash());
        bool dcaIs0 = expectedToken < FWA;
        uint160 sqrtPriceX96 = openingSqrtPriceX96(dcaIs0);
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        (int24 lower, int24 upper) = positionRange(tick, dcaIs0);
        uint128 seeded = liquidityFor(lower, upper, dcaIs0);
        uint256 pooled = pooledAmount(lower, upper, seeded, dcaIs0);
        if (pooled > POOL_AMOUNT) revert UnexpectedDelta();

        token = DCAToken(expectedToken);
        hook = DCAHook(expectedHook);
        tickLower = lower;
        tickUpper = upper;
        liquidity = seeded;
        _action = Action.Seed;
        emit Launched(
            expectedToken,
            expectedHook,
            _poolKey(expectedToken, expectedHook).toId(),
            sqrtPriceX96,
            tick,
            lower,
            upper,
            seeded,
            pooled,
            TOTAL_SUPPLY - pooled
        );

        deployedToken = new DCAToken{salt: TOKEN_SALT}();
        deployedHook = new DCAHook{salt: hookSalt}(poolManager, expectedToken);
        if (address(deployedToken) != expectedToken || address(deployedHook) != expectedHook) {
            revert UnexpectedDeployment();
        }
        if (poolManager.initialize(_poolKey(expectedToken, expectedHook), sqrtPriceX96) != tick) {
            revert UnexpectedDelta();
        }
        if (abi.decode(poolManager.unlock(""), (uint256)) != pooled) revert UnexpectedDelta();
        IERC20(expectedToken).safeTransfer(owner, TOTAL_SUPPLY - pooled);
    }

    /// @notice Anyone may send the locked position's accrued LP fees to FEE_RECIPIENT.
    /// @dev Call outside an existing manager unlock. The liquidity itself can never be withdrawn.
    function collectFees() external nonReentrant returns (uint256 dcaAmount, uint256 fwaAmount) {
        if (address(hook) == address(0)) revert NotLaunched();
        _action = Action.Collect;
        (dcaAmount, fwaAmount) = abi.decode(poolManager.unlock(""), (uint256, uint256));
        emit LiquidityFeesCollected(msg.sender, FEE_RECIPIENT, dcaAmount, fwaAmount);
    }

    /// @notice The launched pool's key for liquidity tooling, quoters and routers.
    function getPoolKey() external view returns (PoolKey memory) {
        if (address(hook) == address(0)) revert NotLaunched();
        return _poolKey(address(token), address(hook));
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        Action action = _action;
        _action = Action.None;
        if (action == Action.Seed) return abi.encode(_seed());
        if (action == Action.Collect) {
            (uint256 dcaAmount, uint256 fwaAmount) = _collect();
            return abi.encode(dcaAmount, fwaAmount);
        }
        revert NoActionInProgress();
    }

    function _seed() private returns (uint256 owed) {
        PoolKey memory key = _poolKey(address(token), address(hook));
        (BalanceDelta delta, BalanceDelta fees) = poolManager.modifyLiquidity(
            key, ModifyLiquidityParams(tickLower, tickUpper, int256(uint256(liquidity)), bytes32(0)), ""
        );
        (int128 dcaDelta, int128 fwaDelta) = _split(key, delta);
        // A new single-sided position owes only DCA and has no fees; launch checks the exact amount.
        if (BalanceDelta.unwrap(fees) != 0 || fwaDelta != 0 || dcaDelta >= 0) revert UnexpectedDelta();
        owed = uint256(-int256(dcaDelta));

        Currency dca = Currency.wrap(address(token));
        poolManager.sync(dca);
        IERC20(address(token)).safeTransfer(address(poolManager), owed);
        if (poolManager.settle() != owed) revert UnexpectedDelta();
    }

    function _collect() private returns (uint256 dcaAmount, uint256 fwaAmount) {
        PoolKey memory key = _poolKey(address(token), address(hook));
        (BalanceDelta delta, BalanceDelta fees) =
            poolManager.modifyLiquidity(key, ModifyLiquidityParams(tickLower, tickUpper, 0, bytes32(0)), "");
        // With no liquidity change, the caller delta is exactly the accrued fees.
        if (BalanceDelta.unwrap(delta) != BalanceDelta.unwrap(fees)) revert UnexpectedDelta();
        (int128 dcaDelta, int128 fwaDelta) = _split(key, delta);
        if (dcaDelta < 0 || fwaDelta < 0) revert UnexpectedDelta();
        dcaAmount = uint256(int256(dcaDelta));
        fwaAmount = uint256(int256(fwaDelta));
        // The manager is the sender, which FWA's transfer rule allows.
        if (dcaAmount != 0) poolManager.take(Currency.wrap(address(token)), FEE_RECIPIENT, dcaAmount);
        if (fwaAmount != 0) poolManager.take(Currency.wrap(FWA), FEE_RECIPIENT, fwaAmount);
    }

    /// @dev Identical to DCAHook.getPoolKey(), which the hook enforces through its stored poolId.
    function _poolKey(address dca, address hook_) private pure returns (PoolKey memory) {
        (address c0, address c1) = dca < FWA ? (dca, FWA) : (FWA, dca);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), POOL_FEE, TICK_SPACING, IHooks(hook_));
    }

    function _split(PoolKey memory key, BalanceDelta delta) private pure returns (int128 dcaDelta, int128 fwaDelta) {
        if (Currency.unwrap(key.currency0) == FWA) return (delta.amount1(), delta.amount0());
        return (delta.amount0(), delta.amount1());
    }

    function _create2Address(bytes32 salt, bytes32 initCodeHash) private view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }

    function _sqrt(uint256 x) private pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
