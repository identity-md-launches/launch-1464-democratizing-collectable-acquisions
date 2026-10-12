// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Test-only model of FWA's restricted transfers, plus adversarial payout behavior.
contract RestrictedFWA is ERC20 {
    address public immutable manager;
    address public rejectedRecipient;
    address public reentryTarget;
    bool public reentryAttempted;
    bool public reentrySucceeded;
    bytes public reentryResult;

    error InvalidTransfer();
    error PayoutRejected();

    constructor(address manager_) ERC20("Restricted FWA mock", "FWA") {
        manager = manager_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function rejectRecipient(address recipient) external {
        rejectedRecipient = recipient;
    }

    function setReentry(address target) external {
        reentryTarget = target;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0) && from != manager && to != manager) revert InvalidTransfer();
        if (to != address(0) && to == rejectedRecipient) revert PayoutRejected();
        super._update(from, to, amount);
        if (from == manager && reentryTarget != address(0)) {
            reentryAttempted = true;
            (reentrySucceeded, reentryResult) = reentryTarget.call(abi.encodeWithSignature("claimFees()"));
        }
    }
}
