// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Fixed-supply, untaxed ERC-20 for Democratizing Collectable Acquisions.
contract DCAToken is ERC20 {
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 1e18;

    /// @dev The launch factory is the deployer and receives the entire supply.
    constructor() ERC20("Democratizing Collectable Acquisions", "DCA") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
