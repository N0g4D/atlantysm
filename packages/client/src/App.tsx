import { useState } from "react";

import { Navbar } from "./components/Navbar";
import { ArenaPanel } from "./components/ArenaPanel";
import { ForgePanel, SanctuaryPanel } from "./components/panels";
import { DEFAULT_TAB, type TabId } from "./tabs";

/**
 * Layout shell. Navigation is plain React state — there is no router because there is nothing yet
 * worth a URL, and adding one now would be a dependency paid for on a promise.
 */
export function App() {
  const [tab, setTab] = useState<TabId>(DEFAULT_TAB);

  return (
    <div className="flex min-h-screen flex-col">
      <Navbar active={tab} onSelect={setTab} />

      <main className="mx-auto w-full max-w-5xl flex-1 px-6 py-10">
        {tab === "forge" ? <ForgePanel /> : null}
        {tab === "sanctuary" ? <SanctuaryPanel /> : null}
        {tab === "arena" ? <ArenaPanel /> : null}
      </main>

      <footer className="mx-auto w-full max-w-5xl px-6 pb-8">
        <p className="muted">Atlantysm — fully on-chain, MUD v2.</p>
      </footer>
    </div>
  );
}
