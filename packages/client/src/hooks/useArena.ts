import { useEffect, useMemo, useState } from "react";
import { useComponentValue, useEntityQuery } from "@latticexyz/react";
import { Has, HasValue, getComponentValue, type Entity } from "@latticexyz/recs";
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

export type MatchResult = {
  lobby: Lobby;
  opponent: Entity;
  /** "win" | "loss" | "draw", from the point of view of the crystal that asked. */
  outcome: "win" | "loss" | "draw";
  /** NET mana change, not the pot: the winner staked the wager too, so it gains exactly `wager`. */
  delta: bigint;
};

/**
 * The most recent settled matches this crystal fought in, newest first.
 *
 * Two deliberate differences from `useLobbyIds`, both driven by the data rather than by taste:
 *
 *   - the query is `HasValue(..., { status: Resolved })`, not `Has`. A lobby moving Matched ->
 *     Resolved does not change WHICH entities exist, so a `Has` query would not re-run and a match
 *     would only appear in the history after some unrelated render. With `HasValue` the entity
 *     ENTERS the query as its status changes, which is exactly the event we want.
 *   - values are read inside the memo here, which would have been a bug in the live list. It is
 *     safe in this one because `Resolved` is TERMINAL: nothing in `ArenaSystem` writes a lobby
 *     again once it settles, so these records are immutable from here on.
 *
 * `Cancelled` is excluded on purpose — a withdrawn lobby or a match where nobody revealed is not a
 * battle, and both sides were refunded, so it has no outcome to report.
 */
export function useResolvedMatches(player: Entity | undefined, limit = 8): MatchResult[] {
  const { components } = useMud();
  const resolved = useEntityQuery([HasValue(components.ArenaLobby, { status: LOBBY_STATUS.Resolved })]);

  return useMemo(() => {
    if (!player) return [];

    return resolved
      .map((entity) => {
        const data = getComponentValue(components.ArenaLobby, entity);
        if (!data) return undefined;

        const challenger = data.challenger as Entity;
        const opponent = data.opponent as Entity;
        if (challenger !== player && opponent !== player) return undefined;

        const winner = data.winner as Entity;
        const wager = data.wager as bigint;

        const outcome: MatchResult["outcome"] = isEmptyEntity(winner)
          ? "draw"
          : winner === player
            ? "win"
            : "loss";

        return {
          lobby: {
            id: entity as Hex,
            challenger,
            opponent,
            winner,
            wager,
            createdAt: Number(data.createdAt),
            matchedAt: Number(data.matchedAt),
            status: Number(data.status),
          },
          opponent: challenger === player ? opponent : challenger,
          outcome,
          delta: outcome === "draw" ? 0n : wager,
        } satisfies MatchResult;
      })
      .filter((result): result is MatchResult => result !== undefined)
      .sort((a, b) => b.lobby.matchedAt - a.lobby.matchedAt)
      .slice(0, limit);
  }, [resolved, player, components, limit]);
}

export function formatCountdown(seconds: number): string {
  if (seconds <= 0) return "scaduto";
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  return `${m}m ${s.toString().padStart(2, "0")}s`;
}
