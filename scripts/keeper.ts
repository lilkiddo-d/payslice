/**
 * Payslice weekly keeper.
 *
 *   1. auto-harvest: withdraw for workers who opted in (funds always go to the worker)
 *   2. payslips: in the first week of each month, sync every stream so monthly Payslip events are emitted
 *   3. conversion: execute every closed epoch's (epoch, stock) batch during US market hours, chunked so each
 *      swap stays inside the oracle slippage band, with a tight keeper minOut from the Uniswap quoter
 *
 * Signing: the keeper NEVER holds a key. Reads use viem; every transaction is sent with
 *   cast send --account payslice-keeper ...
 * (Foundry keystore). For unattended runs set KEEPER_PASSWORD_FILE to a file readable only by the keeper user.
 *
 * Env:
 *   RPC_URL                 read RPC (default: public Robinhood Chain RPC)
 *   KEEPER_TX_RPC_URL       RPC used to SEND txs; point at a private/protected endpoint if available
 *   CHAIN_ID                4663 (default) or 31337 for the local fork
 *   KEEPER_ACCOUNT          keystore account name (default payslice-keeper)
 *   KEEPER_PASSWORD_FILE    optional, passed to cast --password-file
 *   KEEPER_UNLOCKED_FROM    LOCAL FORK ONLY: send with --unlocked --from <addr> instead of a keystore
 *   MAX_HARVEST             max withdrawals per run (default 200)
 *
 * Flags: --dry-run (print, don't send) · --loop (run hourly forever) · --force-sync (always sync payslips)
 */
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  createPublicClient,
  http,
  parseAbi,
  parseAbiItem,
  encodePacked,
  type Address,
  type PublicClient,
} from "viem";
import { ROBINHOOD_CHAIN, UNISWAP_V3, LOCAL_FORK } from "@payslice/config";

const args = new Set(process.argv.slice(2));
const DRY = args.has("--dry-run");
const CHAIN_ID = Number(process.env.CHAIN_ID || ROBINHOOD_CHAIN.id);
const RPC = process.env.RPC_URL || (CHAIN_ID === LOCAL_FORK.id ? LOCAL_FORK.rpcUrl : ROBINHOOD_CHAIN.rpcUrls.http);
const TX_RPC = process.env.KEEPER_TX_RPC_URL || RPC;
const ACCOUNT = process.env.KEEPER_ACCOUNT || "payslice-keeper";
const MAX_HARVEST = Number(process.env.MAX_HARVEST || 200);
const SYNC_BATCH = 50;
const LOOKBACK_EPOCHS = 4n;

const here = dirname(fileURLToPath(import.meta.url));
const dep = JSON.parse(readFileSync(join(here, "..", "contracts", "deployments", `${CHAIN_ID}.json`), "utf8")) as {
  startBlock: number;
  payrollFactory: Address;
  sliceRouter: Address;
  batchConverter: Address;
  marketClock: Address;
  stablecoin: Address;
  assets: { symbol: string; token: Address; fee: number }[];
};

const factoryAbi = parseAbi([
  "function payrollCount() view returns (uint256)",
  "function payrolls(uint256 offset, uint256 limit) view returns (address[])",
  "function workerPayrolls(address) view returns (address[])",
]);
const payrollAbi = parseAbi([
  "function streamCount() view returns (uint256)",
  "function streamsOf(address) view returns (uint256[])",
  "function withdrawable(uint256) view returns (uint256)",
]);
const converterAbi = parseAbi([
  "function currentEpoch() view returns (uint256)",
  "function batches(uint256, address) view returns (uint256 totalIn, uint256 fee, uint256 executedIn, uint256 totalOut, bool feeTaken, bool finalized, bool refunding)",
  "function conversionFeeBps() view returns (uint256)",
  "function quoteMinOut(address asset, uint256 amountIn) view returns (uint256)",
  "function maxSlippageBps() view returns (uint256)",
]);
const clockAbi = parseAbi(["function isMarketOpen() view returns (bool)"]);
const quoterAbi = parseAbi([
  "function quoteExactInput(bytes path, uint256 amountIn) returns (uint256 amountOut, uint160[] sqrtPriceX96AfterList, uint32[] initializedTicksCrossedList, uint256 gasEstimate)",
]);
const autoHarvestEvent = parseAbiItem("event AutoHarvestSet(address indexed worker, bool enabled)");

const client = createPublicClient({ transport: http(RPC, { retryCount: 5, retryDelay: 1500 }) }) as PublicClient;

const log = (...a: unknown[]) => console.log(new Date().toISOString(), ...a);

/** Sends a tx through Foundry's keystore signer. No key material ever passes through this process. */
function send(to: Address, sig: string, params: (string | bigint | number)[]) {
  const cliArgs = ["send", to, sig, ...params.map(String), "--rpc-url", TX_RPC];
  if (process.env.KEEPER_UNLOCKED_FROM) {
    if (CHAIN_ID !== LOCAL_FORK.id) throw new Error("KEEPER_UNLOCKED_FROM is only allowed on the local fork");
    cliArgs.push("--unlocked", "--from", process.env.KEEPER_UNLOCKED_FROM);
  } else {
    cliArgs.push("--account", ACCOUNT);
    if (process.env.KEEPER_PASSWORD_FILE) cliArgs.push("--password-file", process.env.KEEPER_PASSWORD_FILE);
  }
  if (DRY) {
    log("[dry-run] cast", cliArgs.filter((a) => a !== process.env.KEEPER_PASSWORD_FILE).join(" "));
    return;
  }
  const out = execFileSync("cast", cliArgs, { encoding: "utf8", stdio: ["inherit", "pipe", "inherit"] });
  const hash = out.match(/transactionHash\s+(0x[0-9a-f]{64})/i)?.[1];
  log("  sent", sig, hash ?? out.trim().split("\n")[0]);
}

async function getLogsChunked<T>(fetch: (from: bigint, to: bigint) => Promise<T[]>, chunk = 500_000n) {
  const latest = await client.getBlockNumber();
  const out: T[] = [];
  for (let from = BigInt(dep.startBlock); from <= latest; from += chunk) {
    const to = from + chunk - 1n > latest ? latest : from + chunk - 1n;
    out.push(...(await fetch(from, to)));
  }
  return out;
}

async function harvest() {
  const events = await getLogsChunked((fromBlock, toBlock) =>
    client.getLogs({ address: dep.sliceRouter, event: autoHarvestEvent, fromBlock, toBlock }),
  );
  const optedIn = new Map<Address, boolean>();
  for (const e of events) optedIn.set(e.args.worker!, e.args.enabled!);
  let sent = 0;
  for (const [worker, on] of optedIn) {
    if (!on) continue;
    const payrolls = await client.readContract({ address: dep.payrollFactory, abi: factoryAbi, functionName: "workerPayrolls", args: [worker] });
    for (const p of payrolls) {
      const ids = await client.readContract({ address: p, abi: payrollAbi, functionName: "streamsOf", args: [worker] });
      for (const id of ids) {
        if (sent >= MAX_HARVEST) return log(`harvest: hit MAX_HARVEST=${MAX_HARVEST}`);
        const w = await client.readContract({ address: p, abi: payrollAbi, functionName: "withdrawable", args: [id] });
        if (w === 0n) continue;
        log(`harvest: ${worker} payroll ${p} stream ${id} (${w} base units)`);
        try {
          send(p, "withdraw(uint256)", [id]);
          sent++;
        } catch (e) {
          log("  harvest failed:", (e as Error).message.split("\n")[0]);
        }
      }
    }
  }
  log(`harvest: ${sent} withdrawals`);
}

async function syncPayslips() {
  const n = await client.readContract({ address: dep.payrollFactory, abi: factoryAbi, functionName: "payrollCount" });
  for (let off = 0n; off < n; off += 100n) {
    const list = await client.readContract({ address: dep.payrollFactory, abi: factoryAbi, functionName: "payrolls", args: [off, 100n] });
    for (const p of list) {
      const count = await client.readContract({ address: p, abi: payrollAbi, functionName: "streamCount" });
      for (let start = 1n; start <= count; start += BigInt(SYNC_BATCH)) {
        const ids: bigint[] = [];
        for (let i = start; i < start + BigInt(SYNC_BATCH) && i <= count; i++) ids.push(i);
        log(`payslips: sync ${p} streams ${ids[0]}..${ids[ids.length - 1]}`);
        try {
          send(p, "syncStreams(uint256[])", [`[${ids.join(",")}]`]);
        } catch (e) {
          log("  sync failed:", (e as Error).message.split("\n")[0]);
        }
      }
    }
  }
}

async function quote(asset: { token: Address; fee: number }, amountIn: bigint): Promise<bigint | undefined> {
  try {
    const path = encodePacked(["address", "uint24", "address"], [dep.stablecoin, asset.fee, asset.token]);
    const { result } = await client.simulateContract({
      address: UNISWAP_V3.quoterV2,
      abi: quoterAbi,
      functionName: "quoteExactInput",
      args: [path, amountIn],
    });
    return result[0];
  } catch {
    return undefined;
  }
}

async function convert() {
  const open = await client.readContract({ address: dep.marketClock, abi: clockAbi, functionName: "isMarketOpen" });
  if (!open) return log("convert: US market closed, skipping");
  const cur = await client.readContract({ address: dep.batchConverter, abi: converterAbi, functionName: "currentEpoch" });
  const feeBps = await client.readContract({ address: dep.batchConverter, abi: converterAbi, functionName: "conversionFeeBps" });
  const from = cur > LOOKBACK_EPOCHS ? cur - LOOKBACK_EPOCHS : 0n;
  for (let epoch = from; epoch < cur; epoch++) {
    for (const asset of dep.assets) {
      const b = await client.readContract({ address: dep.batchConverter, abi: converterAbi, functionName: "batches", args: [epoch, asset.token] });
      const [totalIn, fee, executedIn, , feeTaken, finalized, refunding] = b;
      if (totalIn === 0n || finalized || refunding) continue;
      const pendingFee = feeTaken ? fee : (totalIn * feeBps) / 10_000n;
      let remaining = totalIn - pendingFee - executedIn;
      log(`convert: epoch ${epoch} ${asset.symbol} remaining ${remaining}`);
      // chunk until the pool quote clears the oracle floor (halve up to 6 times)
      let chunk = remaining;
      for (let i = 0; i < 6 && remaining > 0n; i++) {
        const floor = await client.readContract({ address: dep.batchConverter, abi: converterAbi, functionName: "quoteMinOut", args: [asset.token, chunk] });
        const q = await quote(asset, chunk);
        if (q !== undefined && q >= floor) {
          // keeper-tightened minOut: quote minus 0.3% (contract enforces the oracle floor on top)
          const minOut = (q * 9_970n) / 10_000n > floor ? (q * 9_970n) / 10_000n : floor;
          const deadline = BigInt(Math.floor(Date.now() / 1000) + 300);
          try {
            send(dep.batchConverter, "executeBatch(uint256,address,uint256,uint256,uint256)", [epoch, asset.token, chunk, minOut, deadline]);
            remaining -= chunk;
            chunk = remaining;
            i = -1; // restart halving budget for the rest
            continue;
          } catch (e) {
            log("  execute failed:", (e as Error).message.split("\n")[0]);
            break;
          }
        }
        log(`  quote ${q ?? "n/a"} below floor ${floor} for chunk ${chunk}; halving`);
        chunk = chunk / 2n;
        if (chunk === 0n) break;
      }
    }
  }
}

async function runOnce() {
  log(`keeper start: chain ${CHAIN_ID} rpc ${RPC}${DRY ? " (dry-run)" : ""}`);
  await harvest();
  const day = new Date().getUTCDate();
  if (day <= 7 || args.has("--force-sync")) await syncPayslips();
  await convert();
  log("keeper done");
}

if (args.has("--loop")) {
  for (;;) {
    await runOnce().catch((e) => log("run failed:", e));
    await new Promise((r) => setTimeout(r, 60 * 60 * 1000));
  }
} else {
  await runOnce();
}
