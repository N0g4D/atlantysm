import { formatEther } from "viem";

import { Panel, Stat } from "./Panel";
import { useMana, useOwnedCrystals, usePrimaryCrystal } from "../hooks/useCrystals";
import { truncateTokenId } from "../lib/format";

/**
 * The three sections. They are intentionally read-only for now: phase 10 is the skeleton, and every
 * write path (mint, faucet, level up, match) arrives with its own phase. What they DO show is real
 * synced state rather than mock data, so the MUD wiring is visibly working end to end.
 */

export function ForgePanel() {
  const crystals = useOwnedCrystals();

  return (
    <Panel title="La Forgia" hint="conia un nuovo cristallo" accent="peach">
      <p className="muted mb-4">
        Ogni cristallo nasce a livello 1 e riceve un proprio account on-chain nella stessa
        transazione.
      </p>
      <Stat label="Cristalli posseduti" value={crystals.length} />
      <button type="button" className="btn btn-primary mt-5" disabled>
        Forgia — in arrivo
      </button>
    </Panel>
  );
}

export function SanctuaryPanel() {
  const crystal = usePrimaryCrystal();
  const mana = useMana(crystal?.entity);

  if (!crystal) {
    return (
      <Panel title="Santuario" hint="cura e progressione" accent="mint">
        <p className="muted">Nessun cristallo da custodire. Passa dalla Forgia.</p>
      </Panel>
    );
  }

  return (
    <Panel title="Santuario" hint="cura e progressione" accent="mint">
      <Stat label="Cristallo" value={truncateTokenId(crystal.tokenId)} />
      <Stat label="Livello" value={crystal.level} />
      <Stat label="Mana" value={mana === undefined ? "—" : formatEther(mana)} />
    </Panel>
  );
}

export function ArenaPanel() {
  return (
    <Panel title="L'Arena" hint="commit-reveal, elementi, scommesse" accent="lavender">
      <p className="muted">
        Le mosse restano nascoste finché entrambi i giocatori non rivelano. Nessuna lobby aperta.
      </p>
    </Panel>
  );
}
