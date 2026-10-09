"use client";

import "@rainbow-me/rainbowkit/styles.css";
import { RainbowKitProvider, connectorsForWallets, darkTheme } from "@rainbow-me/rainbowkit";
import {
  injectedWallet,
  metaMaskWallet,
  rabbyWallet,
  walletConnectWallet,
} from "@rainbow-me/rainbowkit/wallets";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { useState, type ReactNode } from "react";
import { WagmiProvider, createConfig, http, mock } from "wagmi";
import { ANVIL_ACCOUNTS, IS_FORK, activeChain } from "@/lib/config";

const projectId = process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID || "payslice-local-dev";

const walletConnectors = connectorsForWallets(
  [
    {
      groupName: "Wallets",
      wallets: process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID
        ? [injectedWallet, rabbyWallet, metaMaskWallet, walletConnectWallet]
        : [injectedWallet, rabbyWallet],
    },
  ],
  { appName: "Payslice", projectId },
);

// Local fork only: anvil's unlocked dev accounts, signing happens inside anvil (no keys in the browser).
const devConnectors = IS_FORK ? [mock({ accounts: ANVIL_ACCOUNTS as [`0x${string}`, ...`0x${string}`[]], features: { reconnect: true } })] : [];

export const wagmiConfig = createConfig({
  chains: [activeChain],
  connectors: [...walletConnectors, ...devConnectors],
  // only the active chain is configured; the cast narrows the union-typed chain id key
  transports: { [activeChain.id]: http(activeChain.rpcUrls.default.http[0], { batch: true }) } as never,
  ssr: true,
});

export function Providers({ children }: { children: ReactNode }) {
  const [queryClient] = useState(
    () => new QueryClient({ defaultOptions: { queries: { refetchInterval: 15_000, staleTime: 5_000 } } }),
  );
  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <RainbowKitProvider theme={darkTheme({ accentColor: "#7c5cff", borderRadius: "medium" })}>
          {children}
        </RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  );
}
