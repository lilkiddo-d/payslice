"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { useAccount, useConnect, useDisconnect } from "wagmi";
import { IS_FORK, TOKEN_FEATURES } from "@/lib/config";
import { MarketBadge } from "./MarketBadge";

export function Nav() {
  const path = usePathname();
  const links = [
    { href: "/employer", label: "Employer" },
    { href: "/worker", label: "Worker" },
    ...(TOKEN_FEATURES ? [{ href: "/stake", label: "Stake" }] : []),
    { href: "/risk", label: "Risks" },
  ];
  return (
    <nav className="nav">
      <Link href="/" className="brand">
        <Logo /> Payslice
      </Link>
      <div className="links">
        {links.map((l) => (
          <Link key={l.href} href={l.href} className={path?.startsWith(l.href) ? "active" : ""}>
            {l.label}
          </Link>
        ))}
      </div>
      <MarketBadge />
      {IS_FORK && <DevAccount />}
      <ConnectButton showBalance={false} chainStatus="icon" />
    </nav>
  );
}

/** Local-fork helper: connect anvil's unlocked dev account (signing happens in anvil, no keys in browser). */
function DevAccount() {
  const { connectors, connect } = useConnect();
  const { connector, isConnected } = useAccount();
  const { disconnect } = useDisconnect();
  const mockConnector = connectors.find((c) => c.id === "mock");
  if (!mockConnector) return null;
  if (isConnected && connector?.id === "mock")
    return (
      <button className="btn small secondary" onClick={() => disconnect()}>
        Fork account ✕
      </button>
    );
  return (
    <button className="btn small secondary" onClick={() => connect({ connector: mockConnector })}>
      Use fork test account
    </button>
  );
}

function Logo() {
  return (
    <svg width="22" height="22" viewBox="0 0 32 32" aria-hidden>
      <circle cx="16" cy="16" r="14" fill="#19c39c" />
      <path d="M16 2 A14 14 0 0 1 30 16 L16 16 Z" fill="#7c5cff" />
    </svg>
  );
}
