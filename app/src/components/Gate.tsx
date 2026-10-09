"use client";

import type { ReactNode } from "react";
import { useAccount } from "wagmi";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { activeChain, isDeployed } from "@/lib/config";

/** Renders children only when contracts are deployed on the active chain and a wallet is connected. */
export function Gate({ children, title }: { children: ReactNode; title: string }) {
  const { isConnected, chainId } = useAccount();
  if (!isDeployed)
    return (
      <div className="alert info">
        Payslice is not deployed on {activeChain.name} yet. Run the deploy script (see DEPLOY.md) — it writes the
        addresses into <code>app/src/config/generated/{activeChain.id}.json</code>.
      </div>
    );
  if (!isConnected)
    return (
      <div className="card">
        <h2>{title}</h2>
        <p className="muted">Connect a wallet to continue.</p>
        <ConnectButton />
      </div>
    );
  if (chainId !== activeChain.id)
    return <div className="alert warn">Switch your wallet to {activeChain.name} (chain id {activeChain.id}).</div>;
  return <>{children}</>;
}
