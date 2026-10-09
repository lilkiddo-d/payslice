import { parseAbiItem, type Address, type PublicClient } from "viem";
import { LOG_CHUNK, deployment } from "./config";

const payslipEvent = parseAbiItem(
  "event Payslip(uint256 indexed streamId, address indexed worker, uint64 periodStart, uint64 periodEnd, uint256 earned, uint256 cumulativeEarned, uint256 cumulativeWithdrawn)",
);
const withdrawnEvent = parseAbiItem(
  "event Withdrawn(uint256 indexed streamId, address indexed worker, uint256 amount, uint256 stablePart, uint256 slicePart)",
);

async function chunkedLogs<T>(
  client: PublicClient,
  fetch: (from: bigint, to: bigint) => Promise<T[]>,
): Promise<T[]> {
  const latest = await client.getBlockNumber();
  const start = BigInt(deployment.startBlock ?? 0);
  const out: T[] = [];
  for (let from = start; from <= latest; from += LOG_CHUNK) {
    const to = from + LOG_CHUNK - 1n > latest ? latest : from + LOG_CHUNK - 1n;
    out.push(...(await fetch(from, to)));
  }
  return out;
}

const iso = (t: bigint) => new Date(Number(t) * 1000).toISOString().slice(0, 10);
const units = (v: bigint, d: number) => {
  const s = v.toString().padStart(d + 1, "0");
  return `${s.slice(0, -d)}.${s.slice(-d)}`;
};

/**
 * Builds a payslip CSV for one stream from on-chain events:
 *  - one PAYSLIP row per completed month (Payslip events emitted by Payroll)
 *  - one WITHDRAWAL row per withdrawal (stablecoin part vs. part routed to stock conversion)
 */
export async function buildPayslipCsv(opts: {
  client: PublicClient;
  payroll: Address;
  payrollName: string;
  streamId: bigint;
  worker: Address;
  decimals: number;
  symbol: string;
}): Promise<string> {
  const { client, payroll, streamId, worker, decimals, symbol, payrollName } = opts;
  const slips = await chunkedLogs(client, (fromBlock, toBlock) =>
    client.getLogs({ address: payroll, event: payslipEvent, args: { streamId, worker }, fromBlock, toBlock }),
  );
  const wds = await chunkedLogs(client, (fromBlock, toBlock) =>
    client.getLogs({ address: payroll, event: withdrawnEvent, args: { streamId, worker }, fromBlock, toBlock }),
  );

  const rows: string[][] = [
    ["type", "period_start", "period_end", "earned", "cumulative_earned", "cumulative_withdrawn", "paid_in_stablecoin", "routed_to_stocks", "currency", "employer_payroll", "payroll_name", "stream_id", "worker", "tx_hash"],
  ];
  for (const l of slips) {
    const a = l.args;
    rows.push([
      "PAYSLIP",
      iso(a.periodStart!),
      iso(a.periodEnd!),
      units(a.earned!, decimals),
      units(a.cumulativeEarned!, decimals),
      units(a.cumulativeWithdrawn!, decimals),
      "",
      "",
      symbol,
      payroll,
      payrollName,
      streamId.toString(),
      worker,
      l.transactionHash ?? "",
    ]);
  }
  for (const l of wds) {
    const a = l.args;
    const block = await client.getBlock({ blockNumber: l.blockNumber! });
    rows.push([
      "WITHDRAWAL",
      iso(block.timestamp),
      iso(block.timestamp),
      units(a.amount!, decimals),
      "",
      "",
      units(a.stablePart!, decimals),
      units(a.slicePart!, decimals),
      symbol,
      payroll,
      payrollName,
      streamId.toString(),
      worker,
      l.transactionHash ?? "",
    ]);
  }
  return rows.map((r) => r.map((c) => (/[",\n]/.test(c) ? `"${c.replace(/"/g, '""')}"` : c)).join(",")).join("\n");
}

export function downloadCsv(filename: string, csv: string) {
  const blob = new Blob([csv], { type: "text/csv;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}
