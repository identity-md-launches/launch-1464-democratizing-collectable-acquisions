// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DCAHookLauncher} from "../src/DCAHookLauncher.sol";
import {HookMiner} from "../src/HookMiner.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

interface IFWALaunchRead is IERC20Metadata {
    function poolManager() external view returns (address);
    function isDistributor(address account) external view returns (bool);
}

/// @notice Read-only mainnet preflight and transaction preparation for the DCA/FWA pool.
/// @dev No environment reads, keys, broadcasting, deployment, or token movements.
contract PrepareLaunch {
    address public constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address public constant FWA = 0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845;

    struct Activation {
        uint256 chainId;
        address from;
        address to;
        address token;
        uint160 sqrtPriceX96;
        bytes32 salt;
        address hook;
        bytes32 initCodeHash;
        PoolKey poolKey;
        PoolId poolId;
        bytes data;
    }

    error WrongChain(uint256 actual);
    error ContractNotDeployed(address account);
    error WrongOwner(address actual, address expected);
    error WrongManager(address actual);
    error AlreadyLaunched();
    error InvalidOpeningPrice();
    error InvalidDCAToken();
    error InvalidFWAConfiguration();
    error HookAddressOccupied(address account);

    /// @param expectedOwner The requester owner from the reviewed deployment record.
    /// @param existingToken The project's actual token address; never a replacement deployment.
    /// @param sqrtPriceX96 Reviewed sqrt(currency1 / currency0) * 2**96, in base units.
    /// @dev The returned transaction has zero ETH value. Token selection and activation are atomic.
    function run(
        DCAHookLauncher launcher,
        address expectedOwner,
        address existingToken,
        uint160 sqrtPriceX96,
        uint256 start,
        uint256 attempts
    ) external view returns (Activation memory plan) {
        if (block.chainid != 1) revert WrongChain(block.chainid);
        _requireCode(address(launcher));
        if (launcher.owner() != expectedOwner || expectedOwner == address(0)) {
            revert WrongOwner(launcher.owner(), expectedOwner);
        }
        if (address(launcher.hook()) != address(0)) revert AlreadyLaunched();
        if (address(launcher.poolManager()) != MANAGER) revert WrongManager(address(launcher.poolManager()));
        if (sqrtPriceX96 < TickMath.MIN_SQRT_PRICE || sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) {
            revert InvalidOpeningPrice();
        }
        _requireCode(MANAGER);
        _requireCode(FWA);
        _requireCode(existingToken);
        _checkTokens(existingToken);

        plan.chainId = block.chainid;
        plan.from = expectedOwner;
        plan.to = address(launcher);
        plan.token = existingToken;
        plan.sqrtPriceX96 = sqrtPriceX96;
        plan.initCodeHash = launcher.hookInitCodeHashFor(existingToken);
        (plan.salt, plan.hook) = HookMiner.find(address(launcher), plan.initCodeHash, start, attempts);
        if (plan.hook.code.length != 0) revert HookAddressOccupied(plan.hook);
        (address c0, address c1) = existingToken < FWA ? (existingToken, FWA) : (FWA, existingToken);
        plan.poolKey = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 12_500, 60, IHooks(plan.hook));
        plan.poolId = plan.poolKey.toId();
        plan.data = abi.encodeCall(DCAHookLauncher.launchWithToken, (existingToken, plan.salt, sqrtPriceX96));
    }

    function _checkTokens(address existingToken) private view {
        IERC20Metadata dca = IERC20Metadata(existingToken);
        if (
            keccak256(bytes(dca.name())) != keccak256("Democratizing Collectable Acquisions")
                || keccak256(bytes(dca.symbol())) != keccak256("DCA") || dca.decimals() != 18
                || dca.totalSupply() != 1_000_000_000 ether
        ) revert InvalidDCAToken();

        IFWALaunchRead fwa = IFWALaunchRead(FWA);
        if (
            keccak256(bytes(fwa.symbol())) != keccak256("FWA") || fwa.decimals() != 18 || fwa.poolManager() != MANAGER
                || !fwa.isDistributor(MANAGER)
        ) revert InvalidFWAConfiguration();
    }

    function _requireCode(address account) private view {
        if (account.code.length == 0) revert ContractNotDeployed(account);
    }
}
