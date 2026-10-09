import { formatUnits, parseUnits } from "viem";

export const SCALE = 10n ** 18n;
export const SECONDS_PER_MONTH = 2_629_800n; // 365.25 days / 12

export function fmt(amount: bigint | undefined, decimals: number, dp = 2): string {
  if (amount === undefined) return "—";
  const s = formatUnits(amount, decimals);
  const [i, f = ""] = s.split(".");
  const int = BigInt(i).toLocaleString("en-US");
  return dp > 0 ? `${int}.${(f + "0".repeat(dp)).slice(0, dp)}` : int;
}

export function parse(value: string, decimals: number): bigint {
  try {
    return parseUnits((value || "0").replace(/,/g, ""), decimals);
  } catch {
    return 0n;
  }
}

/** monthly salary in token base units -> rateX (base units / second, scaled 1e18) */
export const monthlyToRateX = (monthly: bigint) => (monthly * SCALE) / SECONDS_PER_MONTH;
export const rateXToMonthly = (rateX: bigint) => (rateX * SECONDS_PER_MONTH) / SCALE;

export function fmtDuration(seconds: bigint | undefined): string {
  if (seconds === undefined) return "—";
  if (seconds > 10n ** 12n) return "∞";
  const d = Number(seconds) / 86400;
  if (d >= 365) return `${(d / 365).toFixed(1)} years`;
  if (d >= 1) return `${d.toFixed(1)} days`;
  return `${(Number(seconds) / 3600).toFixed(1)} hours`;
}

export const short = (a?: string) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "");

export function dateToTs(v: string): bigint {
  if (!v) return 0n;
  const t = Date.parse(v);
  return Number.isNaN(t) ? 0n : BigInt(Math.floor(t / 1000));
}

export const tsToDate = (t: bigint | number) =>
  Number(t) === 0 ? "—" : new Date(Number(t) * 1000).toISOString().slice(0, 10);
