# Architecture

## Payroll accounting

All amounts inside `Payroll` are scaled by 1e18 (`…X` suffix). Token units appear only at the edges
(`deposit`, `withdraw`, `withdrawUnallocated`).

```
unallocatedX ──(every second: totalRateX)──▶ reserved ──(stream sync)──▶ earnedX ──withdraw──▶ worker
      ▲                                          │
      └──────── released (before start / after end) ◀┘
```

- **Global settle** (`_settle`, O(1)): `need = totalRateX × (now − paidUntil)`. If `need ≤ unallocatedX`, the
  payroll is paid until now. Otherwise only whole affordable seconds are reserved, `paidUntil` stops at the
  depletion second, and `insolvent = true` (emits `RanDry`).
- **Stream sync** (`_syncStream`, O(1) + payslip months): over `[checkpoint, paidUntil)`, a counted stream
  turns `rate × activeSeconds` of reservation into `earnedX` for the part inside `[start, end)`. The rest is
  released. When `paidUntil ≥ end`, the stream leaves `totalRateX` (`StreamEnded`).
- **Dry periods**: a deposit (or a release) that restores ≥ 1 second of runway records a gap
  `[paidUntil, now)` and resumes. `activeSeconds(a, b) = (b − a) − gapSeconds(a, b)`, where gap seconds come
  from a binary search over sorted gaps with prefix sums.
- **Invariant**: `balance × 1e18 ≥ unallocatedX + Σ (earnedX − withdrawn × 1e18) + Σ unsynced reservations`.

## Payslips

Each time a stream syncs across a UTC month boundary, `Payslip(streamId, worker, periodStart, periodEnd, earned,
cumulativeEarned, cumulativeWithdrawn)` is emitted for each completed month (≤ 12 per sync, then one catch-up
slip). The keeper calls `syncStreams` in the first week of every month, so every stream gets its monthly slip.
`cancelStream` emits a final partial-month slip. The app builds a CSV from `Payslip` + `Withdrawn` events.

## Slice conversion

1. `Payroll.withdraw` → `SliceRouter.split(worker, amount)` → the slice goes to `BatchConverter.deposit` (in a
   try/catch; on failure the whole amount is paid in USDG).
2. Deposits are credited to `(currentEpoch, stock, worker)` by weight.
3. After the epoch closes (7 days from converter genesis), during the NYSE session, the keeper calls
   `executeBatch(epoch, stock, chunk, minOut, deadline)`. The contract takes the fee once, computes
   `oracleMin = in × pUSDG / pStock × (1 − maxSlippage)`, swaps through `DexAdapter`, and records `totalOut`.
4. When fully executed, workers `claim(epoch, stock, worker)`: `out_i = in_i × totalOut / totalIn`.
5. If an epoch is still not executed 4 weeks after it closed, `openRefunds` → `refund` returns the unconverted
   input plus any already-converted output, pro-rata.

## Roles

```
Timelock (48h) ── DEFAULT_ADMIN_ROLE on all 10 AccessControl contracts
Guardian ──────── pause/unpause; safe-direction switches (de-list, disable feed, force close, add holiday)
Keeper ────────── BatchConverter.KEEPER_ROLE
Compliance op ─── ComplianceRegistry.COMPLIANCE_ROLE (allowlist edits; enabling needs the Timelock)
```

## Local fork tips

To fund the fork test account with ETH and USDG, the script impersonates the largest EOA USDG holder. It
refuses to run on any chain other than 31337:

```bash
node scripts/fork-fund.mjs 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 100000
```

Time travel on the fork (e.g. to close an epoch):

```bash
cast rpc evm_increaseTime 604800 --rpc-url http://127.0.0.1:8547 && cast rpc evm_mine --rpc-url http://127.0.0.1:8547
```
