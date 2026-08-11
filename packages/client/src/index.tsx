import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import mudConfig from "contracts/mud.config";

import { App } from "./App";
import { MudProvider } from "./mud/MudProvider";
import { setup } from "./mud/setup";
import "./index.css";

const rootElement = document.getElementById("root");
if (!rootElement) throw new Error("index.html is missing #root");

/*
 * MUD is bootstrapped BEFORE React mounts. Top-level await is deliberate: it means no component
 * ever has to render a "connecting…" state for the World, and `useMud()` can be non-nullable.
 */
const mud = await setup();

createRoot(rootElement).render(
  <StrictMode>
    <MudProvider value={mud}>
      <App />
    </MudProvider>
  </StrictMode>,
);

// https://vitejs.dev/guide/env-and-mode.html
if (import.meta.env.DEV) {
  const { mount: mountDevTools } = await import("@latticexyz/dev-tools");
  mountDevTools({
    config: mudConfig,
    publicClient: mud.network.publicClient,
    walletClient: mud.network.walletClient,
    latestBlock$: mud.network.latestBlock$,
    storedBlockLogs$: mud.network.storedBlockLogs$,
    worldAddress: mud.network.worldContract.address,
    worldAbi: mud.network.worldContract.abi,
    write$: mud.network.write$,
    recsWorld: mud.network.world,
  });
}
