// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Off-chain CREATE2 salt preparation; all library code is inlined.
library HookMiner {
    error SaltNotFound();

    function find(address deployer, bytes32 initCodeHash, uint256 start, uint256 attempts)
        internal
        pure
        returns (bytes32 salt, address predicted)
    {
        for (uint256 i; i < attempts; ++i) {
            salt = bytes32(start + i);
            predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
            if ((uint160(predicted) & 0x3fff) == 0x20cc) return (salt, predicted);
        }
        revert SaltNotFound();
    }
}
