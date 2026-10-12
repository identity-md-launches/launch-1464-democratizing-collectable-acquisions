// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PrepareLaunch} from "../script/PrepareLaunch.s.sol";
import {DCAHookLauncher} from "../src/DCAHookLauncher.sol";
import {DCAHook} from "../src/DCAHook.sol";
import {DCAToken} from "../src/DCAToken.sol";
import {HookMiner} from "../src/HookMiner.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {RestrictedFWA} from "./helpers/RestrictedFWA.sol";
import {PoolRouter} from "./helpers/PoolRouter.sol";

/// @dev Adds the preflight read ABI to the existing transfer-restricted test token.
contract LaunchFWAMock is RestrictedFWA {
    constructor(address manager_) RestrictedFWA(manager_) {}

    function symbol() public pure override returns (string memory) {
        return "FWA";
    }

    function poolManager() external view returns (address) {
        return manager;
    }

    function isDistributor(address account) external view returns (bool) {
        return account == manager;
    }
}

contract PrepareLaunchTest is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    address private constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address private constant FWA = 0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845;
    address private constant RECIPIENT = 0xCAE0B01E56cB164ce866A137d3528658b2FCBd4b;
    uint160 private constant Q96 = 79228162514264337593543950336;

    PrepareLaunch private prepare;
    DCAHookLauncher private launcher;
    DCAToken private token;
    IPoolManager private manager;
    LaunchFWAMock private fwa;
    address private owner;

    function setUp() public {
        vm.chainId(1);
        owner = makeAddr("requester owner");
        // Execute the real manager constructor at its test address, then install its returned runtime.
        // This preserves NoDelegateCall's immutable original address. No files or network are read.
        vm.etch(MANAGER, bytes.concat(type(PoolManager).creationCode, abi.encode(address(this))));
        (bool success, bytes memory runtime) = MANAGER.call("");
        require(success, "manager constructor failed");
        vm.etch(MANAGER, runtime);
        manager = IPoolManager(MANAGER);
        LaunchFWAMock implementation = new LaunchFWAMock(MANAGER);
        vm.etch(FWA, address(implementation).code);
        fwa = LaunchFWAMock(FWA);
        token = new DCAToken();
        launcher = new DCAHookLauncher(owner, manager);
        prepare = new PrepareLaunch();
    }

    function _plan() private view returns (PrepareLaunch.Activation memory) {
        return prepare.run(launcher, owner, address(token), Q96, 0, 1_000_000);
    }

    function _execute(PrepareLaunch.Activation memory plan) private returns (DCAHook hook) {
        vm.prank(plan.from);
        (bool success, bytes memory result) = plan.to.call(plan.data);
        require(success, "prepared transaction failed");
        hook = abi.decode(result, (DCAHook));
        assertEq(address(hook), plan.hook);
        assertEq(hook.token(), plan.token);
        assertEq(abi.encode(hook.getPoolKey()), abi.encode(plan.poolKey));
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(plan.poolId));
    }

    function test_PreparationIsReadOnlyAndReturnsExecutableOwnerTransaction() public {
        PrepareLaunch.Activation memory plan = _plan();
        assertEq(plan.chainId, 1);
        assertEq(plan.from, owner);
        assertEq(plan.to, address(launcher));
        assertEq(plan.token, address(token));
        assertEq(plan.sqrtPriceX96, Q96);
        assertEq(plan.initCodeHash, launcher.hookInitCodeHashFor(address(token)));
        assertEq(uint160(plan.hook) & 0x3fff, 0x20cc);
        assertEq(plan.data, abi.encodeCall(DCAHookLauncher.launchWithToken, (address(token), plan.salt, Q96)));
        assertEq(launcher.token(), address(0));
        assertEq(address(launcher.hook()), address(0));
        assertEq(plan.hook.code.length, 0);
        uint256 deployerBalance = token.balanceOf(address(this));
        _execute(plan);
        (uint160 price,,, uint24 fee) = manager.getSlot0(plan.poolId);
        assertEq(price, Q96);
        assertEq(fee, 12_500);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), deployerBalance);
        assertEq(token.balanceOf(plan.to), 0);
        assertEq(token.balanceOf(plan.hook), 0);
    }

    function test_PreparedActivationBuySellAndPayoutForBothTokenOrderings() public {
        for (uint256 i; i < 2; ++i) {
            DCAToken orderedToken = _orderedToken(i == 1);
            DCAHookLauncher orderedLauncher = new DCAHookLauncher(owner, manager);
            PrepareLaunch.Activation memory plan =
                prepare.run(orderedLauncher, owner, address(orderedToken), Q96, 0, 1_000_000);
            DCAHook hook = _execute(plan);
            _tradeAndClaim(orderedToken, hook, plan.poolKey);
        }
    }

    function _tradeAndClaim(DCAToken orderedToken, DCAHook hook, PoolKey memory key) private {
        PoolRouter trader = new PoolRouter(manager);
        orderedToken.transfer(address(trader), 10_000_000 ether);
        fwa.mint(address(trader), 1e30);
        trader.liquidity(key, -60_000, 60_000, 1e24);
        assertEq(hook.pendingFees(), 0, "liquidity is untaxed");
        bool fwaFirst = Currency.unwrap(key.currency0) == FWA;

        uint256 beforeFwa = fwa.balanceOf(address(trader));
        BalanceDelta buy = trader.swap(key, _params(fwaFirst, -100 ether));
        assertEq(fwa.balanceOf(address(trader)), beforeFwa - 100 ether);
        assertGt(fwaFirst ? buy.amount1() : buy.amount0(), 0, "buyer receives DCA");
        assertEq(hook.pendingFees(), 5 ether, "5% of buyer's FWA input");

        BalanceDelta sell = trader.swap(key, _params(!fwaFirst, -50 ether));
        uint256 netFwa = uint256(int256(fwaFirst ? sell.amount0() : sell.amount1()));
        uint256 sellFee = hook.pendingFees() - 5 ether;
        assertGt(sellFee, 0);
        assertEq(sellFee, (netFwa + sellFee) / 20, "5% of gross FWA output");

        uint256 pending = hook.pendingFees();
        uint256 recipientBefore = fwa.balanceOf(RECIPIENT);
        fwa.rejectRecipient(RECIPIENT);
        vm.expectRevert();
        hook.claimFees();
        assertEq(hook.pendingFees(), pending, "failed payout preserves fees");
        assertEq(fwa.balanceOf(RECIPIENT), recipientBefore);
        fwa.rejectRecipient(address(0));
        address keeper = makeAddr("permissionless keeper");
        vm.prank(keeper);
        assertEq(hook.claimFees(), pending);
        assertEq(fwa.balanceOf(RECIPIENT), recipientBefore + pending);
        assertEq(fwa.balanceOf(keeper), 0);
        assertEq(hook.pendingFees(), 0);
        assertEq(fwa.balanceOf(address(hook)), 0, "FWA never held directly by hook");
        assertEq(orderedToken.totalSupply(), 1_000_000_000 ether);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
    }

    function _orderedToken(bool fwaFirst) private returns (DCAToken) {
        bytes32 hash = keccak256(type(DCAToken).creationCode);
        for (uint256 i; i < 100; ++i) {
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), hash)))));
            if ((FWA < predicted) == fwaFirst) return new DCAToken{salt: bytes32(i)}();
        }
        revert("token address search exhausted");
    }

    function _params(bool zeroForOne, int256 amount) private pure returns (SwapParams memory) {
        return SwapParams(zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }

    function test_PreparationDoesNotDependOnCallerAndSignedTokenOverridesStaleSetting() public {
        PrepareLaunch.Activation memory first = _plan();
        vm.prank(makeAddr("unrelated simulator"));
        PrepareLaunch.Activation memory second = prepare.run(launcher, owner, address(token), Q96, 0, 1_000_000);
        assertEq(abi.encode(first), abi.encode(second));
        vm.prank(owner);
        launcher.setToken(makeAddr("outdated setting"));
        _execute(first);
        assertEq(launcher.token(), address(token));
    }

    function test_PreparationRejectsWrongChain() public {
        vm.chainId(8453);
        vm.expectRevert(abi.encodeWithSelector(PrepareLaunch.WrongChain.selector, uint256(8453)));
        _plan();
    }

    function test_PreparationRejectsWrongOwnerIncludingFactory() public {
        vm.expectRevert(abi.encodeWithSelector(PrepareLaunch.WrongOwner.selector, owner, address(this)));
        prepare.run(launcher, address(this), address(token), Q96, 0, 1_000_000);
        vm.expectRevert(abi.encodeWithSelector(PrepareLaunch.WrongOwner.selector, owner, address(0)));
        prepare.run(launcher, address(0), address(token), Q96, 0, 1_000_000);
    }

    function test_PreparationRejectsNoncanonicalManager() public {
        address other = makeAddr("other manager");
        DCAHookLauncher wrong = new DCAHookLauncher(owner, IPoolManager(other));
        vm.expectRevert(abi.encodeWithSelector(PrepareLaunch.WrongManager.selector, other));
        prepare.run(wrong, owner, address(token), Q96, 0, 1_000_000);
    }

    function test_PreparationRejectsMissingContracts() public {
        address[4] memory required = [address(launcher), MANAGER, FWA, address(token)];
        for (uint256 i; i < required.length; ++i) {
            bytes memory code = required[i].code;
            vm.etch(required[i], "");
            vm.expectRevert(abi.encodeWithSelector(PrepareLaunch.ContractNotDeployed.selector, required[i]));
            _plan();
            vm.etch(required[i], code);
        }
    }

    function test_PreparationRejectsInvalidPriceBounds() public {
        uint160[3] memory invalidPrices = [uint160(0), TickMath.MIN_SQRT_PRICE - 1, TickMath.MAX_SQRT_PRICE];
        for (uint256 i; i < invalidPrices.length; ++i) {
            vm.expectRevert(PrepareLaunch.InvalidOpeningPrice.selector);
            prepare.run(launcher, owner, address(token), invalidPrices[i], 0, 1_000_000);
        }
    }

    function test_PreparationRejectsWrongTokenMetadataAndSupply() public {
        bytes[4] memory selectors = [
            abi.encodeWithSignature("name()"),
            abi.encodeWithSignature("symbol()"),
            abi.encodeWithSignature("decimals()"),
            abi.encodeWithSignature("totalSupply()")
        ];
        bytes[4] memory wrongValues =
            [abi.encode("another name"), abi.encode("OTHER"), abi.encode(uint8(6)), abi.encode(uint256(1 ether))];
        for (uint256 i; i < selectors.length; ++i) {
            vm.mockCall(address(token), selectors[i], wrongValues[i]);
            vm.expectRevert(PrepareLaunch.InvalidDCAToken.selector);
            _plan();
            vm.clearMockedCalls();
        }
    }

    function test_PreparationRejectsIncompatibleFwaAndRevokedDistributor() public {
        bytes[4] memory selectors = [
            abi.encodeWithSignature("symbol()"),
            abi.encodeWithSignature("decimals()"),
            abi.encodeWithSignature("poolManager()"),
            abi.encodeWithSignature("isDistributor(address)", MANAGER)
        ];
        bytes[4] memory wrongValues =
            [abi.encode("OTHER"), abi.encode(uint8(6)), abi.encode(makeAddr("wrong fwa manager")), abi.encode(false)];
        for (uint256 i; i < selectors.length; ++i) {
            vm.mockCall(FWA, selectors[i], wrongValues[i]);
            vm.expectRevert(PrepareLaunch.InvalidFWAConfiguration.selector);
            _plan();
            vm.clearMockedCalls();
        }
    }

    function test_PreparationRejectsActivatedLauncher() public {
        _execute(_plan());
        vm.expectRevert(PrepareLaunch.AlreadyLaunched.selector);
        _plan();
    }

    function test_PreparationRejectsOccupiedHookAddress() public {
        PrepareLaunch.Activation memory plan = _plan();
        vm.etch(plan.hook, hex"00");
        vm.expectRevert(abi.encodeWithSelector(PrepareLaunch.HookAddressOccupied.selector, plan.hook));
        _plan();
        assertEq(launcher.token(), address(0));
    }

    function test_ExhaustedSearchLeavesLauncherUnconfigured() public {
        vm.expectRevert(HookMiner.SaltNotFound.selector);
        prepare.run(launcher, owner, address(token), Q96, 0, 0);
        assertEq(launcher.token(), address(0));
        assertEq(address(launcher.hook()), address(0));
    }
}
