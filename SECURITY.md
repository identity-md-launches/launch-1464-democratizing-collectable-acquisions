# Security review record

This project uses a standard OpenZeppelin ERC-20 and a small immutable hook. The review below is local implementation review, not an independent audit or authorization to deploy.

## Trust boundaries

- The actual launch factory must deploy both contracts with the documented bytecode and arguments and initialize the correct hook pool. It receives the supply, controls initial price/liquidity allocation, and is the sole initialization caller. It has no post-launch token/hook administrative power.
- The hook trusts its immutable PoolManager to implement v4 accounting and report truthful pool deltas. Production must use the documented canonical Ethereum deployment. Constructors deliberately make no external calls, so a mistyped manager or token must be caught by deployment review.
- FWA is the supplied canonical token. Its owner and its own restrictions remain external protocol dependencies. The hook owns claims; successful fee claims rely on the manager being able to transfer FWA to the fixed recipient.
- Traders and routers are untrusted. No sender, router, token holder, or deployer receives a fee exemption. Routers remain responsible for slippage and execution limits.

## Adversarial cases reviewed

| Concern | Mitigation and evidence |
| --- | --- |
| Supply growth or privileged confiscation | Only the constructor reaches `_mint`. ERC-20 admin, pause, blacklist, burn-from, and upgrade probes fail. Factory allocations and ordinary transfers arrive whole. |
| Incorrect currency or changed pool fee | Immutable pool ID includes both ordered currencies, fee, tick spacing, and this hook. Rejection tests cover other keys, zero fee, and the dynamic fee flag. |
| Hook address missing required callbacks | Constructor validates all address flags. Tests mine and deploy real CREATE2 hook addresses and reject mismatches. |
| Initialization front-running | `beforeInitialize` authenticates the manager and the deploying factory. Unauthorized initialization reverts before pool creation. |
| Callback spoofing or arbitrary payout recipient | All active callbacks require the manager. The unlock callback additionally requires an in-progress claim; it ignores externally supplied destination data. Recipient is a constant. |
| FWA transfer restriction | Swaps mint claims rather than transferring FWA out of the manager. Claim burns them and uses manager-to-recipient `take`. The mock rejects ordinary transfers. |
| First-swap reserve shortage | Claim minting needs no pre-existing liquid FWA withdrawal. A single-sided launch test buys and sells with less than the fee in pre-swap manager reserves. |
| Wrong signs or charging DCA | Tests compare real swaps with a control pool for both sort orders and every exact-input/output mode. Only the FWA delta changes. |
| Fee on unfilled input/output | FWA-specified partial fills revert atomically. Other partial fills tax actual FWA deltas only. Pool price, balances, and fee claims roll back on failures. |
| Rounding and overflow | Integer 5% fee rounds down. Net-to-gross inversion is fuzzed for exactness and minimality. Signed ranges are checked before negation/gross-up. Aggregate claims redeem in bounded chunks. |
| Fee theft using claims | The hook never grants ERC-6909 allowance or operator rights; attempts to transfer its claims fail. Donated FWA claims can only reach the fixed recipient. |
| Reentrant or failed claim | `nonReentrant`, authenticated callback, and state cleared before burn/take. An adversarial FWA mock attempts reentry; failed payout leaves all claims recoverable. |
| Unsettled flash accounting | Real-manager integration and stateful tests check zero remaining deltas and a locked manager after every transaction. |
| Multiple swaps in an unlock | No global per-swap temporary state; each fee follows its callback's parameters/deltas. Batch and randomized sequence tests pass. |

The hook has no swap entry point, so Uniswap's hook self-call exemption cannot be used to bypass its fee. PoolManager `mint` does not invoke token or recipient callbacks. The only external ERC-20 payout happens under the claim guard.

## Validation and limits

The delivered tests include deterministic success/failure tests, parameter fuzzing, and stateful conservation invariants against the real vendored PoolManager. Default fuzzing uses 256 cases per property; each of the two stateful suites runs 128 sequences of 32 calls. The test harness is deterministic from its seed, independent of caller identity/environment, and contains no live network calls.

Compiler/Foundry checks: `forge build`, `forge test`, and `forge fmt --check`. Runtime-size and prohibited-opcode checks cover the token and hook. Deployment preparation is executed directly in tests on an empty simulated chain. The supplied environment-driven protected harness belongs to the independent verifier; it is not edited or substituted by these tests.

Slither and Mythril were not run. Foundry lint's signed-cast warnings are reviewed against explicit sign/range checks; the claim's external calls are protected by OpenZeppelin's reentrancy guard and PoolManager authentication. Tests do not prove behavior of arbitrary future FWA implementations, liquidity availability, router integrations, or correct external manifest wiring. An independent contributor should review those boundaries and the exact deployment artifacts before release.
