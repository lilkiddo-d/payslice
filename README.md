# Payslice

Payroll streaming on **Robinhood Chain**. Employers stream stablecoin (USDG) salaries **per second**. Workers
withdraw any time and can automatically convert a **slice** of their pay into tokenized stocks. Conversion
runs in weekly batches during US market hours.

```
employer ──deposit──▶ Payroll (clone) ──per-second accrual──▶ worker.withdraw()
                         │                                       │
                         │ 0.25% fee ─▶ FeeCollector             ├─ 70% USDG ─▶ worker
                         │                                       └─ 30% ─▶ BatchConverter (weekly epoch)
                         ▼                                                  │ closed epoch + market open
                    runway / payslips                         DexAdapter (Uniswap v3) ◀─ OracleAdapter floor
                                                                            ▼
                                                              worker.claim() pro-rata stock tokens
```

## Monorepo

| Path | What |
|---|---|
| `contracts/` | Foundry, Solidity 0.8.28 (`^0.8.24`), OpenZeppelin v5.4: protocol, tests, `script/Deploy.s.sol` |
| `app/` | Next.js 16 + TypeScript + wagmi/viem + RainbowKit: employer dashboard, worker view, slice pie, bonuses, CSV payslips, risk page |
| `scripts/` | Weekly keeper: auto-harvest, monthly payslip sync, batch conversion. Signs via `cast --account payslice-keeper` |
| `config/` | `chains.ts`: chain ID, RPCs, explorer, verifier, USDG, stock tokens, Chainlink feeds, Uniswap, all with source links |
| `docs/` | Architecture notes |

## Contracts

| Contract | Role |
|---|---|
| `PayrollFactory` | Deploys `Payroll` minimal proxies; protocol config; worker/employer indexes; guardian pause |
| `Payroll` | Funding, streams (rate/start/end/cliff), pause/edit/cancel, withdrawals with slice routing, solvency guard (auto-pause when dry), runway warnings, monthly `Payslip` events |
| `StreamMath` (lib) | 1e18 fixed-point accrual and dry-period gaps (O(log n) lookup) |
| `SliceRouter` | Per-worker split (stable % + up to 5 weighted stocks), auto-harvest opt-in, asset listing |
| `BatchConverter` | Weekly epochs, keeper execution during market hours, Chainlink-bounded slippage, chunking, pro-rata claims, refunds |
| `DexAdapter` | Swappable `IDexAdapter`: Uniswap v3 SwapRouter02 with per-pair paths, deadline + minOut |
| `OracleAdapter` | Swappable Chainlink adapter: staleness, sanity, USDG peg, optional sequencer feed |
| `MarketClock` | NYSE regular session with on-chain US DST, holiday calendar, guardian force-close |
| `BonusVesting` | Stock-token bonuses: cliff + linear vesting, revoke returns unvested only |
| `FeeCollector` | Payroll and conversion fees; staker share routed to hooks when the token is active |
| `ProjectTokenHooks` | Dormant $SLCE features: `setProjectToken` (once, Timelock), staking, fee discounts, fee sharing |
| `ComplianceRegistry` | Optional allowlist hook (off by default) for entry actions |
| `Timelock` | OZ TimelockController, ≥ 48h; holds every `DEFAULT_ADMIN_ROLE` |

## Quick start

```bash
git submodule update --init --recursive
```

```bash
corepack enable && pnpm install
```

```bash
cd contracts && forge build && forge test
```

Fork tests run against the live mainnet RPC:

```bash
cd contracts && ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-path "test/fork/*"
```

Run the app against a local mainnet fork:

```bash
anvil --fork-url https://rpc.mainnet.chain.robinhood.com --chain-id 31337 --port 8547
```

```bash
cd contracts && forge script script/Deploy.s.sol:Deploy --rpc-url http://127.0.0.1:8547 --broadcast --unlocked --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --slow
```

```bash
cd app && NEXT_PUBLIC_CHAIN=fork pnpm dev
```

On the fork, use **"Use fork test account"** in the header to act as anvil's unlocked dev account. Signing
happens inside anvil, so there are no keys in the browser. To fund it with ETH and USDG:

```bash
node scripts/fork-fund.mjs 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 100000
```

## Status

| Check | Result |
|---|---|
| Unit + fuzz + invariant tests | ✅ all passing (`forge test`) |
| Fork tests (mainnet RPC, real USDG/stocks/Chainlink/Uniswap) | ✅ 4/4, including a real USDG→AAPL batch swap |
| Line coverage, core contracts | ✅ 96.8–100% per contract (`forge coverage`) |
| Slither high/medium | ✅ 0 findings |
| Full deploy on local mainnet fork | ✅ |
| Mainnet dry run (no broadcast) | ✅ SIMULATION COMPLETE |
| Frontend build | ✅ `next build` |

## Docs

- [DEPLOY.md](DEPLOY.md): the exact commands to deploy, verify, enable the token, run the keeper and ship to Vercel
- [THREAT_MODEL.md](THREAT_MODEL.md): assets, actors, the top risks and how they are mitigated
- [DECISIONS.md](DECISIONS.md): every judgment call, with a one-line reason
- [TOKEN_INTEGRATION.md](TOKEN_INTEGRATION.md): how $SLCE plugs in later (no token is deployed)
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): accounting model and flows

## Compliance

Payslice includes an optional allowlist hook (`ComplianceRegistry`, off by default), an optional frontend
geoblock (`BLOCKED_COUNTRIES`) and a risk disclosure page. Employers remain responsible for tax withholding,
payroll filings and labour-law compliance. Payslice is independent and not affiliated with Robinhood.
