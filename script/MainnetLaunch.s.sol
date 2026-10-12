// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DCAMainnetLauncher} from "../src/DCAMainnetLauncher.sol";
import {HookMiner} from "../src/HookMiner.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

interface IFWAMainnetRead is IERC20Metadata {
    function poolManager() external view returns (address);
    function isDistributor(address account) external view returns (bool);
}

/// @notice Ethereum mainnet launch configuration and read-only launch preparation for DCA/FWA.
/// @dev No environment reads, keys, broadcasting, or token movements. The operator signs both
/// transactions it describes with their own wallet.
contract MainnetLaunch {
    uint256 public constant CHAIN_ID = 1;
    /// @notice Operator and signer named by the requester: owns the launcher and receives the 12% remainder.
    address public constant OPERATOR = 0x1EE3ffadfE138415A2ddaedeEBe5F46616fA413d;
    address public constant FEE_RECIPIENT = 0xCAE0B01E56cB164ce866A137d3528658b2FCBd4b;
    address public constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address public constant FWA = 0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845;

    struct Launch {
        uint256 chainId;
        address from;
        address to;
        bytes data;
        bytes32 salt;
        address token;
        address hook;
        PoolKey poolKey;
        PoolId poolId;
        uint160 sqrtPriceX96;
        int24 tick;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 pooled;
        uint256 toOperator;
    }

    error WrongChain(uint256 actual);
    error ContractNotDeployed(address account);
    error WrongOwner(address actual);
    error WrongManager(address actual);
    error AlreadyLaunched();
    error AddressOccupied(address account);
    error InvalidFWAConfiguration();

    /// @notice Constructor arguments for DCAMainnetLauncher: (OPERATOR, MANAGER).
    function constructorArgs() public pure returns (address owner, IPoolManager poolManager) {
        return (OPERATOR, IPoolManager(MANAGER));
    }

    /// @notice Deploys the launcher with the mainnet configuration from the calling account.
    /// @dev Ownership is explicit; it does not depend on who sends the deployment.
    function deploy() public returns (DCAMainnetLauncher launcher) {
        (address owner, IPoolManager poolManager) = constructorArgs();
        launcher = new DCAMainnetLauncher(owner, poolManager);
    }

    /// @notice Read-only preflight: checks the deployed launcher and FWA, mines the hook salt and
    /// returns the zero-value `launch` transaction OPERATOR must sign.
    function prepare(DCAMainnetLauncher launcher, uint256 start, uint256 attempts)
        external
        view
        returns (Launch memory plan)
    {
        if (block.chainid != CHAIN_ID) revert WrongChain(block.chainid);
        _requireCode(address(launcher));
        if (launcher.owner() != OPERATOR) revert WrongOwner(launcher.owner());
        if (address(launcher.poolManager()) != MANAGER) revert WrongManager(address(launcher.poolManager()));
        if (address(launcher.hook()) != address(0)) revert AlreadyLaunched();
        _requireCode(MANAGER);
        _requireCode(FWA);
        IFWAMainnetRead fwa = IFWAMainnetRead(FWA);
        if (
            keccak256(bytes(fwa.symbol())) != keccak256("FWA") || fwa.decimals() != 18 || fwa.poolManager() != MANAGER
                || !fwa.isDistributor(MANAGER)
        ) revert InvalidFWAConfiguration();

        plan.chainId = block.chainid;
        plan.from = OPERATOR;
        plan.to = address(launcher);
        plan.token = launcher.predictToken();
        if (plan.token.code.length != 0) revert AddressOccupied(plan.token);
        (plan.salt, plan.hook) = HookMiner.find(address(launcher), launcher.hookInitCodeHash(), start, attempts);
        if (plan.hook.code.length != 0) revert AddressOccupied(plan.hook);
        plan.data = abi.encodeCall(DCAMainnetLauncher.launch, (plan.salt));

        bool dcaIs0 = plan.token < FWA;
        (address c0, address c1) = dcaIs0 ? (plan.token, FWA) : (FWA, plan.token);
        plan.poolKey = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 12_500, 60, IHooks(plan.hook));
        plan.poolId = plan.poolKey.toId();
        plan.sqrtPriceX96 = launcher.openingSqrtPriceX96(dcaIs0);
        plan.tick = TickMath.getTickAtSqrtPrice(plan.sqrtPriceX96);
        (plan.tickLower, plan.tickUpper) = launcher.positionRange(plan.tick, dcaIs0);
        plan.liquidity = launcher.liquidityFor(plan.tickLower, plan.tickUpper, dcaIs0);
        plan.pooled = launcher.pooledAmount(plan.tickLower, plan.tickUpper, plan.liquidity, dcaIs0);
        plan.toOperator = launcher.TOTAL_SUPPLY() - plan.pooled;
    }

    function _requireCode(address account) private view {
        if (account.code.length == 0) revert ContractNotDeployed(account);
    }
}
