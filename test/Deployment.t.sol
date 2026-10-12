// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DCAToken} from "../src/DCAToken.sol";
import {DCAHook} from "../src/DCAHook.sol";
import {HookMiner} from "../src/HookMiner.sol";
import {PrepareHook} from "../script/PrepareHook.s.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

contract HookFactoryProbe {
    function deploy(IPoolManager manager, address token, bytes32 salt) external returns (DCAHook) {
        return new DCAHook{salt: salt}(manager, token);
    }
}

contract DeploymentTest is Test {
    address internal constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    function test_PreparationDeploysExactPredictedAddressOnEmptyChain() public {
        PrepareHook prepare = new PrepareHook();
        HookFactoryProbe factory = new HookFactoryProbe();
        DCAToken token = new DCAToken();
        assertEq(MANAGER.code.length, 0);
        (bytes32 salt, address expected, bytes32 hash) = prepare.run(address(factory), address(token), 0, 1_000_000);
        assertEq(hash, keccak256(abi.encodePacked(type(DCAHook).creationCode, abi.encode(MANAGER, address(token)))));
        DCAHook hook = factory.deploy(IPoolManager(MANAGER), address(token), salt);
        assertEq(address(hook), expected);
        assertEq(address(hook.poolManager()), MANAGER);
        assertEq(hook.launchFactory(), address(factory));
        assertEq(hook.token(), address(token));
        assertEq(token.balanceOf(address(this)), 1_000_000_000 ether, "hook constructor never moves tokens");
        assertEq(uint160(expected) & 0x3fff, 0x20cc);
        assertLe(address(hook).code.length, 24_576);
        _checkOpcodes(address(token).code);
        _checkOpcodes(address(hook).code);
    }

    function test_NoExternalCallsEvenIfTokenIsNotYetDeployed() public {
        address token = makeAddr("future token");
        HookFactoryProbe factory = new HookFactoryProbe();
        PrepareHook prepare = new PrepareHook();
        (bytes32 salt,,) = prepare.run(address(factory), token, 0, 1_000_000);
        assertEq(token.code.length, 0);
        assertEq(MANAGER.code.length, 0);
        DCAHook hook = factory.deploy(IPoolManager(MANAGER), token, salt);
        assertEq(hook.token(), token);
    }

    function test_WrongHookAddressBitsAreRejected() public {
        address token = makeAddr("token");
        HookFactoryProbe factory = new HookFactoryProbe();
        bytes32 hash = keccak256(abi.encodePacked(type(DCAHook).creationCode, abi.encode(MANAGER, token)));
        bytes32 salt;
        address predicted;
        for (uint256 i;; ++i) {
            salt = bytes32(i);
            predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, hash)))));
            if (uint160(predicted) & 0x3fff != 0x20cc) break;
        }
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        factory.deploy(IPoolManager(MANAGER), token, salt);
    }

    function test_InvalidConstructorArgumentsRevert() public {
        vm.expectRevert(DCAHook.ZeroAddress.selector);
        new DCAHook(IPoolManager(address(0)), makeAddr("token"));
        vm.expectRevert(DCAHook.ZeroAddress.selector);
        new DCAHook(IPoolManager(MANAGER), address(0));
        vm.expectRevert(DCAHook.InvalidToken.selector);
        new DCAHook(IPoolManager(MANAGER), MANAGER);
        vm.expectRevert(DCAHook.InvalidToken.selector);
        new DCAHook(IPoolManager(MANAGER), 0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845);
    }

    function test_PreparationRejectsMissingAddressesAndExhaustedSearch() public {
        PrepareHook prepare = new PrepareHook();
        vm.expectRevert("factory and token required");
        prepare.run(address(0), address(this), 0, 1);
        vm.expectRevert("factory and token required");
        prepare.run(address(this), address(0), 0, 1);
        vm.expectRevert(HookMiner.SaltNotFound.selector);
        prepare.run(address(this), makeAddr("token"), 0, 0);
    }

    function _checkOpcodes(bytes memory code) private pure {
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }
}
