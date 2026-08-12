import { useEffect, useMemo, useState } from "react";
import { useComponentValue, useEntityQuery } from "@latticexyz/react";
import { Has, type Entity } from "@latticexyz/recs";
import { encodeEntity } from "@latticexyz/store-sync/recs";
import type { Hex } from "viem";

import { useMud } from "../mud/MudProvider";
import { LOBBY_STATUS, REVEAL_WINDOW_SECONDS } from "../lib/commit";

export type Lobby = {
  id: Hex;
  challenger: Entity;
  opponent: Entity;
  winner: Entity;
  wager: bigint;
  createdAt: number;
  matchedAt: number;
  status: number;
};

const ZERO_ENTITY = `0x${"0".repeat(64)}` as Entity;

/**
 * Ids of every lobby currently synced.
 *
 * Only the SET is returned. Reading each lobby's fields here would repeat the phase 11 bug: a
 * status moving Open -> Matched touches `ArenaLobby` without changing which entities exist, so a
 * value read inside this memo would go stale exactly when the match got interesting. Each row
 * subscribes to its own record through `useLobby` instead.
 */
export function useLobbyIds(): Entity[] {
  const { components } = useMud();
  return useEntityQuery([Has(components.ArenaLobby)]);
}

export function useLobby(entity: Entity | undefined): Lobby | undefined {
  const { components } = useMud();
  const data = useComponentValue(components.ArenaLobby, entity);

  if (!entity || !data) return undefined;
  return {
    id: entity as Hex,
    challenger: data.challenger as Entity,
    opponent: data.opponent as Entity,
    winner: data.winner as Entity,
    wager: data.wager as bigint,
    createdAt: Number(data.createdAt),
    matchedAt: Number(data.matchedAt),
    status: Number(data.status),
  };
}

/** A single player's commit-reveal state inside a match. Keyed by both, so the two sides never mix. */
export function useCommitment(lobbyId: Entity, player: Entity | undefined) {
  const { components } = useMud();

  const key = useMemo(() => {
    if (!player) return undefined;
    return encodeEntity(
      { lobbyId: "bytes32", playerEntity: "bytes32" },
      { lobbyId: lobbyId as Hex, playerEntity: player as Hex },
    );
  }, [lobbyId, player]);

  return useComponentValue(components.MatchCommitment, key);
}

/**
 * Wall-clock seconds, ticking.
 *
 * The contract compares against `block.timestamp`, not against the browser. On a chain producing
 * blocks steadily the two agree to within seconds, and the reveal window is an hour, so the drift
 * cannot flip a decision. It CAN make a countdown read a second or two off — worth knowing before
 * anyone builds a tighter deadline on top of it.
 */
export function useNow(): number {
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));

  useEffect(() => {
    const timer = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
    return () => clearInterval(timer);
  }, []);

  return now;
}

export function revealDeadline(lobby: Lobby): number {
  return lobby.matchedAt + Number(REVEAL_WINDOW_SECONDS);
}

export function isLive(lobby: Lobby): boolean {
  return lobby.status === LOBBY_STATUS.Open || lobby.status === LOBBY_STATUS.Matched;
}

export function isEmptyEntity(entity: Entity): boolean {
  return !entity || entity === ZERO_ENTITY;
}

export function formatCountdown(seconds: number): string {
  if (seconds <= 0) return "scaduto";
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  return `${m}m ${s.toString().padStart(2, "0")}s`;
}
