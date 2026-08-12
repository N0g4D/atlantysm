import { formatEther } from "viem";

import { Panel, Stat } from "./Panel";
import { useAction } from "../hooks/useAction";
import { useMana, useOwnedCrystalEntities } from "../hooks/useCrystals";
import { levelUpCost, useEthBalance, useMintPrice, useStarterManaClaimed } from "../hooks/useGame";
import { useMud } from "../mud/MudProvider";
import { useSelectedCrystal } from "../mud/CrystalSelection";
import { truncateTokenId } from "../lib/format";

/** Mana and ETH are both 18-decimal; trimming the tail keeps the columns readable. */
function amount(value: bigint, suffix: string): string {
  const formatted = formatEther(value);
  const trimmed = formatted.includes(".") ? formatted.replace(/\.?0+$/, "") : formatted;
  return `${trimmed} ${suffix}`;
}

export function ForgePanel() {
  const { systemCalls } = useMud();
  const crystals = useOwnedCrystalEntities();
  const mintPrice = useMintPrice();
  const ethBalance = useEthBalance();
  const { pending, run } = useAction();

  const forging = pending === "mint";
  const priceKnown = mintPrice?.configured === true;
  const price = mintPrice?.price ?? 0n;
  const shortOnEth = ethBalance !== undefined && priceKnown && ethBalance < price;

  return (
    <Panel title="La Forgia" hint="conia un nuovo cristallo" accent="peach">
      <p className="muted mb-4">
        Ogni cristallo nasce a livello 1 e riceve un proprio account on-chain nella stessa
        transazione.
      </p>

      <Stat label="Prezzo" value={priceKnown ? amount(price, "ETH") : "non configurato"} />
      <Stat label="Saldo del wallet" value={ethBalance === undefined ? "…" : amount(ethBalance, "ETH")} />
      <Stat label="Cristalli posseduti" value={crystals.length} />

      <button
        type="button"
        className="btn btn-primary mt-5"
        disabled={forging || !priceKnown || shortOnEth}
        onClick={() => run("mint", "Cristallo forgiato.", systemCalls.mintCrystal)}
      >
        {forging ? "Forgiatura in corso…" : "Forgia"}
      </button>

      {shortOnEth ? (
        <p className="muted mt-3">
          ETH insufficiente. Il burner wallet parte da zero — usa &ldquo;top up&rdquo; nei MUD Dev
          Tools in basso a destra.
        </p>
      ) : null}
    </Panel>
  );
}

export function SanctuaryPanel() {
  const { systemCalls } = useMud();
  const crystal = useSelectedCrystal();
  const mana = useMana(crystal?.entity);
  const claimed = useStarterManaClaimed(crystal?.entity);
  const { pending, run } = useAction();

  if (!crystal) {
    return (
      <Panel title="Santuario" hint="cura e progressione" accent="mint">
        <p className="muted">Nessun cristallo da custodire. Passa dalla Forgia.</p>
      </Panel>
    );
  }

  const claiming = pending === "claim";
  const levelling = pending === "levelUp";
  const cost = levelUpCost(crystal.level);
  const canAfford = mana !== undefined && mana >= cost;

  return (
    <Panel title="Santuario" hint="cura e progressione" accent="mint">
      <Stat label="Cristallo" value={truncateTokenId(crystal.tokenId)} />
      <Stat label="Livello" value={crystal.level} />
      <Stat label="Mana" value={mana === undefined ? "…" : amount(mana, "MANA")} />
      <Stat label="Costo prossimo livello" value={amount(cost, "MANA")} />

      <div className="mt-5 flex flex-wrap gap-3">
        {/* The grant is once per crystal for life, so the button retires rather than greying out. */}
        {claimed ? null : (
          <button
            type="button"
            className="btn btn-primary"
            disabled={claiming || levelling}
            onClick={() =>
              run("claim", "Mana iniziale riscosso.", () => systemCalls.claimStarterMana(crystal.entity))
            }
          >
            {claiming ? "Estrazione in corso…" : "Estrai Mana Iniziale"}
          </button>
        )}

        <button
          type="button"
          className="btn"
          disabled={levelling || claiming || !canAfford}
          onClick={() => run("levelUp", `Livello ${crystal.level + 1} raggiunto.`, () => systemCalls.levelUp(crystal.entity))}
        >
          {levelling ? "Ascensione in corso…" : "Sali di Livello"}
        </button>
      </div>

      {claimed && !canAfford ? (
        <p className="muted mt-3">
          Mana insufficiente per il prossimo livello. Vincere nell&apos;Arena è l&apos;unica altra
          fonte.
        </p>
      ) : null}
    </Panel>
  );
}
