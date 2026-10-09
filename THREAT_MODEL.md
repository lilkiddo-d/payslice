# Payslice threat model

Scope: `contracts/src/**` as deployed by `script/Deploy.s.sol` on Robinhood Chain (4663), plus the keeper and
frontend where they affect funds.

## Assets

| Asset | Where it sits | Owner |
|---|---|---|
| Unallocated payroll funds (USDG) | `Payroll` clone | employer |
| Earned, not yet withdrawn pay | `Payroll` clone (reserved) | worker |
| Queued slices (USDG) and converted stock tokens | `BatchConverter` | workers, pro-rata |
| Bonus escrow (stock tokens) | `BonusVesting` | worker (vested), employer (unvested) |
| Protocol fees | `FeeCollector`; staker share in `ProjectTokenHooks` | treasury / stakers |
| Staked $SLCE (once set) | `ProjectTokenHooks` | stakers |

## Actors and trust

| Actor | Can | Cannot |
|---|---|---|
| Worker | withdraw earned pay, set slice rule / auto-harvest, claim conversions, bonuses, refunds | touch other workers' funds |
| Employer | fund, create / edit / pause / cancel streams, withdraw **unallocated** funds, grant / revoke **unvested** bonuses | reduce earned pay, block withdrawals, withdraw reserved funds |
| Keeper (`KEEPER_ROLE`) | execute closed batches during market hours, trigger auto-harvest withdrawals (funds go to the worker) | choose a price below the oracle floor, redirect funds |
| Guardian | pause factory / converter / bonus grants / staking; force market closed; disable feeds; de-list assets; add holidays | unpause-only-by-admin actions, move funds, block withdrawals |
| Timelock (48h; proposer/executor = `PAYSLICE_ADMIN`) | all admin config: feeds, routes, fees (capped), listings, compliance, `setProjectToken` (once) | upgrade payrolls (clones of an immutable implementation), touch payroll balances |
| Anyone | fund a payroll, sync streams (emits payslips), deposit into conversions for any worker with their own funds, open refunds for stale batches, sweep treasury fees | anything else |

## Top risks and mitigations

### 1. Employer clawback of accrued pay

**Threat:** the employer cancels, edits or pauses a stream, or withdraws funds, to take back wages already
earned, or freezes the worker so they can't withdraw.

**Mitigations**
- Reservation accounting: every second, `totalRateX` is moved from `unallocatedX` into reserved funds.
  `withdrawUnallocated` can only take `unallocatedX`. Reserved funds become `earnedX` and can never go back
  to the employer. Only over-reservation (time before a stream starts or after it ends) is released.
- `cancelStream`, `pauseStream` and `updateStream` all call `_syncStream` first, so everything earned up to
  `paidUntil` is locked in `earnedX` before the change. Edits apply from now on only. `newEnd` cannot be in
  the past.
- Cliffs can only be moved **earlier** (`reduceCliff`). Cancelling waives the cliff, so a cancel before the
  cliff cannot erase the accrual.
- `withdraw` has no `whenNotPaused`. A protocol pause, compliance flag or failing converter cannot block it:
  the slice deposit is wrapped in `try/catch` and falls back to paying 100% in USDG.
- Payroll clones are immutable (EIP-1167 to a fixed implementation). The factory admin has no function that
  moves payroll funds.
- Tests: `invariant_solvent`, `invariant_alwaysWithdrawable`, `invariant_earnedMonotonic` (random
  employer/worker/time actions), `testFuzz_cancelKeepsEarned`, `testFuzz_employerActionsNeverReduceEarned`.

**Residual:** a worker earns nothing while the payroll is unfunded (auto-pause). That is intrinsic, since
there is no negative balance. Employers keep their legal obligation (see the risk page).

### 2. Batch-conversion sandwiching

**Threat:** MEV searchers front-run the weekly swap, or the keeper or a deposit-timing attacker manipulates
the execution price.

**Mitigations**
- Only *closed* epochs execute. The batch size is fixed before execution, so nobody can add to a batch at
  execution time.
- Every swap's `minOut` is at least `Chainlink-implied output × (1 − maxSlippageBps)` (1% default, 5% hard
  cap), whatever the keeper passes. The keeper further tightens to the Uniswap quote minus 0.3%. A sandwich
  can extract at most that band, and a pool pushed outside the band simply reverts.
- Swaps are allowed only during the regular US session (`MarketClock`), when stock feeds are fresh. Feeds
  must be ≤ 25h old, and USDG must be within 1% of $1 (depeg guard).
- Large batches are split into chunks by the keeper (`amountIn` per call) to limit price impact.
- `KEEPER_ROLE` is required, plus a deadline. `KEEPER_TX_RPC_URL` supports private transaction submission.
- If a batch can't execute for `refundDelay` (4 weeks), anyone can open refunds and workers reclaim their
  input pro-rata. Funds are never stuck.

**Residual:** value extraction is bounded by `maxSlippageBps` against Chainlink. Robinhood Chain has a
centralised sequencer, which today limits public-mempool sandwiching.

### 3. Rounding drift in per-second math

**Threat:** repeated edits / withdrawals leak or create value through rounding, or accrual exceeds funding.

**Mitigations**
- Rates and accruals use 1e18-scaled fixed point (`rateX`, `earnedX`, `unallocatedX`). Values are floored to
  token units only at payout. Total drift over a stream's life is < 1 base unit, however many edits happen.
- `withdrawn` is in token units and `withdrawn × 1e18 ≤ earnedX` always. The employer can only take
  `amount × 1e18 ≤ unallocatedX`. Together these keep `balance × 1e18 ≥ unallocatedX + Σ(earnedX −
  withdrawn·1e18) + unsynced reservations` exact.
- Depletion is computed in whole seconds: the remainder below one second's rate stays unallocated.
- Batch claims are `floor(in_i × out / in)`. Their sum is ≤ out, and dust is < number of workers.
- Tests: `testFuzz_accrualExact`, `testFuzz_noRoundingDrift` (30 random edits: earned equals the exact sum
  floor), `testFuzz_batchExactShares`.

## Other risks

| Risk | Mitigation |
|---|---|
| Reentrancy | `ReentrancyGuardTransient` on every state-changing external entry point; checks-effects-interactions; SafeERC20 everywhere |
| Fee-on-transfer / weird tokens | balance-diff accounting on every pull; only Timelock-allowlisted payroll tokens (USDG) and stock tokens |
| Oracle failure / manipulation | Chainlink only; staleness, `answer > 0`, `startedAt != 0`, `answeredInRound ≥ roundId`; peg check for USDG; guardian can disable a feed; sequencer-uptime check supported but **no feed exists on Robinhood Chain** (gap) |
| Corporate actions | Chainlink stock feeds include the ERC-8056 multiplier and pause during actions. Staleness then blocks conversion, and refunds kick in after the delay |
| Stock token pauses / transfer restrictions | a de-listed asset is ignored by the slice split and conversion deposits revert, so pay falls back to USDG; existing batches can be refunded |
| Unbounded loops / gas DoS | stream syncs O(1) per stream (payslip walk ≤ 12 months + one catch-up), gap lookups O(log n), batches capped (50 streams, 50 claims, 5 assets, 4 reward tokens, 4 tiers, 30 holidays, 200 allowlist) |
| Admin key compromise | 48h Timelock for every admin action; guardian can only act in the safe direction; fee caps (1% payroll, 1% conversion, 5% slippage) are constants |
| Guardian compromise | can pause entry points but never withdrawals or claims; Timelock can revoke the guardian |
| Compliance misuse | `ComplianceRegistry` gates only entry actions (create payroll / stream, set slice, deposit, grant); never withdrawals |
| Flash-staking for fee share / discount | 7-day lock on every stake; rewards use an accumulator (no retroactive gain) |
| Keeper key compromise | keeper can only execute closed batches inside the oracle band, or trigger withdrawals that pay workers. Revoke via Timelock; guardian can pause the converter |
| Frontend compromise | contracts enforce every invariant; app is static and reads addresses from committed JSON; security headers set |
| Timestamp manipulation | sequencer timestamp skew is seconds; at most seconds of accrual |

## Static analysis

`slither . --exclude-informational --exclude-low` reports **0 findings**. Reviewed false positives are
annotated inline with `slither-disable-next-line` and a reason:

- calendar arithmetic (`divide-before-multiply` in DateTimeLib)
- time-of-day modulo (`weak-prng`)
- strict equality on non-balance counters
- the balance-diff pattern around the trusted DEX (`reentrancy-balance`)
- `totalOut` written after the nonReentrant swap

Low findings left: `calls-loop` (≤5 trusted adapter calls), `timestamp` (intended).

## Not in scope / known gaps

- No formal audit yet. Get one before significant TVL.
- No sequencer-uptime feed on Robinhood Chain. The adapter slot exists (`setSequencerFeed`).
- Market holidays must be maintained yearly by the Timelock or guardian (2026–27 preloaded). Early 1 p.m.
  closes are not modelled.
- Uniswap v3 liquidity for stock tokens may be thin. Batches then revert at the oracle floor and are
  retried in smaller chunks or refunded.
