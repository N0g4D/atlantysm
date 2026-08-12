import { createContext, useContext, useMemo, useState, type ReactNode } from "react";
import type { Entity } from "@latticexyz/recs";

import { useCrystal, useOwnedCrystalEntities, type OwnedCrystal } from "../hooks/useCrystals";

type Selection = {
  owned: Entity[];
  selected: Entity | undefined;
  select: (entity: Entity) => void;
};

const SelectionContext = createContext<Selection | null>(null);

/**
 * Which crystal the UI is currently acting as.
 *
 * The Arena is what forced this: a match needs two crystals, and until now the client could only
 * ever drive the first one it happened to find. It also closes phase 10's open point — with three
 * crystals minted, "the first owned one" stopped being a reasonable answer.
 *
 * The selection falls back to the first owned crystal whenever the stored one is gone (sold, or a
 * different wallet), so it can never point at something the player no longer controls.
 */
export function CrystalSelectionProvider({ children }: { children: ReactNode }) {
  const owned = useOwnedCrystalEntities();
  const [chosen, setChosen] = useState<Entity>();

  const value = useMemo<Selection>(() => {
    const selected = chosen && owned.includes(chosen) ? chosen : owned[0];
    return { owned, selected, select: setChosen };
  }, [owned, chosen]);

  return <SelectionContext.Provider value={value}>{children}</SelectionContext.Provider>;
}

export function useCrystalSelection(): Selection {
  const value = useContext(SelectionContext);
  if (!value) throw new Error("useCrystalSelection must be used inside <CrystalSelectionProvider>");
  return value;
}

/** The crystal every panel acts as. Reactive on `CrystalData`, so its level moves with the chain. */
export function useSelectedCrystal(): OwnedCrystal | undefined {
  const { selected } = useCrystalSelection();
  return useCrystal(selected);
}
