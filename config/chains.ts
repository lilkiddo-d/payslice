/**
 * Robinhood Chain network + token configuration for Payslice.
 *
 * Every address here was taken from an official source (links inline) and checked on-chain on 2026-10-08
 * (bytecode present; symbol/decimals match; Chainlink feeds answering). Keep in sync with
 * contracts/script/RobinhoodChain.sol.
 *
 * Gaps (documented in DECISIONS.md / THREAT_MODEL.md):
 *  - No Chainlink L2 sequencer-uptime feed exists for Robinhood Chain
 *    (https://docs.chain.link/data-feeds/l2-sequencer-feeds). OracleAdapter supports one; it is unset.
 *  - Stock tokens are acquired via Uniswap v3 (USDG pools). Other venues (RFQ, Rialto, Lighter) can be
 *    plugged in later as another IDexAdapter.
 */

export type Address = `0x${string}`;

export interface StockToken {
  symbol: string;
  name: string;
  token: Address;
  /** Chainlink <SYMBOL>/USD feed, 8 decimals, multiplier-adjusted (price of one token), 24/5 */
  feed: Address;
}

export const ROBINHOOD_CHAIN = {
  id: 4663,
  name: "Robinhood Chain",
  /** https://docs.robinhood.com/chain/connecting */
  rpcUrls: {
    http: "https://rpc.mainnet.chain.robinhood.com", // public, rate-limited; use a dedicated provider in prod
    ws: "wss://feed.mainnet.chain.robinhood.com",
  },
  explorer: {
    name: "Blockscout",
    url: "https://robinhoodchain.blockscout.com",
    /** Contract verification: https://docs.robinhood.com/chain/deploy-smart-contracts */
    verifierUrl: "https://robinhoodchain.blockscout.com/api/",
    verifier: "blockscout",
  },
  /** Gas token: ETH (https://docs.robinhood.com/chain/connecting) */
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  testnet: {
    id: 46630,
    rpc: "https://rpc.testnet.chain.robinhood.com",
    explorer: "https://explorer.testnet.chain.robinhood.com",
  },
} as const;

/** https://docs.robinhood.com/chain/contracts */
export const STABLECOIN = {
  symbol: "USDG",
  name: "Global Dollar",
  decimals: 6,
  token: "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168" as Address,
  /** https://docs.chain.link/data-feeds/price-feeds/addresses?network=robinhood */
  feed: "0x61B7e5650328764B076A108EFF5fa7282a1B9aD2" as Address,
} as const;

/** https://docs.robinhood.com/chain/contracts */
export const WETH: Address = "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73";

/** https://developers.uniswap.org/docs/protocols/v3/deployments/v3-robinhood-chain-deployments */
export const UNISWAP_V3 = {
  factory: "0x1f7d7550B1b028f7571E69A784071F0205FD2EfA" as Address,
  swapRouter02: "0xCaf681a66D020601342297493863E78C959E5cb2" as Address,
  quoterV2: "0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7" as Address,
} as const;

/** Protocol contracts from https://docs.robinhood.com/chain/protocol-contracts */
export const PROTOCOL = {
  multicall: "0x2cAC2D899eCC914d704FeaAE33ac1bF36277DaD1" as Address,
  permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3" as Address,
} as const;

/**
 * Stock tokens: https://api.robinhood.com/rhj/assets (official Stock Token API,
 * https://docs.robinhood.com/chain/stock-token-apis). 18 decimals, ERC-20 + ERC-8056 uiMultiplier.
 * Feeds: https://reference-data-directory.vercel.app/feeds-robinhood-mainnet.json (Chainlink directory).
 */
export const STOCKS: StockToken[] = [
  { symbol: "AAPL", name: "Apple", token: "0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9", feed: "0x6B22A786bAa607d76728168703a39Ea9C99f2cD0" },
  { symbol: "MSFT", name: "Microsoft", token: "0xe93237C50D904957Cf27E7B1133b510C669c2e74", feed: "0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E" },
  { symbol: "NVDA", name: "NVIDIA", token: "0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC", feed: "0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15" },
  { symbol: "TSLA", name: "Tesla", token: "0x322F0929c4625eD5bAd873c95208D54E1c003b2d", feed: "0x4A1166a659A55625345e9515b32adECea5547C38" },
  { symbol: "AMZN", name: "Amazon", token: "0x12f190a9F9d7D37a250758b26824B97CE941bF54", feed: "0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C" },
  { symbol: "GOOGL", name: "Alphabet", token: "0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3", feed: "0xF6f373a037c30F0e5010d854385cA89185AE638b" },
  { symbol: "META", name: "Meta Platforms", token: "0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35", feed: "0x7C38C00C30BEe9378381E7B6135d7283356D71b1" },
  { symbol: "COIN", name: "Coinbase", token: "0x6330D8C3178a418788dF01a47479c0ce7CCF450b", feed: "0xA3a468A452940B7D6b69991207B508c609a98Ef2" },
  { symbol: "SPY", name: "S&P 500 ETF", token: "0x117cc2133c37B721F49dE2A7a74833232B3B4C0C", feed: "0x319724394D3A0e3669269846abE664Cd621f9f6A" },
  { symbol: "QQQ", name: "Nasdaq-100 ETF", token: "0xD5f3879160bc7c32ebb4dC785F8a4F505888de68", feed: "0x80901d846d5D7B030F26B480776EE3b29374C2ae" },
];

/** Local rehearsal: `anvil --fork-url <mainnet rpc> --chain-id 31337 --port 8547` */
export const LOCAL_FORK = {
  id: 31337,
  name: "Robinhood Chain (local fork)",
  rpcUrl: "http://127.0.0.1:8547",
} as const;

export const stockByToken = (addr: string): StockToken | undefined =>
  STOCKS.find((s) => s.token.toLowerCase() === addr.toLowerCase());
