# Democratizing Collectable Acquisions (DCA)

An immutable, fixed-supply ERC-20 and a Uniswap v4 launch-pool hook. The hook charges 5% exclusively in FWA on buys and sells, in addition to the mandatory 1.25% pool fee. Wallet-to-wallet DCA transfers have no tax.

This source repair adds `DCAHookLauncher`, an application that can be deployed at an ordinary address and then deploys the correctly addressed hook and initializes its pool atomically. The previous source already calculated 5%, but direct application deployment of `DCAHook` failed unless the deploying factory mined its address. The launcher moves that CREATE2 deployment into the delivered source. It uses the **existing DCA token**; it never deploys a token or changes its supply. No on-chain transactions are performed by this assignment.

The fee becomes effective only for swaps using the pool returned by the launcher. Deploying the launcher alone does not activate it, and it cannot add a hook to a previously initialized pool. The launch operator must configure, activate, fund, and select this hooked pool as described below.

## Build and verification

Run from the repository root with Foundry and Solidity 0.8.26 installed:

```sh
forge build
forge test
forge fmt --check
```

`foundry.toml` pins Solidity 0.8.26, Cancun, optimizer settings, and `bytecode_hash = "none"`. All required Solidity dependencies are ordinary files in `lib/`; no dependency installation, network, environment variables, keys, FFI, or filesystem cheatcodes are needed to build or test. Exact dependency commits and retained files are recorded in `DEPENDENCIES.json`, with upstream licenses alongside them.

Tests use the actual vendored Uniswap v4 `PoolManager` and a restricted FWA mock at FWA's canonical address. Their shared setup deploys and initializes through the production launcher. They exercise both address orderings, compare all four swap modes against an equivalent pool without the hook, test single-sided seeding and the first buy, and check fee custody and payout failures. Stateful invariant tests check conservation of both tokens, fees, and settled manager deltas across random swaps and claims. Launcher tests cover ordinary factory deployment, explicit ownership, missing configuration/contracts, invalid salts/prices, atomic rollback/retry, and one-time activation. No mainnet fork or live transaction is used.

## Contracts

| Contract | Constructor arguments | Behavior |
| --- | --- | --- |
| `DCAToken` | None | Name `Democratizing Collectable Acquisions`, symbol `DCA`, 18 decimals; mints exactly 1,000,000,000 DCA to its deployer once. |
| `DCAHook` | `IPoolManager poolManager_`, `address token_` | Fixed pool and fee; accrues FWA claims and permits anyone to trigger payment to the fixed recipient. |
| `DCAHookLauncher` | `address owner_`, `IPoolManager poolManager_` | Ordinary-address application; the owner sets the existing token, then deploys the mined hook and initializes its pool in one call. |

The token supply in base units is `1000000000000000000000000000`. Its original factory received it in the constructor and handled allocations; this follow-up must not repeat that deployment. The token and hook have no owner, upgrade, pause, blacklist, privileged balance movement, or future mint function. The hook constructor neither calls external contracts nor takes any token allocation. With the new path, its `launchFactory` is the launcher, which is the sole caller permitted to initialize its fixed pool.

The launcher has an explicit, immutable requester owner, supplied as `$owner` by the separate launch manifest step. Its deploying application factory receives no ownership rights. The owner can correct the token setting before activation and choose the initial price, but cannot alter the hook's fee, recipient, or pool parameters. Token configuration and activation are permanently disabled after successful activation. The launcher never holds launch allocations, approves assets, routes swaps, or manages liquidity. All constructors make no external calls or code checks; activation checks that the manager and configured token have code.

`HookMiner` is an internal library, and `PrepareHook` is an off-chain preparation script; neither is a launch application. No library linking is required.

## Pool and immutable parameters

| Parameter | Value |
| --- | --- |
| Chain | Ethereum mainnet, chain ID 1 |
| FWA | `0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845` (18 decimals) |
| PoolManager constructor argument to launcher | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| Launcher owner constructor argument | Requester's `$owner`; never the application factory or IMD's launch wallet |
| DCA setting passed to hook | Existing project's `DCAToken` address, configured with `setToken` |
| Fee recipient | `0xCAE0B01E56cB164ce866A137d3528658b2FCBd4b` |
| Hook fee | 500 basis points (5%), immutable |
| Pool fee | `12500` millionths (1.25%), static |
| Tick spacing | `60` |
| Hook address low bits | `address & 0x3fff == 0x20cc` |

`getPoolKey()` sorts DCA and FWA by address and includes this hook, the mandatory fee, and tick spacing. The immutable `poolId` binds all hook callbacks to this exact key. Other pairs, fee tiers, tick spacings, and hook addresses are rejected. Dynamic pool fees are rejected. The hook never overrides the pool fee.

The flags `0x20cc` enable `beforeInitialize`, `beforeSwap`, `afterSwap`, and both swap-return-delta permissions. Unused callbacks are disabled. Hook construction rejects an address with different flags. The launcher itself has no address-bit requirement and must never be used as `PoolKey.hooks`.

## Fee arithmetic and swap behavior

All arithmetic uses integer FWA base units. For gross FWA `G`, the hook fee is `floor(G / 20)` and the remaining amount is `G - floor(G / 20)`. Thus amounts below 20 base units round to zero fee. Repeated tiny trades also round individually.

| Swap | FWA fee treatment |
| --- | --- |
| Buy, exact input | The specified FWA budget includes the hook fee. The hook deducts 5% before the pool swap. |
| Buy, exact output | The hook grosses up the actual FWA input required by the pool, so 5% of the buyer's total FWA payment is retained. |
| Sell, exact input | The hook deducts 5% from the actual gross FWA output. |
| Sell, exact output | The requested FWA output is net of the hook fee. The pool is asked for enough gross FWA to satisfy it. |

For a given net FWA amount `N > 0`, `feeOnNet(N) = floor((N - 1) / 19)` selects the smallest gross amount `N + fee` satisfying the same rounded 5% rule. This can differ by one base unit from a naive gross-up. `feeOnGross` and `feeOnNet` expose the arithmetic for integrators.

For example, an exact-input buy spending 100 FWA retains 5 FWA and passes 95 FWA to the pool. The pool's 1.25% input fee still applies to that 95 FWA. A sell producing 100 FWA from the pool retains 5 FWA and delivers 95 FWA; the pool has already charged its own fee on the DCA input. These fees compound on their respective bases; do not quote them as a universal flat 6.25% charge.

**Partial fills:** exact-input buys and exact-output sells commit their FWA fee before the swap. They revert atomically with `PartialFill()` if the specified FWA leg is not completely filled, including when liquidity or the price limit prevents completion. Exact-input sells and exact-output buys support partial fills and charge only the actual FWA leg. Routers must enforce minimum output, maximum input, deadlines, and whether a partial exact-output buy is acceptable. The hook does not choose slippage limits or trust router-provided fee data.

Swap amounts must be nonzero and fit the positive `int128` range; grossed-up amounts must fit it too. This matches v4's signed balance-delta accounting.

## Fee custody and claiming

Fees are held **as FWA ERC-6909 claims owned exclusively by the hook on the PoolManager**, while the underlying FWA stays in the manager. This represents custody by the hook without an ordinary FWA transfer to it. It also allows the first buy to accrue fees before its input has settled.

`pendingFees()` reports those FWA claims. Anyone can call `claimFees()` in a standalone transaction. It opens a manager unlock, burns the hook's claims, and instructs the manager to send exactly that much FWA directly to the fixed recipient. The caller cannot select a destination and receives no reward. A failed transfer reverts the entire claim and preserves the balance for retry. Repeated claims with no fees return zero. Claims above `int128.max` are redeemed over multiple calls to respect v4 delta limits. Voluntary donations of FWA **claims** to the hook also go only to the fixed recipient.

FWA's supplied transfer definition allows transfers involving the PoolManager but rejects ordinary hook-to-wallet transfers. Consequently this hook requires no distributor registration to pay its recipient. It never converts FWA to ETH, approves an operator for its claims, or transfers collected DCA. Direct ERC-20 donations of FWA or other assets to the hook are outside this mechanism and have no rescue function; do not send them there.

`claimFees()` with a nonzero balance must be called outside an existing manager unlock. Reentrant claims are rejected. Hook callbacks and the unlock callback authenticate the immutable manager; an unsolicited unlock callback is rejected even when presented as coming from the manager.

## Deployment responsibilities

1. Keep the project's existing DCA token and its current supply/allocations. Obtain its actual address from the project's deployment record. This repository supplies no replacement token deployment for this repair.
2. Deploy **`DCAHookLauncher` as the application**, using `(requesterOwner, canonicalMainnetPoolManager)`. Ordinary CREATE or CREATE2 works: the application factory need not mine its own deployment salt. Do not list `DCAHook` as an ordinary-address application; it is created by the launcher during activation. Neither application nor hook receives any token allocation.
3. The requester owner calls `setToken(existingDcaAddress)`. This setting emits `TokenConfigured`; attempts to prepare or activate before configuration revert with `TokenNotConfigured`. A mistaken setting can be corrected before activation. Confirm the manager, owner, and token before proceeding.
4. Prepare a child salt with `PrepareHook.runLauncher(launcher, start, attempts)`, using the deployed launcher's address and current configuration. It reads `hookInitCodeHash()` from that launcher, so the hash includes the creation code embedded in the application and its actual manager/token arguments. Check that `launcher.predictHook(salt)` equals the prepared address and ends with the required low bits. Mine off-chain; activation does no search loop.
5. The owner calls `launcher.launch(salt, sqrtPriceX96)` with the actual opening price derived from the intended market cap, supply, and sorted token ordering. This creates `DCAHook`, initializes exactly its `getPoolKey()`, stores `hook()`, and emits `PoolLaunched`. Invalid salts, invalid prices, and manager failures revert the entire operation, including child creation; correct the cause and retry. Anyone else, including the deploying factory, is rejected. Activation cannot repeat.
6. Seed liquidity in **`launcher.getPoolKey()`** and configure the site, quoter, and swap router to use that exact key. `PoolKey.hooks` must equal `launcher.hook()`. Initializing a pool provides no liquidity. The liquidity operator must use the existing token allocation and enforce price/amount bounds; when the owner is a batching contract, activation and liquidity provisioning can be batched atomically through the operator's reviewed liquidity tooling. Seeding and withdrawals have no hook fee.
7. Verify bytecode, immutable values, address bits, pool ID, liquidity, and actual routing before enabling trading. Exercise a quoted buy, sell, and fee claim through the intended routing stack during the independent release review. Afterward the owner has no fee or trading controls.

Preparation entry points (simulation only, no environment reads or broadcasting):

```solidity
PrepareHook.runLauncher(DCAHookLauncher launcher, uint256 start, uint256 attempts)
    returns (bytes32 salt, address hook, bytes32 initCodeHash);

// Retained for a factory that already supports direct mined-hook deployment on mainnet:
PrepareHook.run(address factory, address token, uint256 start, uint256 attempts)
    returns (bytes32 salt, address hook, bytes32 initCodeHash);
```

To prepare a deployed launcher, simulate `forge script script/PrepareHook.s.sol:PrepareHook --sig "runLauncher(address,uint256,uint256)" LAUNCHER 0 1000000 --rpc-url RPC_URL`, substituting its actual address and a read-only Ethereum RPC endpoint. No `--broadcast` is needed or authorized. An exhausted search returns `SaltNotFound`; try the next interval. Changing the launcher address or token configuration requires mining again. `runLauncher` hashes the deployed launcher's embedded child code, avoiding a mismatch with locally recompiled child code. The direct `run` entry point instead uses the local compiled bytecode and requires mining again after recompilation.

**Integration boundary:** this source now supplies child deployment and hooked-pool initialization without requiring the external application factory to mine a salt. It does not modify IMD's external factory, its default guard-only pool, or an existing pool's immutable hook. A deployment flow that only creates the application and keeps routing to the default pool still does **not** charge the additional 5%. The operator must execute the activation steps and select/fund the resulting hooked pool, or use a hook-capable launch path that deploys `DCAHook` directly. Existing liquidity is not moved by this repair. If a guard-only pool already exists, switching liquidity/routing needs a separately reviewed operator transaction using the same DCA token. No manifest, deployment, migration, or token re-mint is performed here.

The launch policy values recorded by the earlier implementation remain the launch operator's responsibility; this repair does not execute or repeat allocations:

| Item | Required value |
| --- | --- |
| Manifest pool initial-price field | `79228162514264337593543950336` |
| Actual opening price | Derived by the launch deployer from market cap, supply, and token ordering |
| `economics.poolBps` | `8800` |
| `economics.initialMarketCapWei` | `2000000000000000000000000` (2,000,000 FWA) |
| `economics.remainderTo` | `0x1ee3ffadfe138415a2ddaedeebe5f46616fa413d` |
| Swarm allocation | Factory transfers 10% to its MerkleDistributor |
| Pool / remainder allocation | 88% / 2%, performed by the factory |

Neither this hook nor any auxiliary contract is allocated launch tokens. The actual fee recipient is independent of `economics.remainderTo`.

## After launch

After application deployment, the requester owner must call **`DCAHookLauncher.setToken(address)`** with the existing DCA address from the deployment record, prepare the salt, and call **`launch(bytes32,uint160)`** at the reviewed opening price. Then the liquidity/site operators must complete step 6 above. There are no owner-settable fee or recipient values and no post-activation launcher settings. The launcher's immutable owner is responsible only for this setup; a lost owner key before activation cannot be recovered by the factory.

A keeper, the recipient, or any other account may monitor the child hook's `pendingFees()` and pay gas to call `claimFees()`; there is no automatic payout schedule or keeper bounty. Index `PoolLaunched` to find the child and pool, and `HookFeeAccrued` and `FeesClaimed` to reconcile accruals and payments. Call `claimFees()` on `launcher.hook()`, not on the launcher.

The recipient is responsible for its wallet and for disposing of FWA through allowed transfer paths. Receipt of FWA does not exempt it from FWA's own transfer restrictions. The launch operator must confirm that the supplied mainnet FWA definition and PoolManager deployment remain the intended integrations. The mock models the supplied transfer rule, not all possible future FWA governance behavior.

Any separate IMD platform fee-sharing path paid by the launch factory follows IMD/FWA's own distributor-registration requirement; it is independent of this hook's manager-to-recipient payout. That registration, if required by the factory's platform payouts, is the launch operator's responsibility.

The fee applies to this exact launch pool. As with any standard freely transferable token, third parties can create other markets; this hook does not impose a global token tax. There is no owner recovery or upgrade path if an immutable deployment value is wrong. Local tests and review are recorded in `SECURITY.md`; a separate independent review remains a release responsibility.
