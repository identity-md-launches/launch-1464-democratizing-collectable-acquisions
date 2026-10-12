// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DCAHook} from "../src/DCAHook.sol";
import {HookMiner} from "../src/HookMiner.sol";
import {DCAHookLauncher} from "../src/DCAHookLauncher.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/// @notice Pure deployment preparation. No environment reads, keys, or broadcasting.
contract PrepareHook {
    /// @notice Prepare an already configured launcher, using its actual manager/token and bytecode hash.
    function runLauncher(DCAHookLauncher launcher, uint256 start, uint256 attempts)
        external
        view
        returns (bytes32 salt, address hook, bytes32 initCodeHash)
    {
        initCodeHash = launcher.hookInitCodeHash();
        (salt, hook) = HookMiner.find(address(launcher), initCodeHash, start, attempts);
    }

    function run(address factory, address token, uint256 start, uint256 attempts)
        external
        pure
        returns (bytes32 salt, address hook, bytes32 initCodeHash)
    {
        require(factory != address(0) && token != address(0), "factory and token required");
        IPoolManager manager = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
        initCodeHash = keccak256(abi.encodePacked(type(DCAHook).creationCode, abi.encode(manager, token)));
        (salt, hook) = HookMiner.find(factory, initCodeHash, start, attempts);
    }
}
