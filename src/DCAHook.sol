// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @notice An immutable 5% FWA fee on swaps in the launch's DCA/FWA pool.
/// @dev Owns FWA ERC-6909 claims on the manager. Never transfers FWA from the hook to a wallet.
/// Exact-input buys and exact-output sells must fill their FWA leg completely or revert.
contract DCAHook is IUnlockCallback, ReentrancyGuard {
    using SafeCast for uint256;

    address public constant FWA = 0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845;
    address public constant FEE_RECIPIENT = 0xCAE0B01E56cB164ce866A137d3528658b2FCBd4b;
    uint256 public constant FEE_BPS = 500;
    uint256 public constant BPS = 10_000;
    uint24 public constant POOL_FEE = 12_500;
    int24 public constant TICK_SPACING = 60;
    uint160 public constant REQUIRED_HOOK_FLAGS = 0x20cc;
    uint256 private constant MAX_DELTA = (1 << 127) - 1;

    IPoolManager public immutable poolManager;
    address public immutable token;
    /// @notice The deploying launch factory, authorized only to initialize the fixed pool.
    address public immutable launchFactory;
    PoolId public immutable poolId;

    uint256 private _claimAmount;

    error ZeroAddress();
    error InvalidToken();
    error OnlyPoolManager();
    error OnlyLaunchFactory();
    error InvalidPool();
    error InvalidAmount();
    error PartialFill();
    error UnexpectedDelta();
    error NoClaimInProgress();

    /// @param grossFwa FWA paid by a buyer, or output before the hook fee on a sell.
    event HookFeeAccrued(PoolId indexed id, address indexed sender, bool buy, uint256 grossFwa, uint256 fee);
    event FeesClaimed(address indexed caller, address indexed recipient, uint256 amount);

    /// @dev Both arguments are static; no external calls or code checks are made at construction.
    /// Deployment must use a CREATE2 salt producing the exact REQUIRED_HOOK_FLAGS address bits.
    constructor(IPoolManager poolManager_, address token_) {
        if (address(poolManager_) == address(0) || token_ == address(0)) revert ZeroAddress();
        if (token_ == FWA || token_ == address(poolManager_)) revert InvalidToken();
        poolManager = poolManager_;
        token = token_;
        launchFactory = msg.sender;
        poolId = getPoolKey().toId();
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory permissions) {
        permissions.beforeInitialize = true;
        permissions.beforeSwap = true;
        permissions.afterSwap = true;
        permissions.beforeSwapReturnDelta = true;
        permissions.afterSwapReturnDelta = true;
    }

    function getPoolKey() public view returns (PoolKey memory key) {
        (address c0, address c1) = token < FWA ? (token, FWA) : (FWA, token);
        key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), POOL_FEE, TICK_SPACING, IHooks(address(this)));
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        _checkPool(key);
        if (sender != launchFactory) revert OnlyLaunchFactory();
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkPool(key);
        _checkAmount(params.amountSpecified);
        uint256 fee = 0;
        if (_fwaIsSpecified(key, params)) {
            fee = params.amountSpecified < 0
                ? feeOnGross(uint256(-params.amountSpecified))
                : feeOnNet(uint256(params.amountSpecified));
        }
        // A positive specified delta deducts the fee from an input, or grosses up an output.
        // Zero LP override preserves the mandatory, static 1.25% pool fee.
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        _checkPool(key);
        _checkAmount(params.amountSpecified);
        bool fwaIs0 = Currency.unwrap(key.currency0) == FWA;
        bool buy = params.zeroForOne == fwaIs0;
        int256 fwaDelta = fwaIs0 ? int256(delta.amount0()) : int256(delta.amount1());
        if (buy ? fwaDelta > 0 : fwaDelta < 0) revert UnexpectedDelta();

        uint256 fee;
        uint256 gross;
        bool specified = _fwaIsSpecified(key, params);
        if (specified) {
            fee = buy ? feeOnGross(uint256(-params.amountSpecified)) : feeOnNet(uint256(params.amountSpecified));
            // The specified fee was committed before the swap. A partial fill must roll it back.
            if (fwaDelta != params.amountSpecified + int256(fee)) revert PartialFill();
            gross = buy ? uint256(-params.amountSpecified) : uint256(fwaDelta);
        } else if (buy) {
            uint256 net = uint256(-fwaDelta);
            fee = feeOnNet(net);
            gross = net + fee;
        } else {
            gross = uint256(fwaDelta);
            fee = feeOnGross(gross);
        }

        if (fee != 0) {
            // Minting claims consumes the positive hook delta without an ERC-20 transfer.
            emit HookFeeAccrued(poolId, sender, buy, gross, fee);
            poolManager.mint(address(this), uint256(uint160(FWA)), fee);
        }
        return (IHooks.afterSwap.selector, specified ? int128(0) : fee.toInt128());
    }

    /// @notice Floor(5% of gross FWA), in FWA's 18-decimal base units.
    function feeOnGross(uint256 gross) public pure returns (uint256) {
        // 500/10_000 = 1/20 exactly, with no intermediate overflow.
        return gross / 20;
    }

    /// @notice Fee for the smallest gross amount whose post-fee amount equals net.
    /// @dev Inverts net = gross - floor(gross/20), preserving the same rounding rule.
    function feeOnNet(uint256 net) public pure returns (uint256 fee) {
        if (net == 0) return 0;
        if (net > MAX_DELTA) revert InvalidAmount();
        fee = (net - 1) / 19;
        if (net > MAX_DELTA - fee) revert InvalidAmount();
    }

    /// @notice All FWA claims owned by this hook, including any voluntarily donated claims.
    function pendingFees() public view returns (uint256) {
        return poolManager.balanceOf(address(this), uint256(uint160(FWA)));
    }

    /// @notice Anyone may pay gas to redeem fees exclusively to FEE_RECIPIENT.
    /// @dev Call outside an existing manager unlock. At most int128.max is paid per call.
    /// A failed payout atomically preserves the claims for a later retry.
    function claimFees() external nonReentrant returns (uint256 amount) {
        amount = pendingFees();
        if (amount == 0) return 0;
        if (amount > MAX_DELTA) amount = MAX_DELTA;
        _claimAmount = amount;
        emit FeesClaimed(msg.sender, FEE_RECIPIENT, amount);
        poolManager.unlock("");
    }

    function unlockCallback(bytes calldata) external onlyPoolManager returns (bytes memory) {
        uint256 amount = _claimAmount;
        if (amount == 0) revert NoClaimInProgress();
        _claimAmount = 0;
        poolManager.burn(address(this), uint256(uint160(FWA)), amount);
        // FWA permits this transfer because the PoolManager is the sender.
        poolManager.take(Currency.wrap(FWA), FEE_RECIPIENT, amount);
        return "";
    }

    function _checkPool(PoolKey calldata key) private view {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert InvalidPool();
    }

    function _checkAmount(int256 amount) private pure {
        int256 max = int256(type(int128).max);
        if (amount == 0 || amount < -max || amount > max) revert InvalidAmount();
    }

    function _fwaIsSpecified(PoolKey calldata key, SwapParams calldata params) private pure returns (bool) {
        bool specifiedIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        return specifiedIs0 == (Currency.unwrap(key.currency0) == FWA);
    }
}
