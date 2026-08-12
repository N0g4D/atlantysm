import { useMemo } from "react";
import { useComponentValue, useEntityQuery } from "@latticexyz/react";
import { Has, getComponentValue, type Entity } from "@latticexyz/recs";

import { useMud } from "../mud/MudProvider";

export type OwnedCrystal = {
  /** The ECS entity — the crystal's ERC-6551 account address, widened to bytes32. */
  entity: Entity;
  tokenId: bigint;
  level: number;
};

/** The address the client currently acts as. */
export function useConnectedAddress(): string {
  const { network } = useMud();
  return network.walletClient.account.address;
}

/**
 * Entities of every crystal owned by the connected address.
 *
 * Implementation note: this scans `CrystalOwner` and filters, rather than doing a keyed lookup.
 * `CrystalOwner` is keyed by ENTITY (the crystal), not by owner, so there is no direct index from a
 * wallet to its crystals on-chain — inverting it would have meant maintaining another table. The
 * client-side scan is over the synced set only, which is small, and it is the same trade-off
 * `CrystalBalance` makes for `balanceOf`.
 *
 * The comparison is case-insensitive on purpose: viem hands back checksummed addresses while MUD
 * decodes table fields to lowercase hex, so a strict `===` would silently match nothing.
 */
export function useOwnedCrystalEntities(): Entity[] {
  const { components } = useMud();
  const address = useConnectedAddress();

  const entities = useEntityQuery([Has(components.CrystalOwner)]);

  return useMemo(() => {
    const mine = address.toLowerCase();
    return entities.filter(
      (entity) => getComponentValue(components.CrystalOwner, entity)?.owner?.toLowerCase() === mine,
    );
  }, [entities, address, components]);
}

/**
 * A crystal's own data, subscribed to `CrystalData`.
 *
 * This has to be a separate hook rather than a read inside `useOwnedCrystalEntities`'s memo. That
 * memo only recomputes when the CrystalOwner query changes, so a level-up — which touches
 * `CrystalData` and nothing else — produced a successful transaction and a stale number on screen.
 * `useComponentValue` subscribes to the right component, so the level now moves with the chain.
 */
export function useCrystal(entity: Entity | undefined): OwnedCrystal | undefined {
  const { components } = useMud();
  const data = useComponentValue(components.CrystalData, entity);

  if (!entity || !data) return undefined;
  return {
    entity,
    tokenId: data.tokenId as bigint,
    level: Number(data.level),
  };
}

/** The crystal the UI is currently about. First owned one for now — no selector yet. */
export function usePrimaryCrystal(): OwnedCrystal | undefined {
  const entities = useOwnedCrystalEntities();
  return useCrystal(entities[0]);
}

/** In-game mana held by a crystal, in base units. `undefined` while unknown, `0n` when empty. */
export function useMana(entity: Entity | undefined): bigint | undefined {
  const { components } = useMud();
  const record = useComponentValue(components.ManaBalance, entity);
  if (!entity) return undefined;
  return (record?.amount ?? 0n) as bigint;
}
