# Democratizing Collectable Acquisions (DCA)

An immutable, fixed-supply ERC-20 and a Uniswap v4 launch-pool hook. The hook charges 5% exclusively in FWA on buys and sells, in addition to the mandatory 1.25% pool fee. Wallet-to-wallet DCA transfers have no tax.

## Build and verification

Run from the repository root with Foundry and Solidity 0.8.26 installed:

```sh
forge build
forge test
forge fmt --check
```

`foundry.toml` pins Solidity 0.8.26, Cancun, optimizer settings, and `bytecode_hash = "none"`. All required Solidity dependencies are ordinary files in `lib/`; no dependency installation, network, environment variables, keys, FFI, or filesystem cheatcodes are needed to build or test. Exact dependency commits and retained files are recorded in `DEPENDENCIES.json`, with upstream licenses alongside them.

Tests use the actual vendored Uniswap v4 `PoolManager` and a restricted FWA mock at FWA's canonical address. They exercise both address orderings, compare all four swap modes against an equivalent pool without the hook, test single-sided seeding and the first buy, and check fee custody and payout failures. Stateful invariant tests check conservation of both tokens, fees, and settled manager deltas across random swaps and claims. No mainnet fork or live transaction is used.

## Contracts

| Contract | Constructor arguments | Behavior |
| --- | --- | --- |
| `DCAToken` | None | Name `Democratizing Collectable Acquisions`, symbol `DCA`, 18 decimals; mints exactly 1,000,000,000 DCA to its deployer once. |
| `DCAHook` | `IPoolManager poolManager_`, `address token_` | Fixed pool and fee; accrues FWA claims and permits anyone to trigger payment to the fixed recipient. |

The token supply in base units is `1000000000000000000000000000`. The factory receives it in the constructor and performs the launch allocations. The hook constructor neither calls external contracts nor takes any token allocation. Both contracts have no owner, upgrade, pause, blacklist, privileged balance movement, or future mint function. The hook's deploying factory is recorded only as the authority to initialize its fixed pool. It cannot alter fees, recipients, currencies, or trading permissions.

`HookMiner` is an internal library, and `PrepareHook` is an off-chain preparation script; neither is a launch application. No library linking is required.

## Pool and immutable parameters

| Parameter | Value |
| --- | --- |
| Chain | Ethereum mainnet, chain ID 1 |
| FWA | `0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845` (18 decimals) |
| PoolManager constructor argument | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| DCA constructor argument to hook | Address of this launch's `DCAToken` |
| Fee recipient | `0xCAE0B01E56cB164ce866A137d3528658b2FCBd4b` |
| Hook fee | 500 basis points (5%), immutable |
| Pool fee | `12500` millionths (1.25%), static |
| Tick spacing | `60` |
| Hook address low bits | `address & 0x3fff == 0x20cc` |

`getPoolKey()` sorts DCA and FWA by address and includes this hook, the mandatory fee, and tick spacing. The immutable `poolId` binds all hook callbacks to this exact key. Other pairs, fee tiers, tick spacings, and hook addresses are rejected. Dynamic pool fees are rejected. The hook never overrides the pool fee.

The flags `0x20cc` enable `beforeInitialize`, `beforeSwap`, `afterSwap`, and both swap-return-delta permissions. Unused callbacks are disabled. Construction rejects an address with different flags.

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

1. The launch's factory deploys `DCAToken`; it receives the entire supply. Record the actual token address.
2. Prepare the hook's CREATE2 address using the **actual deploying factory**, the token address, canonical mainnet PoolManager, and the exact compiled creation code. The low address bits must be `0x20cc`. Deploy `DCAHook` directly from that factory, with arguments `(PoolManager, DCAToken)` in that order. Its `launchFactory` immutable must be the factory that will call `PoolManager.initialize`.
3. Initialize the key returned by `getPoolKey()` through that factory, at the launch policy's derived opening price, and seed liquidity. Seeding and LP withdrawals have no hook fee. No hook initialization/setter transaction is required.
4. Verify the deployed bytecode, immutable arguments, fee recipient, address bits, pool key, and actual launch allocations before releasing the launch. Exercise a quoted buy, sell, and fee claim through the intended routing stack during the independent release review.

The pure preparation entry point is:

```solidity
PrepareHook.run(address factory, address token, uint256 start, uint256 attempts)
    returns (bytes32 salt, address hook, bytes32 initCodeHash);
```

It can be simulated with `forge script script/PrepareHook.s.sol:PrepareHook --sig "run(address,address,uint256,uint256)" FACTORY TOKEN 0 1000000` after replacing `FACTORY` and `TOKEN` with the launch's actual addresses. No `--broadcast` is needed or authorized. If the search interval is exhausted, use a subsequent interval. Recompiling with different settings or changing constructor arguments requires mining again. The tests call this function directly and verify deployment through a separate factory without any external contracts installed.

**Pool wiring is essential:** the launch must select its hook-capable deployment path and set `PoolKey.hooks` to `DCAHook` when the pool is created. Merely deploying the hook as an application beside the default initialization-guard pool does not install a fee. A pool's hook cannot be replaced after initialization. The supplied custom-token floor checks use a guard-only pool and establish token launch compatibility; the repository's real-manager integration tests additionally verify the requested custom hook. The launch manifest/deployer step must preserve this hook wiring; this repository does not invent a `launch.json` or assume an undocumented factory ABI.

The launch policy values supplied with the assignment remain the manifest step's responsibility:

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

There are no owner-settable token or hook settings. A keeper, the recipient, or any other account may monitor `pendingFees()` and pay gas to call `claimFees()`; there is no automatic payout schedule or keeper bounty. Index `HookFeeAccrued` and `FeesClaimed` events to reconcile accruals and payments.

The recipient is responsible for its wallet and for disposing of FWA through allowed transfer paths. Receipt of FWA does not exempt it from FWA's own transfer restrictions. The launch operator must confirm that the supplied mainnet FWA definition and PoolManager deployment remain the intended integrations. The mock models the supplied transfer rule, not all possible future FWA governance behavior.

Any separate IMD platform fee-sharing path paid by the launch factory follows IMD/FWA's own distributor-registration requirement; it is independent of this hook's manager-to-recipient payout. That registration, if required by the factory's platform payouts, is the launch operator's responsibility.

The fee applies to this exact launch pool. As with any standard freely transferable token, third parties can create other markets; this hook does not impose a global token tax. There is no owner recovery or upgrade path if an immutable deployment value is wrong. Local tests and review are recorded in `SECURITY.md`; a separate independent review remains a release responsibility.
