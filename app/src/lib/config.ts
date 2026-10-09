import { defineChain, type Address } from "viem";
import { LOCAL_FORK, ROBINHOOD_CHAIN, STABLECOIN, STOCKS, stockByToken } from "@payslice/config";
import mainnetDeployment from "@/config/generated/4663.json";
import forkDeployment from "@/config/generated/31337.json";

export interface DeployedAsset {
  symbol: string;
  token: Address;
  feed: Address;
  pool: Address;
  fee: number;
}

export interface Deployment {
  chainId: number;
  notDeployed?: boolean;
  startBlock?: number;
  timelock: Address;
  payrollFactory: Address;
  payrollImplementation: Address;
  sliceRouter: Address;
  batchConverter: Address;
  dexAdapter: Address;
  bonusVesting: Address;
  marketClock: Address;
  oracleAdapter: Address;
  feeCollector: Address;
  projectTokenHooks: Address;
  complianceRegistry: Address;
  stablecoin: Address;
  assets: DeployedAsset[];
}

export const robinhood = defineChain({
  id: ROBINHOOD_CHAIN.id,
  name: ROBINHOOD_CHAIN.name,
  nativeCurrency: ROBINHOOD_CHAIN.nativeCurrency,
  rpcUrls: { default: { http: [process.env.NEXT_PUBLIC_RPC_URL || ROBINHOOD_CHAIN.rpcUrls.http] } },
  blockExplorers: { default: { name: "Blockscout", url: ROBINHOOD_CHAIN.explorer.url } },
});

export const robinhoodFork = defineChain({
  id: LOCAL_FORK.id,
  name: LOCAL_FORK.name,
  nativeCurrency: ROBINHOOD_CHAIN.nativeCurrency,
  rpcUrls: { default: { http: [process.env.NEXT_PUBLIC_FORK_RPC_URL || LOCAL_FORK.rpcUrl] } },
  blockExplorers: { default: { name: "Blockscout (mainnet)", url: ROBINHOOD_CHAIN.explorer.url } },
  testnet: true,
});

export const IS_FORK = process.env.NEXT_PUBLIC_CHAIN === "fork";
export const activeChain = IS_FORK ? robinhoodFork : robinhood;

export const deployment = (IS_FORK ? forkDeployment : mainnetDeployment) as unknown as Deployment;
export const isDeployed = !deployment.notDeployed && !!deployment.payrollFactory;

/** $SLCE: empty env = every token feature hidden */
export const PROJECT_TOKEN = (process.env.NEXT_PUBLIC_PROJECT_TOKEN || "").trim() as Address | "";
export const TOKEN_FEATURES = /^0x[0-9a-fA-F]{40}$/.test(PROJECT_TOKEN);

export const STABLE = STABLECOIN;
export const LOG_CHUNK = BigInt(process.env.NEXT_PUBLIC_LOG_CHUNK || "500000");

export function assetMeta(token: string) {
  const s = stockByToken(token);
  return { symbol: s?.symbol ?? token.slice(0, 6), name: s?.name ?? "Unknown token" };
}

export const ALL_STOCKS = STOCKS;
export const explorerAddress = (a: string) => `${ROBINHOOD_CHAIN.explorer.url}/address/${a}`;
export const explorerTx = (h: string) => `${ROBINHOOD_CHAIN.explorer.url}/tx/${h}`;

/** Anvil's well-known unlocked dev accounts — used ONLY with the local fork via the mock connector. */
export const ANVIL_ACCOUNTS: Address[] = [
  "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
  "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
  "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC",
];
