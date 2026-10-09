"use client";

import { useState } from "react";
import { useAccount } from "wagmi";
import { erc20Abi, type Address } from "viem";
import { projectTokenHooksAbi } from "@/abi";
import { Gate } from "@/components/Gate";
import { deployment, PROJECT_TOKEN, STABLE, TOKEN_FEATURES } from "@/lib/config";
import { useChainQuery, useTx } from "@/lib/hooks";
import { fmt, parse, tsToDate } from "@/lib/format";

export default function StakePage() {
  if (!TOKEN_FEATURES)
    return (
      <main>
        <h1>Staking</h1>
        <p className="muted">Token features are not enabled.</p>
      </main>
    );
  return (
    <main>
      <h1>Stake $SLCE</h1>
      <Gate title="Stake">
        <Stake />
      </Gate>
    </main>
  );
}

function Stake() {
  const { address } = useAccount();
  const token = PROJECT_TOKEN as Address;
  const hooks = deployment.projectTokenHooks;
  const [amount, setAmount] = useState("");
  const tx = useTx();
  const q = useChainQuery(["stake", address], async (c) => {
    const h = (fn: string, args: readonly unknown[] = []) =>
      c.readContract({ address: hooks, abi: projectTokenHooksAbi, functionName: fn as never, args: args as never });
    const [active, onchainToken, staked, unlock, discount, pending, total] = (await Promise.all([
      h("isActive"),
      h("projectToken"),
      h("stakedOf", [address]),
      h("unlockAt", [address]),
      h("feeDiscountBps", [address]),
      h("pendingReward", [address, deployment.stablecoin]),
      h("totalStaked"),
    ])) as [boolean, Address, bigint, bigint, bigint, bigint, bigint];
    const bal = (await c.readContract({ address: token, abi: erc20Abi, functionName: "balanceOf", args: [address!] })) as bigint;
    return { active, onchainToken, staked, unlock, discount, pending, total, bal };
  });
  const d = q.data;
  if (d && d.onchainToken.toLowerCase() !== token.toLowerCase())
    return (
      <div className="alert warn">
        NEXT_PUBLIC_PROJECT_TOKEN is set, but the Timelock has not yet executed <code>setProjectToken</code> for this
        address on-chain. Staking opens once it does.
      </div>
    );
  const amt = parse(amount, 18);
  return (
    <div className="grid cols-2">
      <div className="card">
        <h3>Your stake</h3>
        <p>
          Staked: <b>{fmt(d?.staked, 18)}</b> · wallet {fmt(d?.bal, 18)} · unlocks {d ? tsToDate(d.unlock) : "—"}
        </p>
        <p>
          Payroll fee discount: <b>{Number(d?.discount ?? 0n) / 100}%</b> · pending fee share:{" "}
          <b>
            {fmt(d?.pending, STABLE.decimals)} {STABLE.symbol}
          </b>
        </p>
        <label>Amount</label>
        <input value={amount} onChange={(e) => setAmount(e.target.value)} />
        <div className="row" style={{ marginTop: 10 }}>
          <button
            className="btn"
            disabled={tx.busy || amt === 0n}
            onClick={async () => {
              await tx.ensureAllowance(token, hooks, amt);
              await tx.send({ address: hooks, abi: projectTokenHooksAbi, functionName: "stake", args: [amt] });
            }}
          >
            Stake
          </button>
          <button className="btn secondary" disabled={tx.busy || amt === 0n} onClick={() => tx.send({ address: hooks, abi: projectTokenHooksAbi, functionName: "unstake", args: [amt] })}>
            Unstake
          </button>
          <button className="btn secondary" disabled={tx.busy} onClick={() => tx.send({ address: hooks, abi: projectTokenHooksAbi, functionName: "claimRewards" })}>
            Claim fee share
          </button>
        </div>
        {tx.error && <div className="error">{tx.error}</div>}
      </div>
      <div className="card">
        <h3>How it works</h3>
        <ul className="small muted">
          <li>Employers who stake get a discount on the payroll deposit fee (tiered).</li>
          <li>Stakers share a portion of stock-conversion fees, paid in {STABLE.symbol}.</li>
          <li>Each stake locks your whole position for 7 days (anti flash-staking).</li>
          <li>Total staked: {fmt(d?.total, 18)}</li>
        </ul>
      </div>
    </div>
  );
}
