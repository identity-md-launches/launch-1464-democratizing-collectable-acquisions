// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DCAHook} from "../src/DCAHook.sol";
import {DCAHookLauncher} from "../src/DCAHookLauncher.sol";
import {DCAToken} from "../src/DCAToken.sol";
import {HookMiner} from "../src/HookMiner.sol";
import {PrepareHook} from "../script/PrepareHook.s.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/// @dev Models an application factory that cannot mine hook addresses or call hook-specific constructors.
contract OrdinaryApplicationFactory {
    function deploy(address owner, IPoolManager manager) external returns (DCAHookLauncher) {
        return new DCAHookLauncher(owner, manager);
    }
}

contract DCAHookLauncherTest is Test {
    using StateLibrary for IPoolManager;

    address private constant FWA = 0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845;
    uint160 private constant Q96 = 79228162514264337593543950336;

    IPoolManager private manager;
    DCAToken private token;
    OrdinaryApplicationFactory private factory;
    DCAHookLauncher private launcher;
    PrepareHook private prepare;
    address private owner;

    function setUp() public {
        owner = makeAddr("requester");
        manager = IPoolManager(address(new PoolManager(address(this))));
        token = new DCAToken();
        factory = new OrdinaryApplicationFactory();
        launcher = factory.deploy(owner, manager);
        prepare = new PrepareHook();
    }

    function _configureAndPrepare() private returns (bytes32 salt, address predicted) {
        vm.prank(owner);
        launcher.setToken(address(token));
        bytes32 hash;
        (salt, predicted, hash) = prepare.runLauncher(launcher, 0, 1_000_000);
        assertEq(hash, keccak256(abi.encodePacked(type(DCAHook).creationCode, abi.encode(manager, address(token)))));
        assertEq(launcher.predictHook(salt), predicted);
        assertEq(uint160(predicted) & 0x3fff, 0x20cc);
    }

    function test_OrdinaryFactoryDeploysLauncherWithoutHookAddressConstraint() public view {
        assertTrue(uint160(address(launcher)) & 0x3fff != 0x20cc);
        assertEq(launcher.owner(), owner, "factory is not the owner");
        assertEq(address(launcher.poolManager()), address(manager));
        assertEq(launcher.token(), address(0), "configuration starts unset");
        assertEq(address(launcher.hook()), address(0));
        assertLe(address(launcher).code.length, 24_576);
    }

    function test_ConstructorWorksOnEmptyChainWithExplicitOwner() public {
        IPoolManager absentManager = IPoolManager(makeAddr("not deployed manager"));
        assertEq(address(absentManager).code.length, 0);
        DCAHookLauncher empty = factory.deploy(owner, absentManager);
        assertEq(empty.owner(), owner);
        assertEq(address(empty.poolManager()), address(absentManager));
        assertEq(address(empty.hook()), address(0));
    }

    function test_ConstructorRejectsMissingOwnerOrManager() public {
        vm.expectRevert(DCAHookLauncher.ZeroAddress.selector);
        factory.deploy(address(0), manager);
        vm.expectRevert(DCAHookLauncher.ZeroAddress.selector);
        factory.deploy(owner, IPoolManager(address(0)));
    }

    function test_UnconfiguredLauncherCannotPrepareOrLaunch() public {
        vm.expectRevert(DCAHookLauncher.TokenNotConfigured.selector);
        launcher.hookInitCodeHash();
        vm.expectRevert(DCAHookLauncher.TokenNotConfigured.selector);
        launcher.predictHook(bytes32(0));
        vm.expectRevert(DCAHookLauncher.TokenNotConfigured.selector);
        prepare.runLauncher(launcher, 0, 100);
        vm.expectRevert(DCAHookLauncher.TokenNotConfigured.selector);
        vm.prank(owner);
        launcher.launch(bytes32(0), Q96);
        vm.expectRevert(DCAHookLauncher.NotLaunched.selector);
        launcher.getPoolKey();
    }

    function test_OnlyRequesterCanConfigureOrLaunchNotEvenDeployingFactory() public {
        address[3] memory unauthorized = [address(this), address(factory), makeAddr("front runner")];
        for (uint256 i; i < unauthorized.length; ++i) {
            vm.expectRevert(DCAHookLauncher.Unauthorized.selector);
            vm.prank(unauthorized[i]);
            launcher.setToken(address(token));
            vm.expectRevert(DCAHookLauncher.Unauthorized.selector);
            vm.prank(unauthorized[i]);
            launcher.launch(bytes32(0), Q96);
        }
        assertEq(launcher.token(), address(0));
        assertEq(address(launcher.hook()), address(0));
    }

    function test_InvalidTokenConfigurationLeavesItUnset() public {
        vm.startPrank(owner);
        vm.expectRevert(DCAHookLauncher.ZeroAddress.selector);
        launcher.setToken(address(0));
        vm.expectRevert(DCAHookLauncher.InvalidToken.selector);
        launcher.setToken(FWA);
        vm.expectRevert(DCAHookLauncher.InvalidToken.selector);
        launcher.setToken(address(manager));
        vm.expectRevert(DCAHookLauncher.InvalidToken.selector);
        launcher.setToken(address(launcher));
        vm.stopPrank();
        assertEq(launcher.token(), address(0));
    }

    function test_TokenMayBeCorrectedBeforeLaunchAndNewHashIsUsed() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true, address(launcher));
        emit DCAHookLauncher.TokenConfigured(makeAddr("incorrect token"));
        launcher.setToken(makeAddr("incorrect token"));
        bytes32 oldHash = launcher.hookInitCodeHash();
        (bytes32 salt, address predicted) = _configureAndPrepare();
        assertNotEq(launcher.hookInitCodeHash(), oldHash);
        vm.prank(owner);
        DCAHook deployed = launcher.launch(salt, Q96);
        assertEq(address(deployed), predicted);
        assertEq(deployed.token(), address(token));
    }

    function test_DeploymentAndInitializationAreAtomicAndLeaveExistingSupplyUntouched() public {
        (bytes32 salt, address predicted) = _configureAndPrepare();
        uint256 supply = token.totalSupply();
        uint256 balance = token.balanceOf(address(this));
        PoolKey memory expectedKey = _key(predicted);
        vm.expectEmit(true, true, false, true, address(launcher));
        emit DCAHookLauncher.PoolLaunched(predicted, expectedKey.toId(), salt, Q96, 0);
        vm.prank(owner);
        DCAHook deployed = launcher.launch(salt, Q96);

        assertEq(address(deployed), predicted);
        assertEq(address(launcher.hook()), predicted);
        assertEq(deployed.launchFactory(), address(launcher));
        assertEq(deployed.token(), address(token));
        assertEq(deployed.FEE_BPS(), 500);
        assertEq(deployed.FEE_RECIPIENT(), 0xCAE0B01E56cB164ce866A137d3528658b2FCBd4b);
        assertEq(abi.encode(launcher.getPoolKey()), abi.encode(expectedKey));
        (uint160 price, int24 tick,, uint24 lpFee) = manager.getSlot0(deployed.poolId());
        assertEq(price, Q96);
        assertEq(tick, 0);
        assertEq(lpFee, 12_500, "mandatory fee preserved");
        assertEq(token.totalSupply(), supply);
        assertEq(token.balanceOf(address(this)), balance);
        assertEq(token.balanceOf(address(launcher)), 0);
        assertEq(token.balanceOf(predicted), 0);
    }

    function test_FrontRunnerCannotUsePublishedSaltOrChooseOpeningPrice() public {
        (bytes32 salt, address predicted) = _configureAndPrepare();
        vm.expectRevert(DCAHookLauncher.Unauthorized.selector);
        vm.prank(makeAddr("front runner"));
        launcher.launch(salt, Q96 + 1);
        assertEq(predicted.code.length, 0);
        assertEq(address(launcher.hook()), address(0));
        vm.prank(owner);
        launcher.launch(salt, Q96);
        (uint160 price,,,) = manager.getSlot0(_key(predicted).toId());
        assertEq(price, Q96);
    }

    function test_InvalidSaltRevertsWithoutDisablingRetry() public {
        (bytes32 goodSalt, address predicted) = _configureAndPrepare();
        bytes32 badSalt;
        address wrong;
        for (uint256 i;; ++i) {
            badSalt = bytes32(i);
            wrong = launcher.predictHook(badSalt);
            if ((uint160(wrong) & 0x3fff) != 0x20cc) break;
        }
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, wrong));
        vm.prank(owner);
        launcher.launch(badSalt, Q96);
        assertEq(wrong.code.length, 0);
        assertEq(address(launcher.hook()), address(0));
        assertEq(launcher.token(), address(token));
        vm.prank(owner);
        assertEq(address(launcher.launch(goodSalt, Q96)), predicted);
    }

    function test_InvalidPriceRollsBackChildAndPoolThenSameSaltCanRetry() public {
        (bytes32 salt, address predicted) = _configureAndPrepare();
        vm.expectRevert(abi.encodeWithSelector(TickMath.InvalidSqrtPrice.selector, uint160(0)));
        vm.prank(owner);
        launcher.launch(salt, 0);
        assertEq(address(launcher.hook()), address(0));
        assertEq(predicted.code.length, 0);
        (uint160 beforePrice,,,) = manager.getSlot0(_key(predicted).toId());
        assertEq(beforePrice, 0);
        vm.prank(owner);
        assertEq(address(launcher.launch(salt, Q96)), predicted);
    }

    function test_MissingManagerFailsAtFirstUseWithoutDeployingChild() public {
        IPoolManager absentManager = IPoolManager(makeAddr("not deployed manager"));
        DCAHookLauncher empty = factory.deploy(owner, absentManager);
        vm.prank(owner);
        empty.setToken(address(token));
        vm.expectRevert(abi.encodeWithSelector(DCAHookLauncher.ContractNotDeployed.selector, address(absentManager)));
        vm.prank(owner);
        empty.launch(bytes32(0), Q96);
        assertEq(address(empty.hook()), address(0));
    }

    function test_MissingTokenFailsAtFirstUseAndConfigurationCanBeFixed() public {
        address absentToken = makeAddr("not deployed token");
        vm.prank(owner);
        launcher.setToken(absentToken);
        vm.expectRevert(abi.encodeWithSelector(DCAHookLauncher.ContractNotDeployed.selector, absentToken));
        vm.prank(owner);
        launcher.launch(bytes32(0), Q96);
        assertEq(address(launcher.hook()), address(0));
        (bytes32 salt, address predicted) = _configureAndPrepare();
        vm.prank(owner);
        assertEq(address(launcher.launch(salt, Q96)), predicted);
    }

    function test_LaunchAndTokenConfigurationCannotRepeatAfterSuccess() public {
        (bytes32 salt, address predicted) = _configureAndPrepare();
        vm.prank(owner);
        launcher.launch(salt, Q96);
        vm.startPrank(owner);
        vm.expectRevert(DCAHookLauncher.AlreadyLaunched.selector);
        launcher.launch(salt, Q96);
        vm.expectRevert(DCAHookLauncher.AlreadyLaunched.selector);
        launcher.setToken(makeAddr("replacement token"));
        vm.stopPrank();
        assertEq(address(launcher.hook()), predicted);
        assertEq(launcher.token(), address(token));
    }

    function test_ExhaustedPreparationDoesNotChangeConfiguration() public {
        vm.prank(owner);
        launcher.setToken(address(token));
        vm.expectRevert(HookMiner.SaltNotFound.selector);
        prepare.runLauncher(launcher, 0, 0);
        assertEq(launcher.token(), address(token));
        assertEq(address(launcher.hook()), address(0));
    }

    function test_PreexistingUnhookedPoolIsDistinctAndDoesNotGainAFee() public {
        (bytes32 salt, address predicted) = _configureAndPrepare();
        PoolKey memory unhooked = _key(address(0));
        manager.initialize(unhooked, Q96 + 1);
        vm.prank(owner);
        DCAHook deployed = launcher.launch(salt, Q96);
        assertNotEq(PoolId.unwrap(unhooked.toId()), PoolId.unwrap(deployed.poolId()));
        (uint160 oldPrice,,,) = manager.getSlot0(unhooked.toId());
        (uint160 newPrice,,,) = manager.getSlot0(_key(predicted).toId());
        assertEq(oldPrice, Q96 + 1, "existing pool is not modified");
        assertEq(newPrice, Q96);
    }

    function test_AtomicActivationStartsUnconfiguredAndMintsNothing() public {
        bytes32 hash = launcher.hookInitCodeHashFor(address(token));
        assertEq(launcher.token(), address(0), "preparation does not configure");
        (bytes32 salt, address predicted) = HookMiner.find(address(launcher), hash, 0, 1_000_000);
        uint256 supply = token.totalSupply();
        uint256 deployerBalance = token.balanceOf(address(this));

        vm.expectEmit(true, false, false, true, address(launcher));
        emit DCAHookLauncher.TokenConfigured(address(token));
        vm.expectEmit(true, true, false, true, address(launcher));
        emit DCAHookLauncher.PoolLaunched(predicted, _key(predicted).toId(), salt, Q96, 0);
        vm.prank(owner);
        DCAHook deployed = launcher.launchWithToken(address(token), salt, Q96);

        assertEq(address(deployed), predicted);
        assertEq(launcher.token(), address(token));
        assertEq(launcher.hookInitCodeHash(), hash);
        assertEq(token.totalSupply(), supply);
        assertEq(token.balanceOf(address(this)), deployerBalance);
        assertEq(token.balanceOf(address(launcher)), 0);
        assertEq(token.balanceOf(predicted), 0);
        (uint160 price,,,) = manager.getSlot0(deployed.poolId());
        assertEq(price, Q96);
    }

    function test_AtomicActivationCommitsToTokenDespiteEarlierConfiguration() public {
        bytes32 hash = launcher.hookInitCodeHashFor(address(token));
        (bytes32 salt, address predicted) = HookMiner.find(address(launcher), hash, 0, 1_000_000);
        vm.prank(owner);
        launcher.setToken(makeAddr("stale setting"));
        vm.prank(owner);
        DCAHook deployed = launcher.launchWithToken(address(token), salt, Q96);
        assertEq(address(deployed), predicted);
        assertEq(deployed.token(), address(token));
        assertEq(launcher.token(), address(token));
    }

    function test_AtomicActivationFailureRestoresPriorSettingAndCanRetry() public {
        bytes32 hash = launcher.hookInitCodeHashFor(address(token));
        (bytes32 salt, address predicted) = HookMiner.find(address(launcher), hash, 0, 1_000_000);
        address previous = makeAddr("previous token setting");
        vm.prank(owner);
        launcher.setToken(previous);
        vm.expectRevert(abi.encodeWithSelector(TickMath.InvalidSqrtPrice.selector, uint160(0)));
        vm.prank(owner);
        launcher.launchWithToken(address(token), salt, 0);
        assertEq(launcher.token(), previous);
        assertEq(address(launcher.hook()), address(0));
        assertEq(predicted.code.length, 0);

        vm.prank(owner);
        launcher.launchWithToken(address(token), salt, Q96);
        assertEq(address(launcher.hook()), predicted);
        assertEq(launcher.token(), address(token));
    }

    function test_AtomicActivationUnauthorizedOrMissingCodeLeavesTokenUnset() public {
        vm.expectRevert(DCAHookLauncher.Unauthorized.selector);
        vm.prank(address(factory));
        launcher.launchWithToken(address(token), bytes32(0), Q96);
        address missing = makeAddr("missing token");
        vm.expectRevert(abi.encodeWithSelector(DCAHookLauncher.ContractNotDeployed.selector, missing));
        vm.prank(owner);
        launcher.launchWithToken(missing, bytes32(0), Q96);
        assertEq(launcher.token(), address(0));
        assertEq(address(launcher.hook()), address(0));
    }

    function test_AtomicActivationCannotReplaceLaunchedHook() public {
        (bytes32 salt, address predicted) = _configureAndPrepare();
        vm.prank(owner);
        launcher.launchWithToken(address(token), salt, Q96);
        vm.expectRevert(DCAHookLauncher.AlreadyLaunched.selector);
        vm.prank(owner);
        launcher.launchWithToken(makeAddr("replacement"), salt, Q96);
        assertEq(address(launcher.hook()), predicted);
        assertEq(launcher.token(), address(token));
    }

    function test_ExplicitTokenHashRejectsInvalidTokenWithoutChangingConfiguration() public {
        vm.expectRevert(DCAHookLauncher.ZeroAddress.selector);
        launcher.hookInitCodeHashFor(address(0));
        vm.expectRevert(DCAHookLauncher.InvalidToken.selector);
        launcher.hookInitCodeHashFor(FWA);
        vm.expectRevert(DCAHookLauncher.InvalidToken.selector);
        launcher.hookInitCodeHashFor(address(manager));
        vm.expectRevert(DCAHookLauncher.InvalidToken.selector);
        launcher.hookInitCodeHashFor(address(launcher));
        assertEq(launcher.token(), address(0));
    }

    function _key(address hookAddress) private view returns (PoolKey memory) {
        (address c0, address c1) = address(token) < FWA ? (address(token), FWA) : (FWA, address(token));
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), 12_500, 60, IHooks(hookAddress));
    }
}
