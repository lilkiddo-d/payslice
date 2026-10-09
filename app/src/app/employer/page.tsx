"use client";

import { useMemo, useState } from "react";
import { useAccount } from "wagmi";
import { erc20Abi, isAddress, type Address, type PublicClient } from "viem";
import { payrollAbi, payrollFactoryAbi, bonusVestingAbi, sliceRouterAbi } from "@/abi";
import { Gate } from "@/components/Gate";
import { assetMeta, deployment, explorerAddress, STABLE } from "@/lib/config";
import { useChainQuery, useTx } from "@/lib/hooks";
import { dateToTs, fmt, fmtDuration, monthlyToRateX, parse, rateXToMonthly, short, tsToDate } from "@/lib/format";

const STATUS = ["None", "Active", "Paused", "Cancelled"] as const;
const DEC = STABLE.decimals;

export default function EmployerPage() {
  return (
    <main>
      <h1>Employer dashboard</h1>
      <Gate title="Employer dashboard">
        <Employer />
      </Gate>
    </main>
  );
}

function Employer() {
  const { address } = useAccount();
  const [selected, setSelected] = useState<Address | undefined>();
  const payrolls = useChainQuery(["payrollsOf", address], async (c) => {
    const list = (await c.readContract({
      address: deployment.payrollFactory,
      abi: payrollFactoryAbi,
      functionName: "payrollsOf",
      args: [address!],
    })) as Address[];
    const unique = [...new Set(list)];
    const rows = await Promise.all(
      unique.map(async (p) => {
        const [name, employer] = await Promise.all([
          c.readContract({ address: p, abi: payrollAbi, functionName: "name" }),
          c.readContract({ address: p, abi: payrollAbi, functionName: "employer" }),
        ]);
        return { address: p, name: name as string, employer: employer as Address };
      }),
    );
    return rows.filter((r) => r.employer.toLowerCase() === address!.toLowerCase());
  });

  const current = selected ?? payrolls.data?.[0]?.address;

  return (
    <div className="grid" style={{ gap: 20 }}>
      <div className="row">
        {payrolls.data?.map((p) => (
          <button
            key={p.address}
            className={`btn small ${p.address === current ? "" : "secondary"}`}
            onClick={() => setSelected(p.address)}
          >
            {p.name}
          </button>
        ))}
        <span className="spacer" />
        <CreatePayroll onCreated={(a) => setSelected(a)} />
      </div>
      {payrolls.isLoading && <p className="muted">Loading payrolls…</p>}
      {payrolls.data && payrolls.data.length === 0 && (
        <div className="alert info">No payroll yet. Create one to start streaming salaries.</div>
      )}
      {current && <PayrollView payroll={current} />}
    </div>
  );
}

function CreatePayroll({ onCreated }: { onCreated: (a: Address) => void }) {
  const [name, setName] = useState("");
  const tx = useTx();
  const { address } = useAccount();
  const payrollsCount = useChainQuery(["payrollsOf-len", address], async (c) =>
    ((await c.readContract({ address: deployment.payrollFactory, abi: payrollFactoryAbi, functionName: "payrollsOf", args: [address!] })) as Address[]),
  );
  return (
    <div className="row">
      <input style={{ width: 220 }} placeholder="Company name" value={name} onChange={(e) => setName(e.target.value)} />
      <button
        className="btn"
        disabled={!name || tx.busy}
        onClick={async () => {
          await tx.send({
            address: deployment.payrollFactory,
            abi: payrollFactoryAbi,
            functionName: "createPayroll",
            args: [deployment.stablecoin, name],
          });
          const r = await payrollsCount.refetch();
          const list = r.data ?? [];
          if (list.length) onCreated(list[list.length - 1]);
          setName("");
        }}
      >
        {tx.busy ? "Creating…" : "New payroll"}
      </button>
      {tx.error && <div className="error">{tx.error}</div>}
    </div>
  );
}

interface StreamRow {
  id: bigint;
  worker: Address;
  status: number;
  start: bigint;
  end: bigint;
  cliff: bigint;
  rateX: bigint;
  earned: bigint;
  withdrawn: bigint;
}

async function loadPayroll(c: PublicClient, p: Address) {
  const read = (functionName: string, args: readonly unknown[] = []) =>
    c.readContract({ address: p, abi: payrollAbi, functionName: functionName as never, args: args as never });
  const [name, unallocated, burnRateX, runway, insolvent, warnDays, count, deposited, paid, lowRunway] = (await Promise.all([
    read("name"),
    read("unallocated"),
    read("burnRateX"),
    read("runwaySeconds"),
    read("isInsolvent"),
    read("warnDays"),
    read("streamCount"),
    read("totalDeposited"),
    read("totalWithdrawnByWorkers"),
    read("isLowRunway"),
  ])) as [string, bigint, bigint, bigint, boolean, number, bigint, bigint, bigint, boolean];
  const n = Number(count > 200n ? 200n : count);
  const streams: StreamRow[] = await Promise.all(
    Array.from({ length: n }, async (_, i) => {
      const id = BigInt(i + 1);
      const [s, earned] = (await Promise.all([read("getStream", [id]), read("earned", [id])])) as [
        { worker: Address; status: number; start: bigint; end: bigint; cliff: bigint; rateX: bigint; withdrawn: bigint },
        bigint,
      ];
      return { id, worker: s.worker, status: Number(s.status), start: s.start, end: s.end, cliff: s.cliff, rateX: s.rateX, earned, withdrawn: s.withdrawn };
    }),
  );
  const balance = (await c.readContract({ address: deployment.stablecoin, abi: erc20Abi, functionName: "balanceOf", args: [p] })) as bigint;
  return { name, unallocated, burnRateX, runway, insolvent, warnDays, streams, deposited, paid, lowRunway, balance };
}

function PayrollView({ payroll }: { payroll: Address }) {
  const q = useChainQuery(["payroll", payroll], (c) => loadPayroll(c, payroll));
  const d = q.data;
  const team = d?.streams.filter((s) => s.status === 1).length ?? 0;
  const monthlyBurn = d ? rateXToMonthly(d.burnRateX) : undefined;
  const owed = d?.streams.reduce((a, s) => a + (s.earned - s.withdrawn), 0n);

  return (
    <div className="grid" style={{ gap: 16 }}>
      <div className="row">
        <h2 style={{ margin: 0 }}>{d?.name ?? "…"}</h2>
        <a className="small mono" href={explorerAddress(payroll)} target="_blank" rel="noreferrer">
          {short(payroll)}
        </a>
      </div>
      {d?.insolvent && (
        <div className="alert danger">
          This payroll has run dry. All streams are auto-paused (no worker earns while unfunded). Fund it to resume —
          the dry period is not back-paid.
        </div>
      )}
      {d && !d.insolvent && d.lowRunway && (
        <div className="alert warn">
          Low runway: the balance covers {fmtDuration(d.runway)} of streams, below your {d.warnDays}-day threshold.
        </div>
      )}
      <div className="grid cols-4">
        <Stat label="Active team" value={team.toString()} />
        <Stat label="Monthly burn" value={`${fmt(monthlyBurn, DEC)} ${STABLE.symbol}`} />
        <Stat label="Runway" value={d ? (d.insolvent ? "0 — dry" : fmtDuration(d.runway)) : "—"} />
        <Stat label="Unallocated" value={`${fmt(d?.unallocated, DEC)} ${STABLE.symbol}`} />
        <Stat label="Balance held" value={`${fmt(d?.balance, DEC)} ${STABLE.symbol}`} />
        <Stat label="Owed to workers now" value={`${fmt(owed, DEC)} ${STABLE.symbol}`} />
        <Stat label="Deposited (net)" value={`${fmt(d?.deposited, DEC)} ${STABLE.symbol}`} />
        <Stat label="Paid out" value={`${fmt(d?.paid, DEC)} ${STABLE.symbol}`} />
      </div>
      <div className="grid cols-2">
        <Fund payroll={payroll} />
        <AddStream payroll={payroll} />
      </div>
      <Team payroll={payroll} streams={d?.streams ?? []} />
      <div className="grid cols-2">
        <Treasury payroll={payroll} unallocated={d?.unallocated} warnDays={d?.warnDays} />
        <GrantBonus />
      </div>
    </div>
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div className="card stat">
      <div className="label">{label}</div>
      <div className="value">{value}</div>
    </div>
  );
}

function Fund({ payroll }: { payroll: Address }) {
  const [amount, setAmount] = useState("");
  const tx = useTx();
  const { address } = useAccount();
  const bal = useChainQuery(["bal", address], (c) =>
    c.readContract({ address: deployment.stablecoin, abi: erc20Abi, functionName: "balanceOf", args: [address!] }),
  );
  const fee = useChainQuery(["fee", address], (c) =>
    c.readContract({ address: deployment.payrollFactory, abi: payrollFactoryAbi, functionName: "effectiveFeeBps", args: [address!] }),
  );
  const amt = parse(amount, DEC);
  return (
    <div className="card">
      <h3>Fund payroll</h3>
      <div className="sub">
        Wallet: {fmt(bal.data as bigint | undefined, DEC)} {STABLE.symbol} · protocol fee {Number(fee.data ?? 0n) / 100}%
      </div>
      <label>Amount ({STABLE.symbol})</label>
      <input value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="10000" inputMode="decimal" />
      <div className="row" style={{ marginTop: 12 }}>
        <button
          className="btn"
          disabled={tx.busy || amt === 0n}
          onClick={async () => {
            await tx.ensureAllowance(deployment.stablecoin, payroll, amt);
            await tx.send({ address: payroll, abi: payrollAbi, functionName: "deposit", args: [amt] });
            setAmount("");
          }}
        >
          {tx.busy ? "Confirming…" : "Approve & deposit"}
        </button>
      </div>
      {tx.error && <div className="error">{tx.error}</div>}
    </div>
  );
}

function AddStream({ payroll }: { payroll: Address }) {
  const [worker, setWorker] = useState("");
  const [monthly, setMonthly] = useState("");
  const [start, setStart] = useState("");
  const [end, setEnd] = useState("");
  const [cliff, setCliff] = useState("");
  const tx = useTx();
  const rateX = monthlyToRateX(parse(monthly, DEC));
  const valid = isAddress(worker) && rateX > 0n;
  return (
    <div className="card">
      <h3>Add stream</h3>
      <div className="sub">Salary accrues every second; workers can withdraw any time.</div>
      <label>Worker address</label>
      <input value={worker} onChange={(e) => setWorker(e.target.value.trim())} placeholder="0x…" />
      <label>Monthly salary ({STABLE.symbol})</label>
      <input value={monthly} onChange={(e) => setMonthly(e.target.value)} placeholder="5000" inputMode="decimal" />
      <div className="grid cols-3" style={{ gap: 8 }}>
        <div>
          <label>Start (optional)</label>
          <input type="datetime-local" value={start} onChange={(e) => setStart(e.target.value)} />
        </div>
        <div>
          <label>End (optional)</label>
          <input type="datetime-local" value={end} onChange={(e) => setEnd(e.target.value)} />
        </div>
        <div>
          <label>Cliff (optional)</label>
          <input type="datetime-local" value={cliff} onChange={(e) => setCliff(e.target.value)} />
        </div>
      </div>
      <div className="row" style={{ marginTop: 12 }}>
        <button
          className="btn"
          disabled={!valid || tx.busy}
          onClick={async () => {
            await tx.send({
              address: payroll,
              abi: payrollAbi,
              functionName: "createStream",
              args: [worker as Address, rateX, dateToTs(start), dateToTs(end), dateToTs(cliff)],
            });
            setWorker("");
            setMonthly("");
          }}
        >
          {tx.busy ? "Confirming…" : "Start stream"}
        </button>
        {rateX > 0n && <span className="small muted">≈ {fmt((rateX * 86400n) / 10n ** 18n, DEC)} / day</span>}
      </div>
      {tx.error && <div className="error">{tx.error}</div>}
    </div>
  );
}

function Team({ payroll, streams }: { payroll: Address; streams: StreamRow[] }) {
  const tx = useTx();
  const [editing, setEditing] = useState<bigint | null>(null);
  const [newMonthly, setNewMonthly] = useState("");
  const [newEnd, setNewEnd] = useState("");
  const act = (fn: string, id: bigint) => tx.send({ address: payroll, abi: payrollAbi, functionName: fn, args: [id] });
  return (
    <div className="card">
      <h3>Team</h3>
      {streams.length === 0 ? (
        <p className="muted">No streams yet.</p>
      ) : (
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>#</th>
                <th>Worker</th>
                <th>Monthly</th>
                <th>Start</th>
                <th>End</th>
                <th>Cliff</th>
                <th>Earned</th>
                <th>Withdrawn</th>
                <th>Status</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {streams.map((s) => (
                <tr key={s.id.toString()}>
                  <td>{s.id.toString()}</td>
                  <td className="mono">{short(s.worker)}</td>
                  <td>{fmt(rateXToMonthly(s.rateX), DEC)}</td>
                  <td>{tsToDate(s.start)}</td>
                  <td>{tsToDate(s.end)}</td>
                  <td>{tsToDate(s.cliff)}</td>
                  <td>{fmt(s.earned, DEC)}</td>
                  <td>{fmt(s.withdrawn, DEC)}</td>
                  <td>
                    <span className={`badge ${s.status === 1 ? "ok" : s.status === 2 ? "warn" : "danger"}`}>{STATUS[s.status]}</span>
                  </td>
                  <td>
                    {s.status !== 3 && (
                      <div className="row">
                        <button className="btn small secondary" disabled={tx.busy} onClick={() => setEditing(editing === s.id ? null : s.id)}>
                          Edit
                        </button>
                        {s.status === 1 && (
                          <button className="btn small secondary" disabled={tx.busy} onClick={() => act("pauseStream", s.id)}>
                            Pause
                          </button>
                        )}
                        {s.status === 2 && (
                          <button className="btn small secondary" disabled={tx.busy} onClick={() => act("resumeStream", s.id)}>
                            Resume
                          </button>
                        )}
                        <button
                          className="btn small danger"
                          disabled={tx.busy}
                          onClick={() => {
                            if (confirm("Cancel this stream? Everything earned so far stays withdrawable by the worker.")) act("cancelStream", s.id);
                          }}
                        >
                          Cancel
                        </button>
                      </div>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {editing !== null && (
        <div className="row" style={{ marginTop: 12 }}>
          <span className="small">Edit stream #{editing.toString()}:</span>
          <input style={{ width: 160 }} placeholder="New monthly" value={newMonthly} onChange={(e) => setNewMonthly(e.target.value)} />
          <input style={{ width: 220 }} type="datetime-local" value={newEnd} onChange={(e) => setNewEnd(e.target.value)} />
          <button
            className="btn small"
            disabled={tx.busy || parse(newMonthly, DEC) === 0n}
            onClick={async () => {
              await tx.send({
                address: payroll,
                abi: payrollAbi,
                functionName: "updateStream",
                args: [editing, monthlyToRateX(parse(newMonthly, DEC)), dateToTs(newEnd)],
              });
              setEditing(null);
            }}
          >
            Save
          </button>
          <span className="small muted">Changes apply from now; earned pay is never reduced.</span>
        </div>
      )}
      {tx.error && <div className="error">{tx.error}</div>}
    </div>
  );
}

function Treasury({ payroll, unallocated, warnDays }: { payroll: Address; unallocated?: bigint; warnDays?: number }) {
  const { address } = useAccount();
  const [amount, setAmount] = useState("");
  const [days, setDays] = useState("");
  const tx = useTx();
  return (
    <div className="card">
      <h3>Treasury & alerts</h3>
      <div className="sub">Only unallocated funds can be withdrawn — accrued pay belongs to workers.</div>
      <label>Withdraw unallocated ({fmt(unallocated, DEC)} available)</label>
      <div className="row">
        <input style={{ width: 160 }} value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="0" />
        <button
          className="btn secondary"
          disabled={tx.busy || parse(amount, DEC) === 0n}
          onClick={() => tx.send({ address: payroll, abi: payrollAbi, functionName: "withdrawUnallocated", args: [parse(amount, DEC), address!] })}
        >
          Withdraw
        </button>
      </div>
      <label>Low-runway warning threshold (days, currently {warnDays ?? "—"})</label>
      <div className="row">
        <input style={{ width: 160 }} value={days} onChange={(e) => setDays(e.target.value)} placeholder="14" />
        <button
          className="btn secondary"
          disabled={tx.busy || !days}
          onClick={() => tx.send({ address: payroll, abi: payrollAbi, functionName: "setWarnDays", args: [Number(days)] })}
        >
          Save
        </button>
      </div>
      {tx.error && <div className="error">{tx.error}</div>}
    </div>
  );
}

function GrantBonus() {
  const assets = useChainQuery(["supported"], (c) =>
    c.readContract({ address: deployment.sliceRouter, abi: sliceRouterAbi, functionName: "supportedAssets" }),
  );
  const [worker, setWorker] = useState("");
  const [token, setToken] = useState("");
  const [amount, setAmount] = useState("");
  const [cliffM, setCliffM] = useState("12");
  const [durM, setDurM] = useState("48");
  const [revocable, setRevocable] = useState(true);
  const tx = useTx();
  const list = useMemo(() => ((assets.data as Address[] | undefined) ?? []).map((a) => ({ a, ...assetMeta(a) })), [assets.data]);
  const tok = (token || list[0]?.a) as Address | undefined;
  const amt = parse(amount, 18);
  const month = 2_629_800n;
  return (
    <div className="card">
      <h3>Grant stock bonus</h3>
      <div className="sub">Escrow stock tokens that vest linearly after a cliff. Revoking returns only the unvested part.</div>
      <label>Worker</label>
      <input value={worker} onChange={(e) => setWorker(e.target.value.trim())} placeholder="0x…" />
      <div className="grid cols-2" style={{ gap: 8 }}>
        <div>
          <label>Stock token</label>
          <select value={tok} onChange={(e) => setToken(e.target.value)}>
            {list.map((x) => (
              <option key={x.a} value={x.a}>
                {x.symbol}
              </option>
            ))}
          </select>
        </div>
        <div>
          <label>Amount (tokens)</label>
          <input value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="10" />
        </div>
        <div>
          <label>Cliff (months)</label>
          <input value={cliffM} onChange={(e) => setCliffM(e.target.value)} />
        </div>
        <div>
          <label>Vesting duration (months)</label>
          <input value={durM} onChange={(e) => setDurM(e.target.value)} />
        </div>
      </div>
      <label className="row">
        <input type="checkbox" checked={revocable} onChange={(e) => setRevocable(e.target.checked)} /> Revocable (unvested part only)
      </label>
      <button
        className="btn"
        style={{ marginTop: 8 }}
        disabled={tx.busy || !isAddress(worker) || !tok || amt === 0n}
        onClick={async () => {
          await tx.ensureAllowance(tok!, deployment.bonusVesting, amt);
          await tx.send({
            address: deployment.bonusVesting,
            abi: bonusVestingAbi,
            functionName: "grant",
            args: [worker as Address, tok!, amt, 0n, BigInt(cliffM || "0") * month, BigInt(durM || "1") * month, revocable],
          });
          setAmount("");
        }}
      >
        {tx.busy ? "Confirming…" : "Approve & grant"}
      </button>
      {tx.error && <div className="error">{tx.error}</div>}
    </div>
  );
}
