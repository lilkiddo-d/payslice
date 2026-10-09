# Decisions log

One line each: decision — reason.

## Chain & integrations
- **Stablecoin = USDG** (`0x5fc5…d168`, 6 dp): it is the only stablecoin on Robinhood's official contracts page, it has a Chainlink USD feed, and it has deep USDG/stock pools on Uniswap v3.
- **Stock tokens from Robinhood's official Stock Token API** (`api.robinhood.com/rhj/assets`), cross-checked on-chain: the docs contracts page renders that list dynamically.
- **10 launch assets** (AAPL, MSFT, NVDA, TSLA, AMZN, GOOGL, META, COIN, SPY, QQQ): each has an official token, a Chainlink feed and a USDG Uniswap v3 pool. More can be listed via the Timelock.
- **Oracles = Chainlink** (Robinhood docs name Chainlink as the price source). Addresses come from Chainlink's directory feed `feeds-robinhood-mainnet.json`.
- **No sequencer-uptime feed** exists for Robinhood Chain (Chainlink stopped adding them). OracleAdapter keeps an optional slot instead of faking one.
- **DEX = Uniswap v3 SwapRouter02** behind a swappable `IDexAdapter`: official deployments exist and USDG/stock pools have liquidity. v4/RFQ/Rialto/Lighter adapters can replace it without touching other contracts.
- **The deepest pool per stock is chosen on-chain at deploy time** (liquidity across 100/500/3000/10000 fee tiers), so no fee tier is guessed or hardcoded.
- **Feed staleness 25h** (heartbeat 24h + 1h buffer). Conversion only runs in market hours, when 24/5 feeds update.
- **USDG depeg guard 1%**: a conversion during a depeg would misprice every worker's slice.
- **Verification via Blockscout** with CLI flags (no `[etherscan]` block in foundry.toml): with the block present, forge hammers Blockscout for trace decoding and trips Cloudflare.

## Protocol design
- **Reservation accounting (LlamaPay-style global settle + lazy per-stream sync)**: O(1) solvency without looping over streams, and it makes "accrued ≤ funded" structural.
- **Per-stream start/end/cliff with a conservative global rate**: streams count toward the burn rate from creation; over-reservation is released when the stream syncs. This keeps runway conservative, never optimistic.
- **Running dry = true auto-pause, no back-pay**: the spec says streams "auto-pause". Dry periods are stored as gaps (sorted, prefix sums, O(log n) lookup), so no stream loop is needed on resume.
- **Auto-resume when ≥ 1 second of runway is available**: the simplest rule that never goes negative.
- **1e18 fixed-point scaling** for rates/accruals; floor only on payout: rounding drift < 1 unit per stream.
- **Monthly payslip events emitted lazily during sync** (any touch, or the keeper's monthly `syncStreams`): no unbounded loops, and the event content is exact because the rate is constant between checkpoints. Long-idle streams get ≤ 12 monthly slips plus one catch-up slip.
- **Payroll fee is charged on deposit (0.25%), not on withdrawals**: worker pay is never reduced by protocol fees.
- **The slice is applied on withdrawal, not continuously**: keeps Payroll simple. Auto-harvest lets the keeper trigger withdrawals so slices still flow weekly.
- **Weekly epochs, closed-epoch-only execution, pro-rata pull claims**: removes deposit-timing games and per-worker loops. "Exactly their share" = `floor(in_i·out/in)`.
- **Oracle floor always enforced on top of the keeper minOut**: the keeper can tighten but never loosen price protection.
- **Refund path after 4 weeks**: conversion can stall (market closed, feed paused, thin pools); funds must never get stuck.
- **Conversion fee 0.30%, taken once per batch from gross input**: everyone in a batch pays the same rate, and claims remain a simple ratio.
- **Cliff = withdrawal lock, not an accrual lock; waived on cancel**: otherwise cancelling before the cliff would be a clawback.
- **Cliff can only be reduced, end can't be in the past**: blocks retroactive edits.
- **Guardian pause never blocks withdrawals or claims**: pausing earned pay is functionally a clawback.
- **Guardian may act only in the safe direction** (pause, force market closed, disable feed, de-list, add holiday); reversing requires the Timelock.
- **Timelock = OZ TimelockController with MIN_DELAY 48h enforced in the constructor**, proposer/executor = `PAYSLICE_ADMIN` (defaults to the deployer; a multisig is recommended).
- **AccessControl everywhere** (not Ownable): matches the guardian/keeper/admin split and hands over cleanly to the Timelock.
- **ReentrancyGuardTransient** (EIP-1153): works in clones without initialisation, cheaper, and Robinhood Chain supports Cancun (Uniswap v4 is deployed there).
- **Solidity 0.8.28 / EVM cancun / no via-IR**: stable and transient storage are available; avoiding via-IR keeps coverage reliable.
- **Compliance hook gates entry actions only** and is off by default: it can satisfy allowlist requirements without enabling wage freezes.
- **Factory keeps worker→payroll and employer→payroll indexes**: the frontend works on a rate-limited public RPC without scanning logs.
- **BonusVesting requires assets listed in SliceRouter**: one allowlist for "supported stock tokens".

## Project token ($SLCE)
- **No token is deployed**; `ProjectTokenHooks.setProjectToken` can be called once, by the Timelock only: per spec.
- **Staking lock 7 days per stake**: blocks flash-staking for fee discounts or fee share.
- **Discount tiers 10k/100k/1M → 25/50/100%** of the payroll fee (assuming an 18-decimal token): sensible defaults, adjustable via the Timelock.
- **Stakers get 50% of conversion fees** in USDG via an accumulator (precision 1e36): tokens with different decimals share fairly. Rewards received with zero stakers are queued, not lost.

## Tooling
- **Foundry keystore only** (`--account payslice-deployer`, keeper via `cast send --account payslice-keeper`): no private keys in env/files.
- **Deploy script writes deployment JSON only when broadcasting** (dry runs write `dryrun-<id>.json`): a simulation must never overwrite real addresses.
- **Local fork uses chain id 31337 on port 8547**: a separate id avoids clobbering mainnet config; 8545 was already taken on the dev machine.
- **wagmi 2 + RainbowKit 2** (not wagmi 3): RainbowKit 2.2.x peers on wagmi ^2.
- **wagmi `mock` connector with anvil's unlocked accounts, fork mode only**: the app can be exercised end-to-end locally without any keys in the browser.
- **CSV payslips built client-side from `Payslip` + `Withdrawn` events** (chunked `eth_getLogs` from the deploy block): no backend.
- **Geoblock via Next.js proxy and `x-vercel-ip-country`**, off unless `BLOCKED_COUNTRIES` is set.
- **Brand avoids Robinhood's name/logo** ("Robinhood Chain" appears only as the network name, with a no-affiliation notice).
