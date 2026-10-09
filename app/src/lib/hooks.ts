"use client";

import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useCallback, useEffect, useState } from "react";
import { usePublicClient, useWriteContract, useAccount } from "wagmi";
import type { Abi, Address, PublicClient } from "viem";
import { erc20Abi } from "viem";

/** React-query wrapper around an async reader that gets the public client. */
export function useChainQuery<T>(key: unknown[], fn: (c: PublicClient) => Promise<T>, enabled = true) {
  const client = usePublicClient();
  return useQuery({
    queryKey: ["chain", ...key],
    queryFn: () => fn(client as PublicClient),
    enabled: enabled && !!client,
  });
}

export function useNow(intervalMs = 1000) {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), intervalMs);
    return () => clearInterval(id);
  }, [intervalMs]);
  return now;
}

export interface TxState {
  busy: boolean;
  error?: string;
  hash?: `0x${string}`;
}

/** Sends a contract write, waits for the receipt, then refreshes every chain query. */
export function useTx() {
  const client = usePublicClient();
  const qc = useQueryClient();
  const { writeContractAsync } = useWriteContract();
  const { address } = useAccount();
  const [state, setState] = useState<TxState>({ busy: false });

  const send = useCallback(
    async (args: { address: Address; abi: Abi | readonly unknown[]; functionName: string; args?: readonly unknown[] }) => {
      setState({ busy: true });
      try {
        const hash = await writeContractAsync(args as never);
        await client!.waitForTransactionReceipt({ hash });
        setState({ busy: false, hash });
        await qc.invalidateQueries({ queryKey: ["chain"] });
        return hash;
      } catch (e) {
        const msg = (e as { shortMessage?: string; message?: string }).shortMessage || (e as Error).message;
        setState({ busy: false, error: msg });
        throw e;
      }
    },
    [client, qc, writeContractAsync],
  );

  /** approve `spender` for `amount` of `token` if the current allowance is lower */
  const ensureAllowance = useCallback(
    async (token: Address, spender: Address, amount: bigint) => {
      if (!address) return;
      const allowance = (await client!.readContract({
        address: token,
        abi: erc20Abi,
        functionName: "allowance",
        args: [address, spender],
      })) as bigint;
      if (allowance < amount) {
        await send({ address: token, abi: erc20Abi, functionName: "approve", args: [spender, amount] });
      }
    },
    [address, client, send],
  );

  return { ...state, send, ensureAllowance };
}
