import type { Entity } from "@latticexyz/recs";

import { useConnectedAddress } from "../hooks/useCrystals";
import { truncateAddress, truncateTokenId } from "../lib/format";
import { useCrystalSelection, useSelectedCrystal } from "../mud/CrystalSelection";
import { TABS, type TabId } from "../tabs";

type Props = {
  active: TabId;
  onSelect: (tab: TabId) => void;
};

export function Navbar({ active, onSelect }: Props) {
  const address = useConnectedAddress();
  const crystal = useSelectedCrystal();
  const { owned, selected, select } = useCrystalSelection();

  return (
    <header className="border-b-2 border-ink bg-white">
      <div className="mx-auto flex max-w-5xl flex-wrap items-center gap-4 px-6 py-4">
        <span className="heading mr-2">Atlantysm</span>

        <nav className="flex gap-2" aria-label="Sezioni">
          {TABS.map((tab) => (
            <button
              key={tab.id}
              type="button"
              onClick={() => onSelect(tab.id)}
              aria-current={active === tab.id ? "page" : undefined}
              className={`tab ${active === tab.id ? "tab-active" : ""}`}
            >
              {tab.label}
            </button>
          ))}
        </nav>

        <div className="ml-auto flex items-center gap-2">
          {/* The Arena needs two crystals to be playable at all, which is what finally made a
              selector necessary rather than nice to have. */}
          {owned.length > 1 ? (
            <label className="flex items-center gap-2">
              <span className="muted text-xs uppercase tracking-wide">Attivo</span>
              <select
                aria-label="Cristallo attivo"
                className="select"
                value={selected ?? ""}
                onChange={(event) => select(event.target.value as Entity)}
              >
                {owned.map((entity, index) => (
                  <option key={entity} value={entity}>
                    #{index + 1} · {truncateAddress(entity, 6, 4)}
                  </option>
                ))}
              </select>
            </label>
          ) : null}

          {crystal ? (
            <span className="chip bg-solarpunk-mint" title={`Cristallo #${crystal.tokenId.toString()}`}>
              Cristallo {truncateTokenId(crystal.tokenId)} · Lv {crystal.level}
            </span>
          ) : (
            <span className="chip bg-solarpunk-peach">Nessun cristallo</span>
          )}

          <span className="chip bg-white" title={address}>
            {truncateAddress(address)}
          </span>
        </div>
      </div>
    </header>
  );
}
