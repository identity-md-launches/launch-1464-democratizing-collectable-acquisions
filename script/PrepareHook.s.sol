// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DCAHook} from "../src/DCAHook.sol";
import {HookMiner} from "../src/HookMiner.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/// @notice Pure deployment preparation. No environment reads, keys, or broadcasting.
contract PrepareHook {
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
