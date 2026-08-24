/*
 * The MUD client code is built on top of viem
 * (https://viem.sh/docs/getting-started.html).
 * This line imports the functions we need from it.
 */
import {
  createPublicClient,
  fallback,
  webSocket,
  http,
  createWalletClient,
  Hex,
  ClientConfig,
  getContract,
} from "viem";
import { encodeEntity, syncToRecs } from "@latticexyz/store-sync/recs";

import { getNetworkConfig } from "./getNetworkConfig";
import { world } from "./world";
// See createSystemCalls.ts: `abi/` is the committed copy of Foundry's gitignored `out/`.
import IWorldAbi from "contracts/abi/IWorld.abi.json";
import { createBurnerAccount, transportObserver, ContractWrite } from "@latticexyz/common";
import { transactionQueue, writeObserver } from "@latticexyz/common/actions";

import { Subject, share } from "rxjs";

/*
 * Import our MUD config, which includes strong types for
 * our tables and other config options. We use this to generate
 * things like RECS components and get back strong types for them.
 *
 * See https://mud.dev/templates/typescript/contracts#mudconfigts
 * for the source of this information.
 */
import mudConfig from "contracts/mud.config";

export type SetupNetworkResult = Awaited<ReturnType<typeof setupNetwork>>;

export async function setupNetwork() {
  const networkConfig = await getNetworkConfig();

  /*
   * Create a viem public (read only) client
   * (https://viem.sh/docs/clients/public.html)
   */
  /*
   * Offer the WebSocket transport ONLY when the chain actually declares one.
   *
   * viem's `webSocket()` resolves its url from `chain.rpcUrls.default.webSocket[0]` and throws
   * `UrlRequiredError` when there is none — which is the case for Sepolia. `fallback` does not
   * rescue that: it instantiates each transport OUTSIDE its own try/catch, so the throw escapes
   * before `http()` is ever tried and EVERY rpc call fails. Combined with the missing error
   * boundary (open point 2 at code freeze) the symptom is a permanently blank page, with the real
   * cause visible only in the console.
   */
  const webSocketUrl = networkConfig.chain.rpcUrls.default.webSocket?.[0];
  const transports = webSocketUrl ? [webSocket(), http()] : [http()];

  const clientOptions = {
    chain: networkConfig.chain,
    transport: transportObserver(fallback(transports)),
    pollingInterval: 1000,
  } as const satisfies ClientConfig;

  const publicClient = createPublicClient(clientOptions);

  /*
   * Create an observable for contract writes that we can
   * pass into MUD dev tools for transaction observability.
   */
  const write$ = new Subject<ContractWrite>();

  /*
   * Create a temporary wallet and a viem client for it
   * (see https://viem.sh/docs/clients/wallet.html).
   */
  const burnerAccount = createBurnerAccount(networkConfig.privateKey as Hex);
  const burnerWalletClient = createWalletClient({
    ...clientOptions,
    account: burnerAccount,
  })
    .extend(transactionQueue())
    .extend(writeObserver({ onWrite: (write) => write$.next(write) }));

  /*
   * Create an object for communicating with the deployed World.
   */
  const worldContract = getContract({
    address: networkConfig.worldAddress as Hex,
    abi: IWorldAbi,
    client: { public: publicClient, wallet: burnerWalletClient },
  });

  /*
   * Sync on-chain state into RECS and keeps our client in sync.
   * Uses the MUD indexer if available, otherwise falls back
   * to the viem publicClient to make RPC calls to fetch MUD
   * events from the chain.
   */
  const { components, latestBlock$, storedBlockLogs$, waitForTransaction } = await syncToRecs({
    world,
    config: mudConfig,
    address: networkConfig.worldAddress as Hex,
    publicClient,
    startBlock: BigInt(networkConfig.initialBlockNumber),
  });

  return {
    world,
    components,
    playerEntity: encodeEntity({ address: "address" }, { address: burnerWalletClient.account.address }),
    publicClient,
    walletClient: burnerWalletClient,
    latestBlock$,
    storedBlockLogs$,
    waitForTransaction,
    worldContract,
    write$: write$.asObservable().pipe(share()),
  };
}
