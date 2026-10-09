"use client";

import { marketClockAbi } from "@/abi";
import { deployment, isDeployed } from "@/lib/config";
import { useChainQuery } from "@/lib/hooks";

export function MarketBadge() {
  const { data } = useChainQuery(
    ["market"],
    (c) => c.readContract({ address: deployment.marketClock, abi: marketClockAbi, functionName: "isMarketOpen" }),
    isDeployed,
  );
  if (!isDeployed || data === undefined) return null;
  return (
    <span className={`badge ${data ? "ok" : ""}`} title="Stock conversions only run during the regular US session">
      US market {data ? "open" : "closed"}
    </span>
  );
}
