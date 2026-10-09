# Payslice contracts

Foundry project. See the [root README](../README.md) for the overview and [DEPLOY.md](../DEPLOY.md) for deployment.

```bash
forge build
```

```bash
forge test --no-match-path "test/fork/*"
```

Fork tests run against the live Robinhood Chain mainnet RPC:

```bash
ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-path "test/fork/*"
```
