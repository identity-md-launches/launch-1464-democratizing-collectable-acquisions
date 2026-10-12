# Additional adversarial tests

Run from the repository root with `forge build` and `forge test`. These additions reuse
the existing dependencies, real Uniswap v4 PoolManager, CREATE2 hook deployment, and
restricted FWA mock. No network, environment changes, fork, or extra dependency is needed.

| File | Additional coverage |
| --- | --- |
| `DCATokenEdges.t.sol` | Zero transfers and events, full-supply delegated self-transfer, allowance replacement/revocation, maximum-value rejection, and invalid ERC-20 addresses. |
| `DCATokenStateful.t.sol` | Four actors execute transfers, approvals, delegated transfers, and deliberate failures. Independent balance and allowance ledgers must agree with the token after every call; the full fixed supply must remain transferable after each sequence. |
| `DCAHookEdges.t.sol` | Integer rounding and signed limits, invalid callback amounts/signs, untrusted callback data, failed batch rollback, currency isolation, initialized tick crossings, and fee backing after all liquidity is removed. Both currency orderings run each test. |
| `DCAHookStateful.t.sol` | Three traders mix all four swap modes, dust, round trips, liquidity changes, FWA claim donations, claims, rejected payouts, and rejected partial fills. Both currency orderings run 256 sequences of 64 calls. |
| `DCAHookLauncher.t.sol` | Ordinary application factory deployment, explicit requester ownership, unset/invalid configuration, first-use code checks, exact CREATE2 predictions, atomic token selection/deploy/initialize, restoration of prior configuration after failed activation, signed token selection despite a stale setting, bad salts/prices with rollback/retry, one-time activation, and separation from existing unhooked pools. |
| `PrepareLaunch.t.sol` | Read-only mainnet preflight with explicit parameters, wrong chain/owner/manager, missing code, wrong DCA metadata/supply, incompatible FWA settings, occupied hook addresses, exhausted mining, and repeat activation. Executes the returned calldata through the real manager, seeds liquidity, checks both trade directions and currency orderings, rejects a payout, and then retries payment exclusively to the fixed recipient while preserving supply and settling all deltas. |

All hook swap, edge, and stateful suites now deploy and initialize through
`DCAHookLauncher`, using its production bytecode and the real PoolManager. The
original direct-deployment checks remain in `Deployment.t.sol`. Thus the additional
5% FWA fee and the retained 1.25% pool fee are checked through the repaired activation
path, for both address orderings, with no constructor-validation bypass.

The hook handler advances a second pool without the hook using the same effective
swap amounts and liquidity changes. Its output, price, and LP fee growth are the
reference. Expected hook fees accumulate from those economic results, independently
of `pendingFees()`. The invariants require accrued fees plus donations to equal
pending claims plus actual payouts, preserve both tokens' balances, and leave no
unsettled manager debts. Every sequence ends by claiming everything to the fixed
recipient. Expected failures match specific revert data and must preserve accounting.

The token handler updates its model from requested operations, rather than copying
contract balances. A failed delegated transfer must restore even an allowance that
was tentatively spent before the balance/receiver check. Finite and unlimited
approvals, self-transfers, zero amounts, and full balances are included.

Fuzz arithmetic and callback-data properties run 1,000 cases each. Counts are set
inline on the concrete test contracts, so no Foundry configuration changes are needed.
Deterministic tests exercise every handler action as a check that the random handlers
can reach meaningful states.

The FWA mock models the supplied PoolManager transfer restriction and injects payout
failures; these tests do not validate live deployment wiring or future FWA upgrades.
Random swaps are bounded to keep the pools liquid and traders funded for each
64-call sequence. Separate deterministic tests cover signed arithmetic limits, full
liquidity withdrawal, and the existing suite's large claim redemptions.
