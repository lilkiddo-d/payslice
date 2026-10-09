# $SLCE token integration

Payslice **does not deploy or contain any ERC-20 for the project token.** $SLCE launches separately on a
launchpad. The protocol is fully functional without it. Every token feature stays dormant until the token is
wired in through the Timelock.

## What changes when the token is set

| Feature | Before `setProjectToken` | After |
|---|---|---|
| `ProjectTokenHooks.isActive()` | `false` | `true` (unless the guardian paused hooks) |
| Payroll deposit fee | full `payrollFeeBps` (0.25%) | reduced by the employer's staking tier: ≥10k → −25%, ≥100k → −50%, ≥1M → −100% (assumes 18 decimals; change with `setTiers` via the Timelock) |
| Conversion fees | 100% to treasury | `stakerShareBps` (50%) streamed to stakers in USDG, the rest to treasury |
| `stake` / `unstake` | revert `TokenNotSet` | enabled; each stake locks the whole position for 7 days |
| Frontend | "Stake" page hidden | shown when `NEXT_PUBLIC_PROJECT_TOKEN` is set **and** on-chain `projectToken()` matches |

The discount is computed from the stake of the payroll's **employer** address (`Payroll.employer()`), at
deposit time.

## The wiring

- `contracts/src/ProjectTokenHooks.sol`
  - `setProjectToken(address)`: `DEFAULT_ADMIN_ROLE` only (held by the 48h Timelock). Callable **once**
    (`AlreadySet`). Rejects the zero address and any registered reward token.
  - `feeDiscountBps(account)`: returns 0 while inactive.
  - `notifyReward(token, amount)`: called by FeeCollector with the stakers' share. Rewards that arrive while
    nobody is staked are queued and distributed to the first stakers.
- `PayrollFactory.effectiveFeeBps(employer)` calls `feeDiscountBps` inside a `try/catch`, so a broken hooks
  contract can never block deposits.
- `FeeCollector.receiveFee` routes the staker share only if `hooks.isActive()` and the fee token is a
  registered reward token (USDG is registered at deploy).

No other contract references the token. Withdrawals, streams, conversions and bonuses work the same with or
without it.

## Steps after the launchpad launch

1. Verify the launched token: standard ERC-20, no transfer fee (fee-on-transfer works but rounds), and note its
   decimals. If it isn't 18 decimals, also schedule `setTiers` with scaled thresholds.
2. Schedule `setProjectToken(SLCE)` on the Timelock, wait 48h, then execute. The exact `cast` commands are in
   [DEPLOY.md](DEPLOY.md#3-later-enable-the-slce-project-token-timelock-48h).
3. Set `NEXT_PUBLIC_PROJECT_TOKEN=<address>` in Vercel and redeploy. An empty value hides all token UI.

## Tests

Token behaviour is tested only with a **mock ERC-20** (`test/mocks/Mocks.sol`, `MockERC20`):

- `ProjectTokenHooksTest`: dormant until set, set-once, admin-only, staking lock, rewards, queueing, tiers
- `PayrollTest.test_feeDiscountForStakers`
- `BatchConverterTest.test_stakerShareOfConversionFees`
- `ForkTest.test_fork_timelockGatesProjectToken`: runs the real 48h Timelock flow on a mainnet fork
