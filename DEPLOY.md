# Deploying Payslice to Robinhood Chain mainnet

Everything below is what **you** run. Nothing here needs a private key in a file, an env var or the shell
history. Foundry keeps keys encrypted in its keystore (`~/.foundry/keystores`), and you type the password when
asked.

Commands are written for **Git Bash / macOS / Linux**. A PowerShell version is at the end.

| | |
|---|---|
| Chain | Robinhood Chain mainnet, chain id **4663**, gas token **ETH** |
| RPC | `https://rpc.mainnet.chain.robinhood.com` (public and rate-limited; a dedicated provider such as Alchemy is better) |
| Explorer / verifier | https://robinhoodchain.blockscout.com (Blockscout, no API key) |
| Estimated deploy cost | about 26.5M gas, roughly **0.0012 ETH** at 0.02 gwei (from the mainnet dry run) |

## 0. Prerequisites

- Foundry (`forge`, `cast`, `anvil`) 1.x, Node 20+ and pnpm 10 (`corepack enable`).
- `pnpm install` at the repo root. Contract libraries are git submodules: `git submodule update --init --recursive`.
- About 0.005 ETH on Robinhood Chain for the deployer, and a little for the keeper.

## 1. Import the keys (once)

```bash
cast wallet import payslice-deployer --interactive
```

```bash
cast wallet import payslice-keeper --interactive
```

Each command asks for the private key and then a password to encrypt it with. Neither is echoed or stored in
plain text.

## 2. Deploy, wire, hand over to the Timelock and verify (one command)

Optional role addresses. Each one defaults to the deployer, but production should use a multisig:

```bash
export PAYSLICE_ADMIN=0xYourMultisig        # Timelock proposer + executor (48h delay on every admin change)
export PAYSLICE_GUARDIAN=0xYourGuardian     # can pause / take safe-direction actions instantly
export PAYSLICE_TREASURY=0xYourTreasury     # receives protocol fees
export PAYSLICE_KEEPER=$(cast wallet address --account payslice-keeper)
```

The deploy + verify command:

```bash
cd contracts && forge script script/Deploy.s.sol:Deploy --rpc-url https://rpc.mainnet.chain.robinhood.com --account payslice-deployer --sender $(cast wallet address --account payslice-deployer) --broadcast --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/ --retries 10 --delay 15 --slow
```

The script:

1. Deploys Timelock (48h), FeeCollector, ProjectTokenHooks, ComplianceRegistry (off), OracleAdapter,
   MarketClock, SliceRouter, DexAdapter (Uniswap v3 SwapRouter02), BatchConverter, PayrollFactory (plus the
   Payroll implementation) and BonusVesting.
2. Wires the Chainlink feeds for USDG and 10 stock tokens. For each stock it reads the Uniswap v3 factory
   on-chain and routes through the deepest USDG pool.
3. Allows USDG as the payroll token, grants `KEEPER_ROLE`, and loads the NYSE 2026–27 holidays.
4. Grants `DEFAULT_ADMIN_ROLE` on every contract to the Timelock, renounces it from the deployer, and asserts
   the handover worked.
5. Writes `contracts/deployments/4663.json` and `app/src/config/generated/4663.json`.
6. Verifies every contract on Blockscout.

> **Note (2026-10-09):** Blockscout's API sits behind a Cloudflare bot challenge that rejected every CLI
> verification request (`forge --verify` and `forge verify-contract`). Verify through the website instead:
> the standard-JSON inputs and exact constructor arguments for the live deployment are in
> [`contracts/verification/`](contracts/verification/README.md).

If verification gets rate-limited, re-run only the verification step:

```bash
cd contracts && forge script script/Deploy.s.sol:Deploy --rpc-url https://rpc.mainnet.chain.robinhood.com --account payslice-deployer --sender $(cast wallet address --account payslice-deployer) --resume --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/ --retries 10 --delay 30
```

Commit `contracts/deployments/4663.json` and `app/src/config/generated/4663.json`. The frontend and keeper
read them.

### Rehearsal (optional, recommended)

This is the same flow that was run before handoff:

```bash
anvil --fork-url https://rpc.mainnet.chain.robinhood.com --chain-id 31337 --port 8547
```

```bash
cd contracts && forge script script/Deploy.s.sol:Deploy --rpc-url http://127.0.0.1:8547 --broadcast --unlocked --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --slow
```

Mainnet dry run. This simulates against live state and sends nothing:

```bash
cd contracts && forge script script/Deploy.s.sol:Deploy --rpc-url https://rpc.mainnet.chain.robinhood.com --sender $(cast wallet address --account payslice-deployer)
```

## 3. Later: enable the $SLCE project token (Timelock, 48h)

Do this after the launchpad launch. `setProjectToken` can be called **once**, and only by the Timelock.

```bash
export TIMELOCK=$(jq -r .timelock contracts/deployments/4663.json)
export HOOKS=$(jq -r .projectTokenHooks contracts/deployments/4663.json)
export SLCE=0xYourLaunchedTokenAddress
export DATA=$(cast calldata "setProjectToken(address)" $SLCE)
export ZERO=0x0000000000000000000000000000000000000000000000000000000000000000
```

Schedule it (signed by `PAYSLICE_ADMIN`; if that is the deployer, use `--account payslice-deployer`):

```bash
cast send $TIMELOCK "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" $HOOKS 0 $DATA $ZERO $ZERO 172800 --rpc-url https://rpc.mainnet.chain.robinhood.com --account payslice-deployer
```

Wait 48 hours, then execute it:

```bash
cast send $TIMELOCK "execute(address,uint256,bytes,bytes32,bytes32)" $HOOKS 0 $DATA $ZERO $ZERO --rpc-url https://rpc.mainnet.chain.robinhood.com --account payslice-deployer
```

If `PAYSLICE_ADMIN` is a Safe, submit the same two calls with the Safe Transaction Builder (to `$TIMELOCK`,
data from `cast calldata "schedule(...)" ...`). Then set `NEXT_PUBLIC_PROJECT_TOKEN=$SLCE` in Vercel and
redeploy the app. See [TOKEN_INTEGRATION.md](TOKEN_INTEGRATION.md).

## 4. Start the keeper

The keeper signs through `cast send --account payslice-keeper`. It never sees the key. For unattended runs,
put the keystore password in a file that only the keeper's OS user can read:

```bash
pnpm install && cd scripts && CHAIN_ID=4663 RPC_URL=https://rpc.mainnet.chain.robinhood.com KEEPER_PASSWORD_FILE=$HOME/.payslice-keeper-pass pnpm start
```

- `pnpm dry` prints the planned transactions without sending them.
- Schedule it weekly during US market hours, e.g. cron `30 15 * * 1` (Mon 15:30 UTC = 10:30/11:30 ET), or
  run `pnpm loop` under systemd/pm2 (checks hourly; conversion only happens while the market is open).
- Set `KEEPER_TX_RPC_URL` to a private/protected RPC if one is available. This further reduces sandwich risk.

## 5. Deploy the app to Vercel

1. Import the repo in Vercel and set **Root Directory = `app`**. Vercel detects Next.js and pnpm.
2. Environment variables:
   - `NEXT_PUBLIC_CHAIN=robinhood`
   - `NEXT_PUBLIC_RPC_URL=<your RPC>` (optional)
   - `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID=<reown project id>` (optional; injected wallets work without it)
   - `NEXT_PUBLIC_PROJECT_TOKEN=` (leave **empty** until step 3 is done)
   - `BLOCKED_COUNTRIES=` (optional geoblock, e.g. `US,CU,IR,KP,SY,RU`)
3. Deploy. Or use the CLI: `cd app && npx vercel --prod`.

## PowerShell equivalents

```powershell
$env:PAYSLICE_KEEPER = (cast wallet address --account payslice-keeper)
```

```powershell
cd contracts; forge script script/Deploy.s.sol:Deploy --rpc-url https://rpc.mainnet.chain.robinhood.com --account payslice-deployer --sender (cast wallet address --account payslice-deployer) --broadcast --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/ --retries 10 --delay 15 --slow
```
