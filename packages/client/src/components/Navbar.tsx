import { useConnectedAddress, usePrimaryCrystal } from "../hooks/useCrystals";
import { truncateAddress, truncateTokenId } from "../lib/format";
import { TABS, type TabId } from "../tabs";

type Props = {
  active: TabId;
  onSelect: (tab: TabId) => void;
};

export function Navbar({ active, onSelect }: Props) {
  const address = useConnectedAddress();
  const crystal = usePrimaryCrystal();

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
