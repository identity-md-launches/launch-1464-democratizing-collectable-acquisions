# Democratizing Collectable Acquisions (DCA)

An immutable, fixed-supply ERC-20 and a Uniswap v4 launch-pool hook. The hook charges 5% exclusively in FWA on buys and sells, in addition to the 1.25% pool fee. Wallet-to-wallet DCA transfers have no tax.

**Ethereum mainnet launch (this follow-up).** The requester confirmed there is no Ethereum mainnet launch record yet, so no DCA token exists on mainnet. `DCAMainnetLauncher` performs the whole launch in one transaction signed by the operator: it creates the 1,000,000,000 DCA supply, deploys the 5% FWA fee hook at a mined address, opens the DCA/FWA pool at a **2,000,000 FWA market cap**, and seeds it with **88%** of the supply as permanently locked liquidity. The other 12% goes to the operator. `0x1EE3ffadfE138415A2ddaedeEBe5F46616fA413d` is the operator and signer. All fees, the hook's 5% FWA fee and the locked position's 1.25% LP fees, go to `0xCAE0B01E56cB164ce866A137d3528658b2FCBd4b`. See [Ethereum mainnet launch](#ethereum-mainnet-launch).

This is a source and tooling delivery. No on-chain transaction was sent, and nothing was deployed or minted. The earlier `DCAHookLauncher` path is retained below for a DCA token that already exists. It must **not** be used together with `DCAMainnetLauncher`, because that would create two DCA tokens.

## Ethereum mainnet launch

### Parameters

| Parameter | Value | Where it is fixed |
| --- | --- | --- |
| Chain | Ethereum mainnet, chain ID 1 | `MainnetLaunch.CHAIN_ID` (checked by `prepare`) |
| Operator and signer (launcher owner) | `0x1EE3ffadfE138415A2ddaedeEBe5F46616fA413d` | Constructor argument `owner_`; `MainnetLaunch.OPERATOR` |
| Uniswap v4 PoolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` | Constructor argument `poolManager_`; `MainnetLaunch.MANAGER` |
| Pair | DCA / FWA (`0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845`, 18 decimals) | Constant |
| DCA supply | 1,000,000,000 DCA = `1000000000000000000000000000` base units, 18 decimals, minted once | `DCAToken`, `TOTAL_SUPPLY` |
| Pool allocation | 88% = 880,000,000 DCA (`POOL_BPS = 8800`), single-sided, locked forever | Constant |
| Operator allocation | The other 12%: 120,000,000 DCA plus 21-22 base units of rounding dust | Sent to the owner in `launch` |
| Opening market cap | 2,000,000 FWA (`OPENING_MARKET_CAP_FWA`), i.e. 0.002 FWA per DCA, 500 DCA per FWA | Constant |
| Fee recipient | `0xCAE0B01E56cB164ce866A137d3528658b2FCBd4b` | `DCAHook.FEE_RECIPIENT`, `DCAMainnetLauncher.FEE_RECIPIENT` |
| Hook fee | 5% of the FWA leg of every buy and sell | `DCAHook` (see below) |
| Pool fee / tick spacing | 1.25% (`12500`) static / `60` | Constants |
| DCA token address | `predictToken()`: CREATE2 from the launcher with `TOKEN_SALT = keccak256("DCA mainnet token")` | Derived from the launcher address |

The launcher takes two constructor arguments, `(0x1EE3ffadfE138415A2ddaedeEBe5F46616fA413d, 0x000000000004444c5dc75cB358380D2e3dE08A90)`, and its constructor makes no external calls or code checks. `launch` checks that the manager and FWA have code. Nothing on the launcher is set after deployment: the owner, manager, recipient, supply, allocation and price are all fixed, so there is no owner-settable value to configure.

### Opening price and the seeded position

The price is computed on chain from the constants; the signer does not choose it. With both tokens at 18 decimals, v4's price is currency1 per currency0 in base units:

| Address order (depends on the launcher address) | `sqrtPriceX96` | Opening tick | Seeded range | Liquidity | DCA pooled |
| --- | --- | --- | --- | --- | --- |
| DCA is currency0 (price 0.002) | `3543191142285914205922034323` | -62150 | [-62100, 887220] | `39451700324980270566438357` | `879999999999999999999999978` |
| FWA is currency0 (price 500) | `1771595571142957102961017161607` | 62149 | [-887220, 62100] | `39451700324980270566438357` | `879999999999999999999999979` |

`sqrtPriceX96 = floor(sqrt(2**192 * currency1 / currency0))`, so the pool initializes at a market cap equal to 2,000,000 FWA (to within 1e-27 relative). Seeding uses only DCA, so the position must lie wholly on the DCA side of the current price. It therefore starts at the first tick multiple of 60 at or beyond the opening price and runs to the edge of the usable price range. The first buyer crosses at most 60 ticks of empty range, at most 0.6% above the opening price (at most 0.5% for the address orders above). From there the full 88% is available. Liquidity is rounded down, so the pool takes 21-22 base units less than 880,000,000 DCA; that dust goes to the operator with the 12%. `prepare` returns the exact numbers for the actual launcher.

The position is owned by the launcher at `(tickLower, tickUpper, salt 0)` and **cannot be withdrawn**: the launcher has no function that removes liquidity, and nobody (including the operator) can change that. Its LP fees remain collectable (below).

### Fees

- **Hook fee, 5% in FWA**: unchanged `DCAHook` behaviour, documented in [Fee arithmetic](#fee-arithmetic-and-swap-behavior) and [Fee custody](#fee-custody-and-claiming). Anyone may call `hook.claimFees()` to send the accrued FWA to `0xCAE0…4b`.
- **LP fees, 1.25% pool fee**: the locked position earns the pool fee in the input token: FWA on buys, DCA on sells. Anyone may call `launcher.collectFees()`. It collects them by a zero-liquidity `modifyLiquidity` and has the manager send both currencies directly to `0xCAE0…4b`. FWA's transfer rule allows this, because the manager is the sender. The caller chooses nothing and earns nothing. A failed payout reverts the whole call and leaves the fees in place for a retry.
- This path pays no IMD platform share. If a platform fee split is required, it is outside this contract and must be agreed before launch.

### Launch steps (operator)

1. **Deploy the launcher.** Use `MainnetLaunch.deploy()`, or deploy `DCAMainnetLauncher` with `MainnetLaunch.constructorArgs()` = `(0x1EE3…413d, 0x0000…8A90)`. Ownership is explicit and does not depend on who sends the deployment. Deploy **only** this contract: `DCAToken` and `DCAHook` are created by `launch`, and neither should be deployed or listed separately.
2. **Prepare (read-only).** Run `MainnetLaunch.prepare(launcher, start, attempts)` against mainnet:
   ```sh
   forge script script/MainnetLaunch.s.sol:MainnetLaunch --sig "prepare(address,uint256,uint256)" LAUNCHER 0 1000000 --rpc-url RPC_URL
   ```
   It checks chain ID 1 and that the launcher has code, owner `0x1EE3…413d`, the canonical manager and is not launched. It checks that FWA reports symbol `FWA`, 18 decimals, the canonical `poolManager()` and `isDistributor(manager) == true`, and that the predicted token and hook addresses are empty. It then mines the hook salt off-chain (`address & 0x3fff == 0x20cc`) and returns `to`, `from`, the calldata `launch(salt)` (ETH value 0), and the predicted token, hook, pool key, pool ID, price, tick, range, liquidity, pooled amount and operator amount. `SaltNotFound` means the interval is exhausted; try the next `start`.
3. **Review and sign.** From `0x1EE3…413d`, send the returned zero-value transaction to the launcher. In one transaction it emits `Launched` with every value above, creates DCA (all 1B to the launcher), deploys the hook, initializes the pool and seeds 880M DCA. It then transfers the remainder to the operator. Any failure, such as a wrong salt or a manager error, reverts everything and can be retried. Only the owner can call it, and only once.
4. **Route.** Point the site, quoter and router at `launcher.getPoolKey()` (equal to `hook.getPoolKey()`). Before announcing, verify on a block explorer: the launcher and hook bytecode, the slot0 price, the position liquidity, and a small quoted buy, sell, `claimFees()` and `collectFees()`.

### After launch

- There are no settings to make: nothing on the launcher, the token or the hook is owner-settable.
- **Operator (`0x1EE3…413d`)** holds the 12% (120,000,000 DCA plus dust). Any further distribution, such as the 10% swarm and 2% remainder recorded in the earlier launch policy, is the operator's own decision and is not performed by these contracts.
- **Fee keepers.** Anyone (the recipient, the operator or a keeper) pays gas to call `hook.claimFees()` and `launcher.collectFees()`. There is no automatic schedule or bounty. Index `HookFeeAccrued`, `FeesClaimed` and `LiquidityFeesCollected`.
- **Recipient (`0xCAE0…4b`)** receives FWA and DCA. FWA's own transfer rule still applies to whatever the recipient does with FWA afterwards.
- **FWA governance.** FWA's owner controls FWA's transfer rule and distributor list. If the PoolManager stopped being an FWA distributor, swaps and fee payouts in FWA would fail. That is outside this project's control.

### Assumptions

- No DCA token exists on Ethereum mainnet (stated by the requester), so `launch` performs the one and only mint. If a DCA token is deployed by any other route first, do not use `DCAMainnetLauncher`.
- "88% opens the pool at a 2 million FWA market cap" means: the market cap is the full 1B supply valued at the opening price (2,000,000 FWA / 1,000,000,000 DCA = 0.002 FWA per DCA), and 88% of the supply is the pool's only liquidity, all DCA, with no FWA paired in.
- Seeded liquidity is locked permanently, and its LP fees go to the fee recipient. The brief says "send fees to 0xCAE0…", which this applies to all fees.
- The launch transaction is submitted directly by the operator. A private relay is not required, because nobody else can initialize the hooked pool or deploy to the launcher's CREATE2 addresses.

## Build and verification

Run from the repository root with Foundry and Solidity 0.8.26 installed:

```sh
forge build
forge test
forge fmt --check
```

`foundry.toml` pins Solidity 0.8.26, Cancun, optimizer settings, and `bytecode_hash = "none"`. All required Solidity dependencies are ordinary files in `lib/`; no dependency installation, network, environment variables, keys, FFI, or filesystem cheatcodes are needed to build or test. Exact dependency commits and retained files are recorded in `DEPENDENCIES.json`, with upstream licenses alongside them.

Tests use the actual vendored Uniswap v4 `PoolManager` and a restricted FWA mock at FWA's canonical address. Their shared setup deploys and initializes through the production launcher. They exercise both address orderings, compare all four swap modes against an equivalent pool without the hook, test single-sided seeding and the first buy, and check fee custody and payout failures. Stateful invariant tests check conservation of both tokens, fees, and settled manager deltas across random swaps and claims. Launcher tests cover ordinary factory deployment, explicit ownership, missing configuration/contracts, invalid salts/prices, atomic rollback/retry, and one-time activation. Preparation tests execute the returned transaction against the real manager, then provide liquidity, buy, sell, and redeem FWA to the requested recipient for both currency orderings. They also reject wrong chains/owners/managers, missing contracts, incorrect token metadata/supply, incompatible FWA settings, occupied addresses, and repeat activation. Mainnet launcher tests (`test/DCAMainnetLauncher.t.sol`) run the real manager at its mainnet address. For both address orders they check the exact `Launched` event, the 1B supply, the 88%/12% split, that no FWA is used, the opening price against the 2M FWA market cap, and the position's range and liquidity. They also run a first buy near the opening price, then a sell, then hook-fee and LP-fee payouts to the recipient. Failure tests cover owner-only and one-time launch, wrong-salt rollback and retry, missing manager or FWA code, calls before launch, spoofed callbacks, an LP fee payout that fails and is retried, reentrant fee collection, and the preparation script's wrong-chain, wrong-owner, wrong-manager, missing-code and FWA-misconfiguration cases. A test also executes the exact transaction that `prepare` returns. No mainnet fork or live transaction is used in tests.

## Contracts

| Contract | Constructor arguments | Behavior |
| --- | --- | --- |
| `DCAToken` | None | Name `Democratizing Collectable Acquisions`, symbol `DCA`, 18 decimals; mints exactly 1,000,000,000 DCA to its deployer once. |
| `DCAHook` | `IPoolManager poolManager_`, `address token_` | Fixed pool and fee; accrues FWA claims and permits anyone to trigger payment to the fixed recipient. |
| `DCAMainnetLauncher` | `address owner_` (`0x1EE3…413d`), `IPoolManager poolManager_` (canonical) | **Mainnet launch.** Owner-only, one-time `launch(salt)` creates DCA, the hook and the pool, seeds 88% as locked liquidity and sends 12% to the owner; anyone may `collectFees()` to the fixed recipient. |
| `DCAHookLauncher` | `address owner_`, `IPoolManager poolManager_` | Earlier path for an already deployed token only: the owner selects it, deploys the mined hook, and initializes an empty pool with `launchWithToken`. Not used for the mainnet launch above. |

The token supply in base units is `1000000000000000000000000000`. `DCAToken` mints it once to its constructor caller; factory allocations belong to the separate token-launch process. This follow-up must not repeat a token deployment. The name intentionally preserves the request's spelling, **`Democratizing Collectable Acquisions`**. The token and hook have no owner, upgrade, pause, blacklist, privileged balance movement, or future mint function. The hook constructor neither calls external contracts nor takes any token allocation. Its `launchFactory` is the launcher, which is the sole caller permitted to initialize its fixed pool.

The launcher has an explicit, immutable requester owner, supplied as `$owner` by the separate launch manifest step. Its deploying application factory receives no ownership rights. The owner can correct the token setting before activation and choose the initial price, but cannot alter the hook's fee, recipient, or pool parameters. Token configuration and activation are permanently disabled after successful activation. The launcher never holds launch allocations, approves assets, routes swaps, or manages liquidity. All constructors make no external calls or code checks; activation checks that the manager and configured token have code.

`HookMiner` is an internal library; `MainnetLaunch`, `PrepareLaunch` and `PrepareHook` are off-chain preparation scripts, not launch applications. No library linking is required.

## Pool and immutable parameters

| Parameter | Value |
| --- | --- |
| Chain | Ethereum mainnet, chain ID 1 |
| FWA | `0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845` (18 decimals) |
| PoolManager constructor argument to launcher | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| Launcher owner constructor argument | Requester's `$owner`; never the application factory or IMD's launch wallet |
| DCA setting passed to hook | Project's actual `DCAToken` address, supplied in `launchWithToken` or configured with `setToken` |
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

## Earlier path: existing-token deployment responsibilities

This section applies only to `DCAHookLauncher` with a DCA token that already exists. For the Ethereum mainnet launch requested now, follow [Ethereum mainnet launch](#ethereum-mainnet-launch) instead.

1. Obtain the project's actual DCA address from its deployment record. If the separate token-launch process has not completed, its recorded address must be available before activation. Keep that token and its supply/allocations; this repository supplies no replacement token deployment for this repair. Obtain the requester owner from that same record, and the reviewed opening price from the launch economics. These are explicit inputs, not guessed addresses or default prices.
2. Deploy **`DCAHookLauncher` as the application**, using `(requesterOwner, canonicalMainnetPoolManager)`. Ordinary CREATE or CREATE2 works: the application factory need not mine its own deployment salt. Do not list `DCAHook` as an ordinary-address application; it is created by the launcher during activation. Neither application nor hook receives any token allocation.
3. Run `PrepareLaunch.run(launcher, requesterOwner, existingDcaAddress, sqrtPriceX96, start, attempts)` on Ethereum mainnet as a read-only simulation. No prior `setToken` transaction is needed. It verifies code exists, the explicit owner matches, the manager is canonical, DCA metadata/supply match, FWA reports the expected metadata/manager/distributor status, and the price is within v4's valid range. It reads `hookInitCodeHashFor(existingDcaAddress)` from the deployed launcher, so mining uses its embedded child creation code and actual constructor arguments. Mining is off-chain; activation has no search loop.
4. Review the returned `Activation`: `chainId = 1`, `from = requesterOwner`, `to = launcher`, `token`, `sqrtPriceX96`, `salt`, predicted `hook`, `initCodeHash`, `poolKey`, `poolId`, and `data`. The ETH transaction value is **0**. Verify the token's provenance and the launcher bytecode as well as these fields; a contract can imitate ERC-20 metadata. The script validates the price's range, not its economic suitability. With both tokens using 18 decimals, if the reviewed DCA price is `p` FWA per DCA, use `floor(sqrt(p) * 2**96)` when DCA is currency0, and `floor(sqrt(1/p) * 2**96)` when FWA is currency0. Compute with integer/high-precision tooling and verify sorted currencies. The test price `2**96` means 1 FWA per DCA and is not an approved opening price.
5. The requester owner submits the reviewed zero-value `to`/`data` transaction through its own wallet. It calls `launchWithToken(existingDcaAddress, salt, sqrtPriceX96)`, emits `TokenConfigured`, creates `DCAHook`, initializes exactly its `getPoolKey()`, stores `hook()`, and emits `PoolLaunched`. The call commits to the token even if a previous `setToken` setting differs. Invalid salts, invalid prices, and manager failures roll back the entire operation, including token configuration and child creation; correct the cause and retry. Anyone else, including the deploying factory, is rejected. Activation cannot repeat. This assignment does not submit that transaction.
6. Seed liquidity in **`launcher.getPoolKey()`** and configure the site, quoter, and swap router to use that exact key. `PoolKey.hooks` must equal `launcher.hook()`. Initializing a pool provides no liquidity. The liquidity operator must use the existing token allocation and enforce price/amount bounds; when the owner is a batching contract, activation and liquidity provisioning can be batched atomically through the operator's reviewed liquidity tooling. Seeding and withdrawals have no hook fee.
7. Verify bytecode, immutable values, address bits, pool ID, liquidity, and actual routing before enabling trading. Exercise a quoted buy, sell, and fee claim through the intended routing stack during the independent release review. Afterward the owner has no fee or trading controls.

Preparation entry points (simulation only, no environment reads or broadcasting):

```solidity
PrepareLaunch.run(
    DCAHookLauncher launcher, address expectedOwner, address existingToken,
    uint160 sqrtPriceX96, uint256 start, uint256 attempts
) returns (PrepareLaunch.Activation memory plan);

// Retained two-step path: owner first calls setToken, then uses this to prepare launch(salt, price).
PrepareHook.runLauncher(DCAHookLauncher launcher, uint256 start, uint256 attempts)
    returns (bytes32 salt, address hook, bytes32 initCodeHash);

// Retained for a factory that already supports direct mined-hook deployment on mainnet:
PrepareHook.run(address factory, address token, uint256 start, uint256 attempts)
    returns (bytes32 salt, address hook, bytes32 initCodeHash);
```

Prepare the new activation call with the actual recorded values in place of the uppercase labels:

```sh
forge script script/PrepareLaunch.s.sol:PrepareLaunch \
  --sig "run(address,address,address,uint160,uint256,uint256)" \
  LAUNCHER REQUESTER_OWNER DCA_ADDRESS OPENING_SQRT_PRICE_X96 0 1000000 \
  --rpc-url RPC_URL
```

On this contributor machine, `RPC_URL` is `http://127.0.0.1:37851/rpc/1`. Elsewhere use an Ethereum endpoint supplied by the operator. The script only returns data and makes read calls; it never broadcasts or signs. An exhausted search returns `SaltNotFound`; try the next interval. Changing the launcher address or chosen token requires mining again. Both launcher preparation paths hash the deployed launcher's embedded child code, avoiding a mismatch with locally recompiled child code. The legacy direct `PrepareHook.run` instead uses local bytecode and requires mining again after recompilation. The legacy `setToken` / `runLauncher` / `launch` path remains available; its token-dependent calls fail with `TokenNotConfigured` while unset. Only `PrepareLaunch` performs the full mainnet preflight.

**Integration boundary:** this source now supplies child deployment and hooked-pool initialization without requiring the external application factory to mine a salt. It does not modify IMD's external factory, its default guard-only pool, or an existing pool's immutable hook. A deployment flow that only creates the application and keeps routing to the default pool still does **not** charge the additional 5%. The operator must execute the activation steps and select/fund the resulting hooked pool, or use a hook-capable launch path that deploys `DCAHook` directly. Existing liquidity is not moved by this repair. If a guard-only pool already exists, switching liquidity/routing needs a separately reviewed operator transaction using the same DCA token. No manifest, deployment, migration, or token re-mint is performed here.

The following are historical launch-policy values recorded by the earlier implementation, not inputs applied by these scripts or contracts. The operator must reconcile them with the separate launch record; this repair does not execute or repeat allocations, or treat the historical manifest price field as an activation price:

| Item | Previously recorded value |
| --- | --- |
| Manifest pool initial-price field | `79228162514264337593543950336` |
| Actual opening price | Derived by the launch deployer from market cap, supply, and token ordering |
| `economics.poolBps` | `8800` |
| `economics.initialMarketCapWei` | `2000000000000000000000000` (2,000,000 FWA) |
| `economics.remainderTo` | `0x1ee3ffadfe138415a2ddaedeebe5f46616fa413d` |
| Swarm allocation | Factory transfers 10% to its MerkleDistributor |
| Pool / remainder allocation | 88% / 2%, performed by the factory |

Neither this hook nor any auxiliary contract is allocated launch tokens. The actual fee recipient is independent of `economics.remainderTo`.

## After launch (earlier path)

For the mainnet launch, see [After launch](#after-launch) above. On the earlier path: after application deployment, the requester owner must prepare and submit **`DCAHookLauncher.launchWithToken(address,bytes32,uint160)`** with the actual DCA address from the deployment record and the reviewed opening price. Alternatively, **`setToken(address)`** followed by **`launch(bytes32,uint160)`** remains supported. `setToken` emits `TokenConfigured` and can correct the setting only before activation; no token-dependent action on the two-step path works while unset. Then the liquidity/site operators must complete step 6 above. There are no owner-settable fee or recipient values and no post-activation launcher settings. The launcher's immutable owner is responsible only for this setup; a lost owner key before activation cannot be recovered by the factory.

A keeper, the recipient, or any other account may monitor the child hook's `pendingFees()` and pay gas to call `claimFees()`; there is no automatic payout schedule or keeper bounty. Index `PoolLaunched` to find the child and pool, and `HookFeeAccrued` and `FeesClaimed` to reconcile accruals and payments. Call `claimFees()` on `launcher.hook()`, not on the launcher.

The recipient is responsible for its wallet and for disposing of FWA through allowed transfer paths. Receipt of FWA does not exempt it from FWA's own transfer restrictions. The launch operator must confirm that the supplied mainnet FWA definition and PoolManager deployment remain the intended integrations. The mock models the supplied transfer rule, not all possible future FWA governance behavior.

Read-only mainnet checks for this follow-up at block **26178567** returned FWA symbol `FWA`, decimals `18`, `poolManager()` equal to the canonical manager, and `isDistributor(manager) == true`; both addresses had code. These observations establish the current integration assumptions, not DCA deployment, pool liquidity, or a permanent promise by FWA governance. Repeat preparation immediately before signing. Preflight is an off-chain check; the launcher still trusts its configured integrations and owner, and does not freeze external FWA settings.

Any separate IMD platform fee-sharing path paid by the launch factory follows IMD/FWA's own distributor-registration requirement; it is independent of this hook's manager-to-recipient payout. That registration, if required by the factory's platform payouts, is the launch operator's responsibility.

The fee applies to this exact launch pool. As with any standard freely transferable token, third parties can create other markets; this hook does not impose a global token tax. There is no owner recovery or upgrade path if an immutable deployment value is wrong. Local tests and review are recorded in `SECURITY.md`; a separate independent review remains a release responsibility.
