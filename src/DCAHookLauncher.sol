// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DCAHook} from "./DCAHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

/// @notice Deploys and initializes the fixed 5% FWA hook pool for an existing DCA token.
/// @dev The launcher itself needs no special address bits. Mine the child's salt off-chain.
/// No token is deployed, minted, transferred, or approved by this contract.
contract DCAHookLauncher {
    address private constant FWA = 0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845;

    address public immutable owner;
    IPoolManager public immutable poolManager;

    address public token;
    DCAHook public hook;

    error ZeroAddress();
    error Unauthorized();
    error InvalidToken();
    error TokenNotConfigured();
    error ContractNotDeployed(address account);
    error AlreadyLaunched();
    error NotLaunched();

    event TokenConfigured(address indexed token);
    event PoolLaunched(address indexed hook, PoolId indexed poolId, bytes32 salt, uint160 sqrtPriceX96);

    /// @param owner_ The requester's launch owner, supplied explicitly (never the deploying factory).
    /// @param poolManager_ The canonical PoolManager on the launch chain.
    /// @dev Makes no external calls or code checks; ordinary CREATE/CREATE2 deployment is supported.
    constructor(address owner_, IPoolManager poolManager_) {
        if (owner_ == address(0) || address(poolManager_) == address(0)) revert ZeroAddress();
        owner = owner_;
        poolManager = poolManager_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    /// @notice Select the existing project token. Configuration freezes after a successful launch.
    function setToken(address token_) external onlyOwner {
        _setToken(token_);
    }

    function _setToken(address token_) private {
        if (address(hook) != address(0)) revert AlreadyLaunched();
        _checkToken(token_);
        token = token_;
        emit TokenConfigured(token_);
    }

    function _checkToken(address token_) private view {
        if (token_ == address(0)) revert ZeroAddress();
        if (token_ == FWA || token_ == address(poolManager) || token_ == address(this)) revert InvalidToken();
    }

    /// @notice Hash to use when mining the hook salt with this launcher as CREATE2 deployer.
    function hookInitCodeHash() public view returns (bytes32) {
        if (token == address(0)) revert TokenNotConfigured();
        return hookInitCodeHashFor(token);
    }

    /// @notice Prepare activation without first sending a token-configuration transaction.
    /// @dev Uses this launcher's embedded child code. Does not change the configured token.
    function hookInitCodeHashFor(address token_) public view returns (bytes32) {
        _checkToken(token_);
        return keccak256(bytes.concat(type(DCAHook).creationCode, abi.encode(poolManager, token_)));
    }

    function predictHook(bytes32 salt) external view returns (address) {
        return
            address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hookInitCodeHash()))))
            );
    }

    /// @notice Deploy the mined hook and initialize its pool at the owner's chosen opening price.
    /// @dev A bad salt, invalid price, or manager failure rolls back deployment and leaves this retryable.
    /// Initialization comes from this launcher, which is also the child's immutable launchFactory.
    /// This initializes a new pool; it cannot change the hook of an existing pool.
    function launch(bytes32 salt, uint160 sqrtPriceX96) external onlyOwner returns (DCAHook deployed) {
        return _launch(salt, sqrtPriceX96);
    }

    /// @notice Select the existing token, deploy its hook, and initialize its pool atomically.
    /// @dev The signed call commits to the token as well as the salt and opening price.
    /// Any failure also restores the previous token setting. No token is deployed or minted.
    function launchWithToken(address token_, bytes32 salt, uint160 sqrtPriceX96)
        external
        onlyOwner
        returns (DCAHook deployed)
    {
        _setToken(token_);
        return _launch(salt, sqrtPriceX96);
    }

    function _launch(bytes32 salt, uint160 sqrtPriceX96) private returns (DCAHook deployed) {
        if (address(hook) != address(0)) revert AlreadyLaunched();
        address configuredToken = token;
        if (configuredToken == address(0)) revert TokenNotConfigured();
        if (address(poolManager).code.length == 0) revert ContractNotDeployed(address(poolManager));
        if (configuredToken.code.length == 0) revert ContractNotDeployed(configuredToken);

        deployed = new DCAHook{salt: salt}(poolManager, configuredToken);
        // Freeze configuration before calling the manager. The child's constructor calls no contracts.
        hook = deployed;
        poolManager.initialize(deployed.getPoolKey(), sqrtPriceX96);
        emit PoolLaunched(address(deployed), deployed.poolId(), salt, sqrtPriceX96);
    }

    /// @notice The initialized pool key to use for liquidity provisioning, quotes, and swaps.
    function getPoolKey() external view returns (PoolKey memory) {
        DCAHook deployed = hook;
        if (address(deployed) == address(0)) revert NotLaunched();
        return deployed.getPoolKey();
    }
}
