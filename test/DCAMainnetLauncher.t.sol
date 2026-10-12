// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DCAMainnetLauncher} from "../src/DCAMainnetLauncher.sol";
import {DCAHook} from "../src/DCAHook.sol";
import {DCAToken} from "../src/DCAToken.sol";
import {HookMiner} from "../src/HookMiner.sol";
import {MainnetLaunch} from "../script/MainnetLaunch.s.sol";
import {RestrictedFWA} from "./helpers/RestrictedFWA.sol";
import {PoolRouter} from "./helpers/PoolRouter.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Position} from "v4-core/src/libraries/Position.sol";

/// @dev Transfer-restricted FWA model with the read ABI the mainnet preflight checks.
contract MainnetFWAMock is RestrictedFWA {
    // Etched code has no constructor storage, so the default (false) must mean "registered".
    bool public distributorRemoved;

    constructor(address manager_) RestrictedFWA(manager_) {}

    function symbol() public pure override returns (string memory) {
        return "FWA";
    }

    function poolManager() external view returns (address) {
        return manager;
    }

    function isDistributor(address account) external view returns (bool) {
        return account == manager && !distributorRemoved;
    }

    function setManagerIsDistributor(bool value) external {
        distributorRemoved = !value;
    }
}

/// @dev Called by the FWA mock during a payout; tries to re-enter the launcher's fee collection.
contract CollectReentrant {
    DCAMainnetLauncher public immutable launcher;
    bytes public innerError;

    constructor(DCAMainnetLauncher launcher_) {
        launcher = launcher_;
    }

    function claimFees() external {
        try launcher.collectFees() {}
        catch (bytes memory reason) {
            innerError = reason;
        }
    }
}

contract DCAMainnetLauncherTest is Test {
    using StateLibrary for IPoolManager;

    address private constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address private constant FWA = 0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845;
    address private constant OPERATOR = 0x1EE3ffadfE138415A2ddaedeEBe5F46616fA413d;
    address private constant RECIPIENT = 0xCAE0B01E56cB164ce866A137d3528658b2FCBd4b;
    uint256 private constant SUPPLY = 1_000_000_000e18;
    uint256 private constant POOL_AMOUNT = 880_000_000e18;
    uint256 private constant MARKET_CAP = 2_000_000e18;

    IPoolManager private manager;
    MainnetFWAMock private fwa;
    MainnetLaunch private config;
    uint256 private launcherSalt;

    function setUp() public {
        vm.chainId(1);
        // Run the real manager constructor at its mainnet address so NoDelegateCall's immutable matches.
        vm.etch(MANAGER, bytes.concat(type(PoolManager).creationCode, abi.encode(address(this))));
        (bool success, bytes memory runtime) = MANAGER.call("");
        require(success, "manager constructor failed");
        vm.etch(MANAGER, runtime);
        manager = IPoolManager(MANAGER);
        MainnetFWAMock implementation = new MainnetFWAMock(MANAGER);
        vm.etch(FWA, address(implementation).code);
        fwa = MainnetFWAMock(FWA);
        config = new MainnetLaunch();
    }

    // ---------------------------------------------------------------- helpers

    function _launcher(bool dcaFirst) private returns (DCAMainnetLauncher launcher) {
        for (uint256 i; i < 64; ++i) {
            launcher = new DCAMainnetLauncher{salt: bytes32(launcherSalt++)}(OPERATOR, manager);
            if (launcher.dcaIsCurrency0() == dcaFirst) return launcher;
        }
        revert("launcher ordering search exhausted");
    }

    function _salt(DCAMainnetLauncher launcher) private view returns (bytes32 salt) {
        (salt,) = HookMiner.find(address(launcher), launcher.hookInitCodeHash(), 0, 1_000_000);
    }

    function _launch(bool dcaFirst) private returns (DCAMainnetLauncher launcher, DCAToken token, DCAHook hook) {
        launcher = _launcher(dcaFirst);
        bytes32 salt = _salt(launcher);
        vm.prank(OPERATOR);
        (token, hook) = launcher.launch(salt);
    }

    function _marketCap(uint160 sqrtPriceX96, bool dcaFirst) private pure returns (uint256) {
        uint256 priceX192 = uint256(sqrtPriceX96) * sqrtPriceX96;
        // currency1 per currency0, in base units; both tokens have 18 decimals.
        return dcaFirst ? FullMath.mulDiv(priceX192, SUPPLY, 1 << 192) : FullMath.mulDiv(SUPPLY, 1 << 192, priceX192);
    }

    function _buy(PoolRouter router, PoolKey memory key, uint256 fwaIn) private returns (BalanceDelta) {
        bool zeroForOne = Currency.unwrap(key.currency0) == FWA;
        return router.swap(
            key,
            SwapParams(
                zeroForOne, -int256(fwaIn), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            )
        );
    }

    function _sell(PoolRouter router, PoolKey memory key, uint256 dcaIn) private returns (BalanceDelta) {
        bool zeroForOne = Currency.unwrap(key.currency0) != FWA;
        return router.swap(
            key,
            SwapParams(
                zeroForOne, -int256(dcaIn), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            )
        );
    }

    // ---------------------------------------------------------------- configuration

    function test_Constants() public {
        DCAMainnetLauncher launcher = new DCAMainnetLauncher(OPERATOR, manager);
        assertEq(launcher.owner(), OPERATOR);
        assertEq(address(launcher.poolManager()), MANAGER);
        assertEq(launcher.FEE_RECIPIENT(), RECIPIENT);
        assertEq(launcher.TOTAL_SUPPLY(), SUPPLY);
        assertEq(launcher.POOL_AMOUNT(), POOL_AMOUNT);
        assertEq(launcher.OPENING_MARKET_CAP_FWA(), MARKET_CAP);
    }

    function test_ConstructorRejectsZeroAddresses() public {
        vm.expectRevert(DCAMainnetLauncher.ZeroAddress.selector);
        new DCAMainnetLauncher(address(0), manager);
        vm.expectRevert(DCAMainnetLauncher.ZeroAddress.selector);
        new DCAMainnetLauncher(OPERATOR, IPoolManager(address(0)));
    }

    function test_DeployConfigUsesOperatorWhoeverSends() public {
        (address owner, IPoolManager poolManager) = config.constructorArgs();
        assertEq(owner, OPERATOR);
        assertEq(address(poolManager), MANAGER);
        vm.prank(makeAddr("factory"));
        DCAMainnetLauncher launcher = config.deploy();
        assertEq(launcher.owner(), OPERATOR);
        assertEq(address(launcher.poolManager()), MANAGER);
        assertEq(address(launcher.hook()), address(0));
    }

    function test_OpeningPriceIsTwoMillionFwaMarketCap() public pure {
        // DCA as currency0: price = 0.002 FWA per DCA; FWA as currency0: price = 500 DCA per FWA.
        uint256 ratio0 = FullMath.mulDiv(1 << 192, MARKET_CAP, SUPPLY);
        uint256 ratio1 = FullMath.mulDiv(1 << 192, SUPPLY, MARKET_CAP);
        assertEq(ratio0, (uint256(1) << 192) / 500);
        assertEq(ratio1, (uint256(1) << 192) * 500);
    }

    function test_OpeningSqrtPriceIsFloorSqrt() public {
        DCAMainnetLauncher launcher = new DCAMainnetLauncher(OPERATOR, manager);
        uint256 s0 = launcher.openingSqrtPriceX96(true);
        uint256 s1 = launcher.openingSqrtPriceX96(false);
        uint256 ratio0 = (uint256(1) << 192) / 500;
        uint256 ratio1 = (uint256(1) << 192) * 500;
        assertLe(s0 * s0, ratio0);
        assertGt((s0 + 1) * (s0 + 1), ratio0);
        assertLe(s1 * s1, ratio1);
        assertGt((s1 + 1) * (s1 + 1), ratio1);
        assertApproxEqRel(_marketCap(uint160(s0), true), MARKET_CAP, 1e3);
        assertApproxEqRel(_marketCap(uint160(s1), false), MARKET_CAP, 1e3);
    }

    function testFuzz_PositionRangeIsSingleSidedAndAligned(int24 tick, bool dcaFirst) public {
        tick = int24(bound(tick, TickMath.minUsableTick(60) + 60, TickMath.maxUsableTick(60) - 120));
        DCAMainnetLauncher launcher = new DCAMainnetLauncher(OPERATOR, manager);
        (int24 lower, int24 upper) = launcher.positionRange(tick, dcaFirst);
        assertEq(lower % 60, 0);
        assertEq(upper % 60, 0);
        assertLt(lower, upper);
        if (dcaFirst) {
            assertLt(tick, lower);
            assertLe(lower - tick, 60);
            assertEq(upper, TickMath.maxUsableTick(60));
        } else {
            assertGe(tick, upper);
            assertLt(tick - upper, 60);
            assertEq(lower, TickMath.minUsableTick(60));
        }
    }

    // ---------------------------------------------------------------- launch

    function test_LaunchDcaAsCurrency0() public {
        _checkLaunch(true);
    }

    function test_LaunchFwaAsCurrency0() public {
        _checkLaunch(false);
    }

    struct Expected {
        address token;
        address hook;
        PoolId id;
        uint160 sqrtPriceX96;
        int24 tick;
        int24 lower;
        int24 upper;
        uint128 liquidity;
        uint256 pooled;
    }

    function _expected(DCAMainnetLauncher launcher, bytes32 salt, bool dcaFirst)
        private
        view
        returns (Expected memory e)
    {
        e.token = launcher.predictToken();
        e.hook = launcher.predictHook(salt);
        e.sqrtPriceX96 = launcher.openingSqrtPriceX96(dcaFirst);
        e.tick = TickMath.getTickAtSqrtPrice(e.sqrtPriceX96);
        (e.lower, e.upper) = launcher.positionRange(e.tick, dcaFirst);
        e.liquidity = launcher.liquidityFor(e.lower, e.upper, dcaFirst);
        e.pooled = launcher.pooledAmount(e.lower, e.upper, e.liquidity, dcaFirst);
        (address c0, address c1) = dcaFirst ? (e.token, FWA) : (FWA, e.token);
        e.id = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 12_500, 60, IHooks(e.hook)).toId();
    }

    function _checkLaunch(bool dcaFirst) private {
        DCAMainnetLauncher launcher = _launcher(dcaFirst);
        bytes32 salt = _salt(launcher);
        Expected memory e = _expected(launcher, salt, dcaFirst);

        vm.expectEmit(true, true, true, true, address(launcher));
        emit DCAMainnetLauncher.Launched(
            e.token, e.hook, e.id, e.sqrtPriceX96, e.tick, e.lower, e.upper, e.liquidity, e.pooled, SUPPLY - e.pooled
        );
        vm.prank(OPERATOR);
        (DCAToken token, DCAHook hook) = launcher.launch(salt);
        _checkLaunched(launcher, token, hook, e, dcaFirst);
    }

    function _checkLaunched(DCAMainnetLauncher launcher, DCAToken token, DCAHook hook, Expected memory e, bool dcaFirst)
        private
        view
    {
        assertEq(address(token), e.token);
        assertEq(address(hook), e.hook);
        assertEq(address(launcher.token()), e.token);
        assertEq(address(launcher.hook()), e.hook);
        assertEq(uint160(address(hook)) & 0x3fff, 0x20cc);
        assertEq(hook.launchFactory(), address(launcher));
        assertEq(hook.token(), address(token));
        assertEq(address(hook.poolManager()), MANAGER);
        _checkAllocation(launcher, token, e.pooled);
        _checkPool(launcher, hook, e, dcaFirst);
    }

    /// @dev 88% in the pool, the rest to the operator, nothing left behind, no FWA used.
    function _checkAllocation(DCAMainnetLauncher launcher, DCAToken token, uint256 expectedPooled) private view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.name(), "Democratizing Collectable Acquisions");
        assertEq(token.symbol(), "DCA");
        uint256 pooled = token.balanceOf(MANAGER);
        assertEq(pooled, expectedPooled);
        assertLe(pooled, POOL_AMOUNT);
        assertGe(pooled, POOL_AMOUNT - 1e9);
        assertEq(token.balanceOf(OPERATOR), SUPPLY - pooled);
        assertEq(token.balanceOf(address(launcher)), 0);
        assertEq(fwa.balanceOf(MANAGER), 0);
        assertEq(fwa.balanceOf(address(launcher)), 0);
    }

    /// @dev The pool opens at the 2M FWA market cap; the position is single-sided and owned by the launcher.
    function _checkPool(DCAMainnetLauncher launcher, DCAHook hook, Expected memory e, bool dcaFirst) private view {
        PoolKey memory key = launcher.getPoolKey();
        PoolId id = key.toId();
        assertEq(PoolId.unwrap(id), PoolId.unwrap(e.id));
        assertEq(PoolId.unwrap(id), PoolId.unwrap(hook.getPoolKey().toId()));
        assertEq(PoolId.unwrap(id), PoolId.unwrap(hook.poolId()));
        assertEq(Currency.unwrap(key.currency0) == e.token, dcaFirst);
        assertEq(address(key.hooks), address(hook));
        assertEq(key.fee, 12_500);
        assertEq(key.tickSpacing, 60);

        (uint160 sqrtPriceX96, int24 tick,,) = manager.getSlot0(id);
        assertEq(sqrtPriceX96, e.sqrtPriceX96);
        assertApproxEqRel(_marketCap(sqrtPriceX96, dcaFirst), MARKET_CAP, 1e3);
        assertEq(tick, e.tick);

        assertEq(launcher.tickLower(), e.lower);
        assertEq(launcher.tickUpper(), e.upper);
        assertEq(launcher.liquidity(), e.liquidity);
        assertGt(e.liquidity, 0);
        if (dcaFirst) assertLt(tick, e.lower);
        else assertGe(tick, e.upper);
        // Not in range until the first buy crosses into it.
        assertEq(manager.getLiquidity(id), 0);
        bytes32 positionKey = Position.calculatePositionKey(address(launcher), e.lower, e.upper, bytes32(0));
        assertEq(manager.getPositionLiquidity(id, positionKey), e.liquidity);
    }

    function test_FirstBuyPaysNearOpeningPriceAndFeesReachRecipient() public {
        _checkTrading(true);
        _checkTrading(false);
    }

    function _checkTrading(bool dcaFirst) private {
        (DCAMainnetLauncher launcher, DCAToken token, DCAHook hook) = _launch(dcaFirst);
        PoolKey memory key = launcher.getPoolKey();
        PoolRouter router = new PoolRouter(manager);
        fwa.mint(address(router), 1_000e18);
        uint256 recipientFwa = fwa.balanceOf(RECIPIENT);

        _buy(router, key, 1_000e18);
        uint256 bought = token.balanceOf(address(router));
        // 5% hook fee and 1.25% pool fee, then 0.002 FWA per DCA (or slightly more past the first tick).
        uint256 atOpening = (950e18 * 9875 / 10_000) * SUPPLY / MARKET_CAP;
        assertLe(bought, atOpening);
        assertGe(bought, atOpening * 99 / 100);
        assertEq(hook.pendingFees(), 50e18);

        assertEq(hook.claimFees(), 50e18);
        assertEq(fwa.balanceOf(RECIPIENT), recipientFwa + 50e18);

        (uint256 dcaFees, uint256 fwaFees) = launcher.collectFees();
        assertEq(dcaFees, 0);
        assertApproxEqAbs(fwaFees, 950e18 * 125 / 10_000, 1e6);
        assertEq(fwa.balanceOf(RECIPIENT), recipientFwa + 50e18 + fwaFees);

        uint256 recipientDca = token.balanceOf(RECIPIENT);
        _sell(router, key, bought / 2);
        (dcaFees, fwaFees) = launcher.collectFees();
        assertApproxEqAbs(dcaFees, (bought / 2) * 125 / 10_000, 1e6);
        assertEq(fwaFees, 0);
        assertEq(token.balanceOf(RECIPIENT), recipientDca + dcaFees);
        assertGt(hook.pendingFees(), 0);

        // The seeded liquidity is untouched by fee collection and cannot be withdrawn.
        bytes32 positionKey =
            Position.calculatePositionKey(address(launcher), launcher.tickLower(), launcher.tickUpper(), bytes32(0));
        assertEq(manager.getPositionLiquidity(key.toId(), positionKey), launcher.liquidity());
    }

    function test_CollectFeesWithNothingAccruedReturnsZero() public {
        (DCAMainnetLauncher launcher,,) = _launch(true);
        (uint256 dcaFees, uint256 fwaFees) = launcher.collectFees();
        assertEq(dcaFees, 0);
        assertEq(fwaFees, 0);
    }

    function test_CollectFeesPayoutFailureRevertsAndRetries() public {
        (DCAMainnetLauncher launcher,,) = _launch(false);
        PoolKey memory key = launcher.getPoolKey();
        PoolRouter router = new PoolRouter(manager);
        fwa.mint(address(router), 1_000e18);
        _buy(router, key, 1_000e18);

        fwa.rejectRecipient(RECIPIENT);
        vm.expectRevert(); // the manager wraps the token's PayoutRejected
        launcher.collectFees();
        assertEq(fwa.balanceOf(RECIPIENT), 0);

        fwa.rejectRecipient(address(0));
        (, uint256 fwaFees) = launcher.collectFees();
        assertGt(fwaFees, 0);
        assertEq(fwa.balanceOf(RECIPIENT), fwaFees);
    }

    function test_CollectFeesCannotBeReentered() public {
        (DCAMainnetLauncher launcher,,) = _launch(true);
        PoolRouter router = new PoolRouter(manager);
        fwa.mint(address(router), 1_000e18);
        _buy(router, launcher.getPoolKey(), 1_000e18);

        CollectReentrant attacker = new CollectReentrant(launcher);
        fwa.setReentry(address(attacker));
        (, uint256 fwaFees) = launcher.collectFees();
        assertTrue(fwa.reentryAttempted());
        assertEq(bytes4(attacker.innerError()), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        assertEq(fwa.balanceOf(RECIPIENT), fwaFees);
    }

    // ---------------------------------------------------------------- failures

    function test_OnlyOperatorCanLaunch() public {
        DCAMainnetLauncher launcher = _launcher(true);
        bytes32 salt = _salt(launcher);
        vm.expectRevert(DCAMainnetLauncher.Unauthorized.selector);
        launcher.launch(salt); // the deploying factory has no rights
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(DCAMainnetLauncher.Unauthorized.selector);
        launcher.launch(salt);
        assertEq(launcher.predictToken().code.length, 0);
    }

    function test_LaunchOnlyOnce() public {
        (DCAMainnetLauncher launcher,,) = _launch(true);
        vm.prank(OPERATOR);
        vm.expectRevert(DCAMainnetLauncher.AlreadyLaunched.selector);
        launcher.launch(bytes32(0));
    }

    function test_WrongSaltRollsBackAndCanRetry() public {
        DCAMainnetLauncher launcher = _launcher(false);
        bytes32 good = _salt(launcher);
        bytes32 bad = bytes32(uint256(good) + 1);
        if (uint160(launcher.predictHook(bad)) & 0x3fff == 0x20cc) bad = bytes32(uint256(good) + 2);

        vm.prank(OPERATOR);
        vm.expectRevert();
        launcher.launch(bad);
        assertEq(launcher.predictToken().code.length, 0);
        assertEq(address(launcher.hook()), address(0));
        assertEq(address(launcher.token()), address(0));

        vm.prank(OPERATOR);
        (DCAToken token,) = launcher.launch(good);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_LaunchRequiresManagerAndFwaCode() public {
        DCAMainnetLauncher noManager = new DCAMainnetLauncher(OPERATOR, IPoolManager(makeAddr("no manager")));
        vm.prank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(DCAMainnetLauncher.ContractNotDeployed.selector, makeAddr("no manager")));
        noManager.launch(bytes32(0));

        DCAMainnetLauncher launcher = _launcher(true);
        bytes32 salt = _salt(launcher);
        vm.etch(FWA, "");
        vm.prank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(DCAMainnetLauncher.ContractNotDeployed.selector, FWA));
        launcher.launch(salt);
    }

    function test_NotLaunchedViewsAndFees() public {
        DCAMainnetLauncher launcher = new DCAMainnetLauncher(OPERATOR, manager);
        vm.expectRevert(DCAMainnetLauncher.NotLaunched.selector);
        launcher.collectFees();
        vm.expectRevert(DCAMainnetLauncher.NotLaunched.selector);
        launcher.getPoolKey();
    }

    function test_UnlockCallbackIsAuthenticated() public {
        (DCAMainnetLauncher launcher,,) = _launch(true);
        vm.expectRevert(DCAMainnetLauncher.OnlyPoolManager.selector);
        launcher.unlockCallback("");
        vm.prank(MANAGER);
        vm.expectRevert(DCAMainnetLauncher.NoActionInProgress.selector);
        launcher.unlockCallback("");
    }

    function test_OthersCannotInitializeTheHookedPool() public {
        (DCAMainnetLauncher launcher,,) = _launch(true);
        PoolKey memory key = launcher.getPoolKey();
        vm.expectRevert(); // already initialized, and the hook only admits its launcher
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
    }

    // ---------------------------------------------------------------- preparation script

    function test_PrepareReturnsExecutableLaunch() public {
        DCAMainnetLauncher launcher = config.deploy();
        MainnetLaunch.Launch memory plan = config.prepare(launcher, 0, 1_000_000);
        assertEq(plan.chainId, 1);
        assertEq(plan.from, OPERATOR);
        assertEq(plan.to, address(launcher));

        vm.prank(plan.from);
        (bool success,) = plan.to.call(plan.data);
        assertTrue(success);
        assertEq(address(launcher.token()), plan.token);
        assertEq(address(launcher.hook()), plan.hook);
        assertEq(PoolId.unwrap(launcher.getPoolKey().toId()), PoolId.unwrap(plan.poolId));
        assertEq(launcher.tickLower(), plan.tickLower);
        assertEq(launcher.tickUpper(), plan.tickUpper);
        assertEq(launcher.liquidity(), plan.liquidity);
        assertEq(launcher.token().balanceOf(MANAGER), plan.pooled);
        assertEq(launcher.token().balanceOf(OPERATOR), plan.toOperator);
        assertEq(plan.pooled + plan.toOperator, SUPPLY);
        (uint160 sqrtPriceX96, int24 tick,,) = manager.getSlot0(plan.poolId);
        assertEq(sqrtPriceX96, plan.sqrtPriceX96);
        assertEq(tick, plan.tick);

        vm.expectRevert(MainnetLaunch.AlreadyLaunched.selector);
        config.prepare(launcher, 0, 1_000_000);
    }

    function test_PrepareRejectsWrongSetup() public {
        DCAMainnetLauncher launcher = config.deploy();

        vm.chainId(8453);
        vm.expectRevert(abi.encodeWithSelector(MainnetLaunch.WrongChain.selector, 8453));
        config.prepare(launcher, 0, 1_000_000);
        vm.chainId(1);

        DCAMainnetLauncher other = new DCAMainnetLauncher(makeAddr("other"), manager);
        vm.expectRevert(abi.encodeWithSelector(MainnetLaunch.WrongOwner.selector, makeAddr("other")));
        config.prepare(other, 0, 1_000_000);

        DCAMainnetLauncher wrongManager = new DCAMainnetLauncher(OPERATOR, IPoolManager(address(fwa)));
        vm.expectRevert(abi.encodeWithSelector(MainnetLaunch.WrongManager.selector, FWA));
        config.prepare(wrongManager, 0, 1_000_000);

        vm.expectRevert(abi.encodeWithSelector(MainnetLaunch.ContractNotDeployed.selector, makeAddr("nothing")));
        config.prepare(DCAMainnetLauncher(makeAddr("nothing")), 0, 1_000_000);

        fwa.setManagerIsDistributor(false);
        vm.expectRevert(MainnetLaunch.InvalidFWAConfiguration.selector);
        config.prepare(launcher, 0, 1_000_000);
        fwa.setManagerIsDistributor(true);

        vm.expectRevert(HookMiner.SaltNotFound.selector);
        config.prepare(launcher, 0, 1);
    }
}
