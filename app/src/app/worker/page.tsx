"use client";

import { useEffect, useMemo, useState } from "react";
import { useAccount, usePublicClient } from "wagmi";
import { formatUnits, type Address, type PublicClient } from "viem";
import { payrollAbi, payrollFactoryAbi, sliceRouterAbi, batchConverterAbi, bonusVestingAbi } from "@/abi";
import { Gate } from "@/components/Gate";
import { Pie, PALETTE } from "@/components/Pie";
import { assetMeta, deployment, STABLE } from "@/lib/config";
import { useChainQuery, useNow, useTx } from "@/lib/hooks";
import { fmt, rateXToMonthly, SCALE, short, tsToDate } from "@/lib/format";
import { buildPayslipCsv, downloadCsv } from "@/lib/payslip";

const DEC = STABLE.decimals;

export default function WorkerPage() {
  return (
    <main>
      <h1>My pay</h1>
      <Gate title="Worker view">
        <Worker />
      </Gate>
    </main>
  );
}

interface MyStream {
  payroll: Address;
  payrollName: string;
  id: bigint;
  status: number;
  rateX: bigint;
  start: bigint;
  cliff: bigint;
  end: bigint;
  earned: bigint;
  withdrawable: bigint;
  withdrawn: bigint;
  runway: bigint;
  insolvent: boolean;
  fetchedAt: number;
}

async function loadStreams(c: PublicClient, me: Address): Promise<MyStream[]> {
  const payrolls = (await c.readContract({
    address: deployment.payrollFactory,
    abi: payrollFactoryAbi,
    functionName: "workerPayrolls",
    args: [me],
  })) as Address[];
  const out: MyStream[] = [];
  for (const p of payrolls) {
    const r = (fn: string, args: readonly unknown[] = []) =>
      c.readContract({ address: p, abi: payrollAbi, functionName: fn as never, args: args as never });
    const [ids, name, runway, insolvent] = (await Promise.all([r("streamsOf", [me]), r("name"), r("runwaySeconds"), r("isInsolvent")])) as [
      bigint[],
      string,
      bigint,
      boolean,
    ];
    const rows = await Promise.all(
      ids.map(async (id) => {
        const [s, earned, withdrawable] = (await Promise.all([r("getStream", [id]), r("earned", [id]), r("withdrawable", [id])])) as [
          { status: number; rateX: bigint; start: bigint; cliff: bigint; end: bigint; withdrawn: bigint },
          bigint,
          bigint,
        ];
        return {
          payroll: p,
          payrollName: name,
          id,
          status: Number(s.status),
          rateX: s.rateX,
          start: s.start,
          cliff: s.cliff,
          end: s.end,
          earned,
          withdrawable,
          withdrawn: s.withdrawn,
          runway,
          insolvent,
          fetchedAt: Date.now(),
        };
      }),
    );
    out.push(...rows);
  }
  return out;
}

/** Earned right now, extrapolated per second from the last on-chain read, capped by runway and end. */
function liveEarned(s: MyStream, now: number): bigint {
  if (s.status !== 1 || s.insolvent) return s.earned;
  const from = Math.max(s.fetchedAt, Number(s.start) * 1000);
  let dt = BigInt(Math.max(0, Math.floor((now - from) / 1000)));
  if (dt > s.runway) dt = s.runway;
  if (s.end !== 0n) {
    const left = s.end - BigInt(Math.floor(s.fetchedAt / 1000));
    if (left < dt) dt = left > 0n ? left : 0n;
  }
  return s.earned + (s.rateX * dt) / SCALE;
}

function Worker() {
  const { address } = useAccount();
  const streams = useChainQuery(["myStreams", address], (c) => loadStreams(c, address!));
  return (
    <div className="grid" style={{ gap: 16 }}>
      <LiveTotal streams={streams.data ?? []} />
      {streams.data?.length === 0 && <div className="alert info">No salary streams for {short(address)} yet.</div>}
      {streams.data?.map((s) => (
        <StreamCard key={`${s.payroll}-${s.id}`} s={s} />
      ))}
      <div className="grid cols-2">
        <SliceSettings />
        <Conversions />
      </div>
      <Bonuses />
    </div>
  );
}

function LiveTotal({ streams }: { streams: MyStream[] }) {
  const now = useNow(100);
  const total = streams.reduce((a, s) => a + liveEarned(s, now) - s.withdrawn, 0n);
  const nowSec = BigInt(Math.floor(now / 1000));
  const perSec = streams
    .filter((s) => s.status === 1 && !s.insolvent && s.start <= nowSec && (s.end === 0n || s.end > nowSec))
    .reduce((a, s) => a + s.rateX, 0n);
  // show 6 decimals and a fractional tail so the counter visibly ticks
  const tail = (() => {
    const ms = now % 1000;
    return (perSec * BigInt(ms)) / 1000n / SCALE;
  })();
  return (
    <div className="card">
      <div className="stat">
        <div className="label">Available to withdraw (live)</div>
      </div>
      <div className="counter">
        {Number(formatUnits(total + tail, DEC)).toLocaleString("en-US", { minimumFractionDigits: 6, maximumFractionDigits: 6 })}{" "}
        <span className="muted" style={{ fontSize: 18 }}>
          {STABLE.symbol}
        </span>
      </div>
      <div className="muted small">
        +{fmt((perSec * 3600n) / SCALE, DEC, 4)} per hour · +{fmt((perSec * 86400n) / SCALE, DEC)} per day
      </div>
    </div>
  );
}

function StreamCard({ s }: { s: MyStream }) {
  const tx = useTx();
  const client = usePublicClient();
  const [busyCsv, setBusyCsv] = useState(false);
  const { address } = useAccount();
  const now = useNow(1000);
  const cliffLocked = s.cliff !== 0n && BigInt(Math.floor(now / 1000)) < s.cliff && s.status !== 3;
  return (
    <div className="card">
      <div className="row">
        <h3 style={{ margin: 0 }}>
          {s.payrollName} · stream #{s.id.toString()}
        </h3>
        <span className={`badge ${s.status === 1 ? "ok" : s.status === 2 ? "warn" : "danger"}`}>
          {["", "Active", "Paused", "Cancelled"][s.status]}
        </span>
        {s.insolvent && <span className="badge danger">Payroll unfunded — paused</span>}
        <span className="spacer" />
        <button
          className="btn small secondary"
          disabled={busyCsv}
          onClick={async () => {
            setBusyCsv(true);
            try {
              const csv = await buildPayslipCsv({
                client: client as PublicClient,
                payroll: s.payroll,
                payrollName: s.payrollName,
                streamId: s.id,
                worker: address!,
                decimals: DEC,
                symbol: STABLE.symbol,
              });
              downloadCsv(`payslips-${s.payrollName.replace(/\W+/g, "_")}-${s.id}.csv`, csv);
            } finally {
              setBusyCsv(false);
            }
          }}
        >
          {busyCsv ? "Building CSV…" : "Download payslips (CSV)"}
        </button>
      </div>
      <div className="grid cols-4" style={{ marginTop: 12 }}>
        <div className="stat">
          <div className="label">Monthly</div>
          <div className="value">{fmt(rateXToMonthly(s.rateX), DEC)}</div>
        </div>
        <div className="stat">
          <div className="label">Earned total</div>
          <div className="value">{fmt(liveEarned(s, now), DEC, 4)}</div>
        </div>
        <div className="stat">
          <div className="label">Withdrawn</div>
          <div className="value">{fmt(s.withdrawn, DEC)}</div>
        </div>
        <div className="stat">
          <div className="label">{cliffLocked ? `Cliff until ${tsToDate(s.cliff)}` : "End"}</div>
          <div className="value">{cliffLocked ? "🔒" : tsToDate(s.end)}</div>
        </div>
      </div>
      <div className="row" style={{ marginTop: 12 }}>
        <button
          className="btn"
          disabled={tx.busy || cliffLocked || liveEarned(s, now) - s.withdrawn === 0n}
          onClick={() => tx.send({ address: s.payroll, abi: payrollAbi, functionName: "withdraw", args: [s.id] })}
        >
          {tx.busy ? "Withdrawing…" : "Withdraw"}
        </button>
        <span className="small muted">Your slice rule is applied automatically on every withdrawal.</span>
      </div>
      {tx.error && <div className="error">{tx.error}</div>}
    </div>
  );
}

function SliceSettings() {
  const { address } = useAccount();
  const supported = useChainQuery(["supported"], (c) =>
    c.readContract({ address: deployment.sliceRouter, abi: sliceRouterAbi, functionName: "supportedAssets" }),
  );
  const raw = useChainQuery(["rawAlloc", address], (c) =>
    c.readContract({ address: deployment.sliceRouter, abi: sliceRouterAbi, functionName: "rawAllocationOf", args: [address!] }),
  );
  const assets = useMemo(() => ((supported.data as Address[] | undefined) ?? []).map((a) => ({ a, ...assetMeta(a) })), [supported.data]);
  const [sliceBps, setSliceBps] = useState(0);
  const [weights, setWeights] = useState<Record<string, number>>({});
  const [auto, setAuto] = useState(false);
  const tx = useTx();

  useEffect(() => {
    const r = raw.data as { sliceBps: number; autoHarvest: boolean; assets: Address[]; weights: number[] } | undefined;
    if (!r) return;
    setSliceBps(Number(r.sliceBps));
    setAuto(r.autoHarvest);
    const w: Record<string, number> = {};
    r.assets.forEach((a, i) => (w[a.toLowerCase()] = Number(r.weights[i]) / 100));
    setWeights(w);
  }, [raw.data]);

  const chosen = assets.filter((x) => (weights[x.a.toLowerCase()] ?? 0) > 0);
  const sum = chosen.reduce((a, x) => a + (weights[x.a.toLowerCase()] ?? 0), 0);
  const valid = sliceBps === 0 || (chosen.length > 0 && chosen.length <= 5 && Math.abs(sum - 100) < 1e-9);
  const pie = [
    { label: STABLE.symbol, value: 100 - sliceBps / 100, color: PALETTE[0] },
    ...chosen.map((x, i) => ({
      label: x.symbol,
      value: ((sliceBps / 100) * (weights[x.a.toLowerCase()] ?? 0)) / Math.max(sum, 1),
      color: PALETTE[(i + 1) % PALETTE.length],
    })),
  ];

  return (
    <div className="card">
      <h3>Slice settings</h3>
      <div className="sub">Choose how much of each withdrawal is converted into stock tokens in the weekly batch.</div>
      <Pie slices={pie} />
      <label>Convert to stocks: {(sliceBps / 100).toFixed(0)}%</label>
      <input type="range" min={0} max={10000} step={500} value={sliceBps} onChange={(e) => setSliceBps(Number(e.target.value))} />
      <label>Weights across stocks (must total 100%, up to 5)</label>
      <div className="grid cols-3" style={{ gap: 8 }}>
        {assets.map((x) => (
          <div key={x.a}>
            <label style={{ marginTop: 0 }}>{x.symbol}</label>
            <input
              value={weights[x.a.toLowerCase()] ?? ""}
              placeholder="0"
              inputMode="decimal"
              onChange={(e) => setWeights({ ...weights, [x.a.toLowerCase()]: Number(e.target.value) || 0 })}
            />
          </div>
        ))}
      </div>
      <label className="row">
        <input type="checkbox" checked={auto} onChange={(e) => setAuto(e.target.checked)} /> Auto-harvest: let the weekly keeper
        withdraw for me (funds always go to my wallet)
      </label>
      {!valid && <div className="error">Weights must add up to 100% (now {sum.toFixed(2)}%).</div>}
      <div className="row" style={{ marginTop: 10 }}>
        <button
          className="btn"
          disabled={tx.busy || !valid}
          onClick={async () => {
            const list = sliceBps === 0 ? [] : chosen;
            const ws = list.map((x) => Math.round((weights[x.a.toLowerCase()] / sum) * 10000));
            if (ws.length) ws[ws.length - 1] += 10000 - ws.reduce((a, b) => a + b, 0);
            await tx.send({
              address: deployment.sliceRouter,
              abi: sliceRouterAbi,
              functionName: "setSlice",
              args: [sliceBps, list.map((x) => x.a), ws],
            });
            const r = raw.data as { autoHarvest: boolean } | undefined;
            if (r?.autoHarvest !== auto) {
              await tx.send({ address: deployment.sliceRouter, abi: sliceRouterAbi, functionName: "setAutoHarvest", args: [auto] });
            }
          }}
        >
          {tx.busy ? "Saving…" : "Save slice rule"}
        </button>
      </div>
      {tx.error && <div className="error">{tx.error}</div>}
    </div>
  );
}

interface ConvRow {
  epoch: bigint;
  asset: Address;
  queued: bigint;
  claimable: bigint;
  finalized: boolean;
  refunding: boolean;
  settled: boolean;
}

function Conversions() {
  const { address } = useAccount();
  const tx = useTx();
  const q = useChainQuery(["conversions", address], async (c) => {
    const read = (fn: string, args: readonly unknown[] = []) =>
      c.readContract({ address: deployment.batchConverter, abi: batchConverterAbi, functionName: fn as never, args: args as never });
    const [cur, supported] = (await Promise.all([
      read("currentEpoch"),
      c.readContract({ address: deployment.sliceRouter, abi: sliceRouterAbi, functionName: "supportedAssets" }),
    ])) as unknown as [bigint, readonly Address[]];
    const from = cur > 8n ? cur - 8n : 0n;
    const rows: ConvRow[] = [];
    for (let e = from; e <= cur; e++) {
      for (const a of supported) {
        const queued = (await read("userIn", [e, a, address])) as bigint;
        if (queued === 0n) continue;
        const [b, claimable, settled] = (await Promise.all([read("batches", [e, a]), read("claimable", [e, a, address]), read("settled", [e, a, address])])) as [
          readonly [bigint, bigint, bigint, bigint, boolean, boolean, boolean],
          bigint,
          boolean,
        ];
        rows.push({ epoch: e, asset: a, queued, claimable, finalized: b[5], refunding: b[6], settled });
      }
    }
    return { cur, rows };
  });
  return (
    <div className="card">
      <h3>Stock conversions</h3>
      <div className="sub">
        Slices are pooled per week and converted in one batch during US market hours. Current week #{q.data?.cur.toString() ?? "…"}.
      </div>
      {!q.data?.rows.length ? (
        <p className="muted">Nothing queued yet.</p>
      ) : (
        <table>
          <thead>
            <tr>
              <th>Week</th>
              <th>Stock</th>
              <th>Queued</th>
              <th>Status</th>
              <th />
            </tr>
          </thead>
          <tbody>
            {q.data.rows.map((r) => (
              <tr key={`${r.epoch}-${r.asset}`}>
                <td>#{r.epoch.toString()}</td>
                <td>{assetMeta(r.asset).symbol}</td>
                <td>
                  {fmt(r.queued, DEC)} {STABLE.symbol}
                </td>
                <td>
                  {r.settled ? "Claimed" : r.finalized ? `${Number(formatUnits(r.claimable, 18)).toFixed(6)} ready` : r.refunding ? "Refund open" : r.epoch === q.data!.cur ? "Collecting" : "Awaiting batch"}
                </td>
                <td>
                  {!r.settled && r.finalized && (
                    <button
                      className="btn small"
                      disabled={tx.busy}
                      onClick={() => tx.send({ address: deployment.batchConverter, abi: batchConverterAbi, functionName: "claim", args: [r.epoch, r.asset, address!] })}
                    >
                      Claim
                    </button>
                  )}
                  {!r.settled && r.refunding && (
                    <button
                      className="btn small secondary"
                      disabled={tx.busy}
                      onClick={() => tx.send({ address: deployment.batchConverter, abi: batchConverterAbi, functionName: "refund", args: [r.epoch, r.asset, address!] })}
                    >
                      Refund
                    </button>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      {tx.error && <div className="error">{tx.error}</div>}
    </div>
  );
}

function Bonuses() {
  const { address } = useAccount();
  const tx = useTx();
  const now = useNow(5000);
  const q = useChainQuery(["bonuses", address], async (c) => {
    const read = (fn: string, args: readonly unknown[]) =>
      c.readContract({ address: deployment.bonusVesting, abi: bonusVestingAbi, functionName: fn as never, args: args as never });
    const ids = (await read("grantsOfWorker", [address])) as bigint[];
    return Promise.all(
      ids.map(async (id) => {
        const [g, vested, claimable] = (await Promise.all([read("getGrant", [id]), read("vested", [id]), read("claimableOf", [id])])) as [
          { token: Address; total: bigint; claimed: bigint; start: bigint; cliff: bigint; duration: bigint; revokedAt: bigint; employer: Address },
          bigint,
          bigint,
        ];
        return { id, g, vested, claimable };
      }),
    );
  });
  if (!q.data?.length) return null;
  return (
    <div className="card">
      <h3>Stock bonuses</h3>
      <table>
        <thead>
          <tr>
            <th>#</th>
            <th>Stock</th>
            <th>Total</th>
            <th>Vested</th>
            <th>Claimable</th>
            <th>Cliff</th>
            <th>Fully vested</th>
            <th>Progress</th>
            <th />
          </tr>
        </thead>
        <tbody>
          {q.data.map(({ id, g, vested, claimable }) => {
            const end = Number(g.start + g.duration);
            const pct = g.total === 0n ? 0 : Number((vested * 10000n) / g.total) / 100;
            return (
              <tr key={id.toString()}>
                <td>{id.toString()}</td>
                <td>{assetMeta(g.token).symbol}</td>
                <td>{fmt(g.total, 18, 4)}</td>
                <td>{fmt(vested, 18, 4)}</td>
                <td>{fmt(claimable, 18, 4)}</td>
                <td>{tsToDate(g.cliff)}</td>
                <td>{g.revokedAt !== 0n ? "revoked" : tsToDate(end)}</td>
                <td>{now / 1000 < Number(g.cliff) ? "cliff" : `${pct.toFixed(1)}%`}</td>
                <td>
                  <button
                    className="btn small"
                    disabled={tx.busy || claimable === 0n}
                    onClick={() => tx.send({ address: deployment.bonusVesting, abi: bonusVestingAbi, functionName: "claim", args: [id] })}
                  >
                    Claim
                  </button>
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
      {tx.error && <div className="error">{tx.error}</div>}
    </div>
  );
}
