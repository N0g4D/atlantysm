/*
 * The write paths. Everything the UI can change on-chain goes through here.
 */

import { encodeFunctionData, getAddress, type Hex } from "viem";
import { getComponentValue, type Entity } from "@latticexyz/recs";
import { singletonEntity } from "@latticexyz/store-sync/recs";

import IWorldAbi from "contracts/out/IWorld.sol/IWorld.abi.json";
import CrystalNFTAbi from "contracts/out/CrystalNFT.sol/CrystalNFT.abi.json";
import AtlantysmAccountAbi from "contracts/out/AtlantysmAccount.sol/AtlantysmAccount.abi.json";

import { ClientComponents } from "./createClientComponents";
import { SetupNetworkResult } from "./setupNetwork";

export type SystemCalls = ReturnType<typeof createSystemCalls>;

/**
 * A crystal's ERC-6551 account address is its entity, narrowed back to 20 bytes — the entity IS the
 * account, widened. Deriving it locally avoids a round trip for something that is pure arithmetic.
 */
export function accountAddressOf(entity: Entity): Hex {
  return getAddress(`0x${entity.slice(-40)}`);
}

export function createSystemCalls(
  { walletClient, waitForTransaction, worldContract }: SetupNetworkResult,
  components: ClientComponents,
) {
  const account = walletClient.account;

  /** Reads the wiring PostDeploy left. Throws with a readable reason rather than a revert blob. */
  function requireFacade(): Hex {
    const facades = getComponentValue(components.TokenFacade, singletonEntity);
    if (!facades?.crystalNft) throw new Error("Nessuna facade NFT registrata nel World.");
    return getAddress(facades.crystalNft as Hex);
  }

  function requireMintPrice(): bigint {
    const price = getComponentValue(components.MintPrice, singletonEntity);
    // The `configured` flag is the sentinel from phase 6: an unset price reads as 0, which would
    // otherwise look like a free mint right up until the transaction reverts.
    if (!price?.configured) throw new Error("La forgia non ha ancora un prezzo configurato.");
    return price.price as bigint;
  }

  /**
   * Mint through the ERC-721 facade — the only path that creates a crystal (phase 7), and the one
   * that also deploys its token bound account in the same transaction (phase 9).
   */
  async function mintCrystal(): Promise<Hex> {
    const nft = requireFacade();
    const value = requireMintPrice();

    const hash = await walletClient.writeContract({
      chain: walletClient.chain,
      account,
      address: nft,
      abi: CrystalNFTAbi,
      functionName: "mint",
      args: [account.address],
      // Payment must be EXACT: overpaying reverts too, so there is no rounding up here.
      value,
    });

    await waitForTransaction(hash);
    return hash;
  }

  /**
   * Route a World call through the crystal's own account.
   *
   * This is not optional plumbing — it is the identity model. Every System resolves the actor from
   * `_msgSender()`, so a call sent straight from the burner wallet would arrive as the HUMAN and be
   * rejected: the human owns the crystal but is not one. Going through `callSystem` makes the
   * account the sender, which is exactly what the Systems expect.
   */
  async function callAsCrystal(entity: Entity, data: Hex): Promise<Hex> {
    const hash = await walletClient.writeContract({
      chain: walletClient.chain,
      account,
      address: accountAddressOf(entity),
      abi: AtlantysmAccountAbi,
      functionName: "callSystem",
      args: [worldContract.address, data],
    });

    await waitForTransaction(hash);
    return hash;
  }

  // `args: []` is required even for zero-argument functions: with a strongly typed ABI viem cannot
  // otherwise narrow which overload is meant.
  async function claimStarterMana(entity: Entity): Promise<Hex> {
    return callAsCrystal(
      entity,
      encodeFunctionData({ abi: IWorldAbi, functionName: "app__claimStarterMana", args: [] }),
    );
  }

  async function levelUp(entity: Entity): Promise<Hex> {
    return callAsCrystal(entity, encodeFunctionData({ abi: IWorldAbi, functionName: "app__levelUp", args: [] }));
  }

  // -----------------------------------------------------------------------------------------
  // Arena
  // -----------------------------------------------------------------------------------------

  async function createLobby(entity: Entity, lobbySalt: Hex, wager: bigint, commitment: Hex): Promise<Hex> {
    return callAsCrystal(
      entity,
      encodeFunctionData({ abi: IWorldAbi, functionName: "app__createLobby", args: [lobbySalt, wager, commitment] }),
    );
  }

  async function joinLobby(entity: Entity, lobbyId: Hex, commitment: Hex): Promise<Hex> {
    return callAsCrystal(
      entity,
      encodeFunctionData({ abi: IWorldAbi, functionName: "app__joinLobby", args: [lobbyId, commitment] }),
    );
  }

  async function revealMove(entity: Entity, lobbyId: Hex, move: number, salt: Hex): Promise<Hex> {
    return callAsCrystal(
      entity,
      encodeFunctionData({ abi: IWorldAbi, functionName: "app__revealMove", args: [lobbyId, move, salt] }),
    );
  }

  async function claimTimeout(entity: Entity, lobbyId: Hex): Promise<Hex> {
    return callAsCrystal(
      entity,
      encodeFunctionData({ abi: IWorldAbi, functionName: "app__claimTimeout", args: [lobbyId] }),
    );
  }

  async function cancelLobby(entity: Entity, lobbyId: Hex): Promise<Hex> {
    return callAsCrystal(
      entity,
      encodeFunctionData({ abi: IWorldAbi, functionName: "app__cancelLobby", args: [lobbyId] }),
    );
  }

  /**
   * Settle a fully revealed match.
   *
   * Sent straight from the wallet, NOT through a crystal's account — and that is not an
   * inconsistency. `resolveMatch` is permissionless by design (phase 3.5): with both moves already
   * on-chain the outcome is fixed, so ordering the transaction gains nothing and any keeper may
   * drive it. Routing it through a token bound account would add a hop and quietly require the
   * caller to own a crystal.
   */
  async function resolveMatch(lobbyId: Hex): Promise<Hex> {
    const hash = await walletClient.writeContract({
      chain: walletClient.chain,
      account,
      address: worldContract.address,
      abi: IWorldAbi,
      functionName: "app__resolveMatch",
      args: [lobbyId],
    });

    await waitForTransaction(hash);
    return hash;
  }

  return {
    mintCrystal,
    claimStarterMana,
    levelUp,
    createLobby,
    joinLobby,
    revealMove,
    resolveMatch,
    claimTimeout,
    cancelLobby,
  };
}
