import { useEffect, useState } from "react";
import { useComponentValue } from "@latticexyz/react";
import { singletonEntity } from "@latticexyz/store-sync/recs";
import type { Entity } from "@latticexyz/recs";

import { useMud } from "../mud/MudProvider";
import { useConnectedAddress } from "./useCrystals";

/**
 * Base of the level ladder, in mana base units.
 *
 * DUPLICATED FROM `ProgressionSystem.LEVEL_UP_BASE_COST`. The contract stays the source of truth —
 * a mismatch shows up as a transaction that reverts after the UI promised a price — so this is a
 * display convenience, not an authority. The World also exposes `app__levelUpCost(entity)`; it was
 * not used here because reading it is an async call per render, while the formula is two lines and
 * updates instantly with the level.
 */
export const LEVEL_UP_BASE_COST = 50_000_000_000_000_000_000n; // 50e18

/** `BASE * level^2` — quadratic since phase 6, against combat damage that stays linear. */
export function levelUpCost(level: number): bigint {
  return LEVEL_UP_BASE_COST * BigInt(level) * BigInt(level);
}

export type MintPrice = { configured: boolean; price: bigint };

/** The forge price, straight from the singleton table. `configured: false` means minting is shut. */
export function useMintPrice(): MintPrice | undefined {
  const { components } = useMud();
  const record = useComponentValue(components.MintPrice, singletonEntity);
  if (!record) return undefined;
  return { configured: Boolean(record.configured), price: record.price as bigint };
}

/** Whether this crystal has already drawn its one and only starter grant. */
export function useStarterManaClaimed(entity: Entity | undefined): boolean {
  const { components } = useMud();
  const record = useComponentValue(components.StarterManaClaimed, entity);
  return Boolean(record?.claimed);
}

/**
 * Native ETH held by the burner wallet.
 *
 * Polled rather than synced: ETH is not MUD state, so nothing pushes it into RECS. It matters
 * because a fresh burner starts at zero and minting costs real ETH — without this the first thing a
 * new player meets is a failed transaction rather than an explanation.
 */
export function useEthBalance(pollMs = 4000): bigint | undefined {
  const { network } = useMud();
  const address = useConnectedAddress();
  const [balance, setBalance] = useState<bigint>();

  useEffect(() => {
    let cancelled = false;

    async function read() {
      try {
        const value = await network.publicClient.getBalance({ address: address as `0x${string}` });
        if (!cancelled) setBalance(value);
      } catch {
        // A transient RPC failure should not blank the figure that is already on screen.
      }
    }

    void read();
    const timer = setInterval(read, pollMs);
    return () => {
      cancelled = true;
      clearInterval(timer);
    };
  }, [network.publicClient, address, pollMs]);

  return balance;
}
