/*
 * Network specific configuration for the client.
 * By default connect to the anvil test network.
 */

/*
 * By default the template just creates a temporary wallet
 * (called a burner wallet).
 */
import { getBurnerPrivateKey } from "@latticexyz/common";
import { isHex, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";

/*
 * Import the addresses of the World, possibly on multiple chains,
 * from packages/contracts/worlds.json. When the contracts package
 * deploys a new `World`, it updates this file.
 */
import worlds from "contracts/worlds.json";

/*
 * The supported chains.
 */

import { supportedChains } from "./supportedChains";

/*
 * MUD's own cache key. This MUST stay byte-identical to the default in
 * `@latticexyz/common`'s getBurnerPrivateKey, because the entire mechanism below is to prime the
 * slot that function is about to read. If MUD ever renames it, `?burner=` silently stops working:
 * the key would be stored, ignored, and a fresh unfunded wallet generated in its place.
 */
const BURNER_CACHE_KEY = "mud:burnerWallet";

/*
 * Where a replaced burner goes. Adopting a promo link overwrites whatever wallet was there, which
 * is the point — but during a demo the previous wallet may own a crystal, and its key is the only
 * way back to it. Keeping one copy costs nothing and turns "I lost my crystal" into a console line.
 */
const BURNER_BACKUP_KEY = "mud:burnerWallet:replaced";

/**
 * Adopt a private key handed over in the URL: `https://<host>/?burner=0x...`
 *
 * This is what makes the promo links work, and it does NOT come for free with MUD —
 * `getBurnerPrivateKey` only ever reads its localStorage cache and generates a new key when the
 * cache is empty. It has no notion of a URL parameter. So we write the cache ourselves, first.
 *
 * Called before `getBurnerPrivateKey()` — and `setup()` is awaited before React mounts, so the key
 * is in place well before any component can ask who the player is.
 */
function adoptBurnerFromUrl(): void {
  const params = new URLSearchParams(window.location.search);
  const candidate = params.get("burner");
  if (candidate === null) return;

  const privateKey = (candidate.startsWith("0x") ? candidate : `0x${candidate}`) as Hex;

  /*
   * Validate before storing. MUD's own `assertPrivateKey` THROWS on a malformed cached key, and
   * with no error boundary that surfaces as a permanently blank page — from which the user cannot
   * even clear the bad value, since the broken key would be re-read on every reload. A typo'd link
   * has to degrade to "ordinary burner", never to a bricked origin.
   */
  let address: string;
  try {
    if (!isHex(privateKey) || privateKey.length !== 66) {
      throw new Error(`expected 32 bytes of hex, got ${privateKey.length - 2} characters`);
    }
    address = privateKeyToAccount(privateKey).address;
  } catch (error) {
    // Deliberately NOT stripped from the URL: leaving it visible is what lets someone read the
    // broken link and see which character is wrong.
    console.error("[atlantysm] ignoring malformed ?burner= parameter, falling back to a local burner", error);
    return;
  }

  const previous = localStorage.getItem(BURNER_CACHE_KEY);
  if (previous !== null && previous !== privateKey) {
    localStorage.setItem(BURNER_BACKUP_KEY, previous);
    console.warn(
      `[atlantysm] replacing the existing burner wallet. The previous key is kept at ` +
        `localStorage["${BURNER_BACKUP_KEY}"] — it is the only way back to anything that wallet owns.`,
    );
  }

  localStorage.setItem(BURNER_CACHE_KEY, privateKey);
  console.log(`[atlantysm] adopted burner wallet from URL: ${address}`);

  /*
   * Strip the key from the address bar. It stays in localStorage, so this costs nothing — and a
   * private key left in the URL is one screenshot, one shared link or one shoulder-glance away
   * from being someone else's. `replaceState` also keeps it out of the back-button history.
   * Every other parameter (chainId, worldAddress, initialBlockNumber) is preserved.
   */
  params.delete("burner");
  const query = params.toString();
  window.history.replaceState({}, "", `${window.location.pathname}${query ? `?${query}` : ""}${window.location.hash}`);
}

export async function getNetworkConfig() {
  adoptBurnerFromUrl();

  const params = new URLSearchParams(window.location.search);

  /*
   * The chain ID is the first item available from this list:
   * 1. chainId query parameter
   * 2. chainid query parameter
   * 3. The VITE_CHAIN_ID environment variable set when the
   *    vite dev server was started or client was built
   * 4. The default, 31337 (anvil)
   */
  const chainId = Number(params.get("chainId") || params.get("chainid") || import.meta.env.VITE_CHAIN_ID || 31337);

  /*
   * Find the chain (unless it isn't in the list of supported chains).
   */
  const chainIndex = supportedChains.findIndex((c) => c.id === chainId);
  const chain = supportedChains[chainIndex];
  if (!chain) {
    throw new Error(`Chain ${chainId} not found`);
  }

  /*
   * Get the address of the World. If you want to use a
   * different address than the one in worlds.json,
   * provide it as worldAddress in the query string.
   */
  const world = worlds[chain.id.toString()];
  const worldAddress = params.get("worldAddress") || world?.address;
  if (!worldAddress) {
    throw new Error(`No world address found for chain ${chainId}. Did you run \`mud deploy\`?`);
  }

  /*
   * MUD clients use events to synchronize the database, meaning
   * they need to look as far back as when the World was started.
   * The block number for the World start can be specified either
   * on the URL (as initialBlockNumber) or in the worlds.json
   * file. If neither has it, it starts at the first block, zero.
   */
  const initialBlockNumber = params.has("initialBlockNumber")
    ? Number(params.get("initialBlockNumber"))
    : world?.blockNumber ?? 0n;

  return {
    privateKey: getBurnerPrivateKey(),
    chainId,
    chain,
    worldAddress,
    initialBlockNumber,
  };
}
