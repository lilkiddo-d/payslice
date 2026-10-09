// LOCAL FORK ONLY: give an address ETH + USDG on the anvil fork by impersonating the largest USDG holder.
// usage: node scripts/fork-fund.mjs <recipient> [usdgAmount=100000] [rpc=http://127.0.0.1:8547]
const [, , to, amountArg = "100000", rpc = "http://127.0.0.1:8547"] = process.argv;
const USDG = "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168";
if (!/^0x[0-9a-fA-F]{40}$/.test(to || "")) throw new Error("usage: node scripts/fork-fund.mjs <recipient> [amount]");

let id = 0;
async function call(method, params) {
  const r = await fetch(rpc, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: ++id, method, params }),
  });
  const j = await r.json();
  if (j.error) throw new Error(`${method}: ${j.error.message}`);
  return j.result;
}

const chainId = parseInt(await call("eth_chainId", []), 16);
if (chainId !== 31337) throw new Error(`refusing to run on chain ${chainId}; this is for the local fork (31337) only`);

const holders = await (await fetch(`https://robinhoodchain.blockscout.com/api/v2/tokens/${USDG}/holders`)).json();
const pad = (h) => h.replace(/^0x/, "").padStart(64, "0");
const amount = BigInt(Math.round(Number(amountArg) * 1e6));
let whale;
for (const h of holders.items ?? []) {
  const addr = h.address.hash;
  const code = await call("eth_getCode", [addr, "latest"]);
  const bal = BigInt(await call("eth_call", [{ to: USDG, data: "0x70a08231" + pad(addr) }, "latest"]));
  if (bal >= amount && code === "0x") {
    whale = addr;
    break;
  }
}
if (!whale) throw new Error("no EOA holder with enough USDG found");

await call("anvil_setBalance", [to, "0x56BC75E2D63100000"]); // 100 ETH
await call("anvil_setBalance", [whale, "0x56BC75E2D63100000"]);
await call("anvil_impersonateAccount", [whale]);
const data = "0xa9059cbb" + pad(to) + pad(amount.toString(16));
const hash = await call("eth_sendTransaction", [{ from: whale, to: USDG, data }]);
await call("anvil_stopImpersonatingAccount", [whale]);
console.log(`funded ${to} with ${amountArg} USDG from ${whale} (tx ${hash}) and 100 ETH`);
