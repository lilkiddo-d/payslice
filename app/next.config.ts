import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  reactStrictMode: true,
  transpilePackages: ["@payslice/config"],
  webpack: (config, { webpack }) => {
    // optional deps of WalletConnect / MetaMask SDK that are not needed in the browser bundle
    config.externals.push("pino-pretty", "lokijs", "encoding");
    config.resolve.fallback = { ...config.resolve.fallback, "@react-native-async-storage/async-storage": false };
    // Solana-only x402 payment code reachable through the Base/Coinbase account SDK; never used by Payslice
    config.plugins.push(new webpack.IgnorePlugin({ resourceRegExp: /^@x402\// }));
    config.plugins.push(new webpack.IgnorePlugin({ resourceRegExp: /^@solana\/(kit|web3\.js)$/ }));
    return config;
  },
  async headers() {
    return [
      {
        source: "/(.*)",
        headers: [
          { key: "X-Frame-Options", value: "DENY" },
          { key: "X-Content-Type-Options", value: "nosniff" },
          { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
        ],
      },
    ];
  },
};

export default nextConfig;
