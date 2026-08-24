/*
 * The supported chains.
 *
 * - mudFoundry, the chain running on anvil that pnpm dev
 *   starts by default. It is similar to the viem anvil chain
 *   (see https://viem.sh/docs/clients/test.html), but with the
 *   basefee set to zero to avoid transaction fees.
 * - Redstone, MUD's production blockchain (https://redstone.xyz/)
 * - Garnet, MUD's test blockchain (https://garnetchain.com/)
 * - Sepolia, where the hosted demo lives.
 *
 */

import { MUDChain, mudFoundry, redstone, garnet } from "@latticexyz/common/chains";
import { sepolia as sepoliaConfig } from "viem/chains";

/*
 * Ethereum Sepolia (11155111), for the Vercel deployment.
 *
 * The RPC endpoint is overridable because the default will not carry a demo. A MUD client replays
 * every `Store_*` log from the World's deploy block on load, so the first paint costs a burst of
 * `eth_getLogs` — precisely what a shared public endpoint throttles. Set VITE_SEPOLIA_RPC_HTTP to
 * a dedicated key (Alchemy, Infura, drpc) for anything you intend to demo.
 *
 * The baked-in default is publicnode rather than viem's own, which is worth stating because it
 * looks like gratuitous divergence: viem's Sepolia default is https://sepolia.drpc.org, and that
 * host now answers "chain is not available on free plan" — a hard error on every call, i.e. a
 * blank page. Checked against the live endpoints, not assumed.
 *
 * WebSocket is opt-in and absent by default: viem's `webSocket()` throws `UrlRequiredError` when
 * the chain declares no socket url, and `fallback` does not catch it (see setupNetwork.ts). Only
 * advertise one here if VITE_SEPOLIA_RPC_WS really points at a working endpoint.
 */
const sepoliaHttpUrl = import.meta.env.VITE_SEPOLIA_RPC_HTTP || "https://ethereum-sepolia-rpc.publicnode.com";
const sepoliaWebSocketUrl = import.meta.env.VITE_SEPOLIA_RPC_WS;

export const sepolia: MUDChain = {
  ...sepoliaConfig,
  rpcUrls: {
    ...sepoliaConfig.rpcUrls,
    default: {
      http: [sepoliaHttpUrl],
      ...(sepoliaWebSocketUrl ? { webSocket: [sepoliaWebSocketUrl] } : {}),
    },
  },
};

/*
 * See https://mud.dev/guides/hello-world/add-chain-client
 * for instructions on how to add networks.
 */
export const supportedChains: MUDChain[] = [mudFoundry, redstone, garnet, sepolia];
