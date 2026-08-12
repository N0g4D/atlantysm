import { encodeAbiParameters, encodePacked, keccak256, type Hex } from "viem";
import type { Entity } from "@latticexyz/recs";

/**
 * Client-side half of the arena's commit-reveal.
 *
 * Every value here must match `ArenaSystem` byte for byte. A mismatch does not fail loudly at
 * commit time — the contract only ever sees a hash — it fails hours later when the reveal is
 * rejected and the player loses the match by timeout. The two encodings below are therefore
 * spelled out rather than inferred, and cross-checked against `cast` in the phase report.
 */

/** `enum Element { None, Fire, Water, Earth }` — the ORDER is the on-chain value. */
export const ELEMENT = {
  None: 0,
  Fire: 1,
  Water: 2,
  Earth: 3,
} as const;

export type ElementName = "Fire" | "Water" | "Earth";
export const PLAYABLE_ELEMENTS: ElementName[] = ["Fire", "Water", "Earth"];

/** `enum LobbyStatus { None, Open, Matched, Resolved, Cancelled }`. */
export const LOBBY_STATUS = {
  None: 0,
  Open: 1,
  Matched: 2,
  Resolved: 3,
  Cancelled: 4,
} as const;

/** `ArenaSystem.REVEAL_WINDOW`, in seconds. */
export const REVEAL_WINDOW_SECONDS = 3600n;

/**
 * `keccak256(abi.encode(challenger, lobbySalt))`.
 *
 * NOTE the encoding: `abi.encode`, so both operands are padded to 32 bytes — 64 bytes of preimage.
 * `encodePacked` would produce the same bytes here only by accident of both being bytes32, but the
 * contract says `encode` and matching it exactly is the whole point.
 */
export function deriveLobbyId(challenger: Entity, lobbySalt: Hex): Hex {
  return keccak256(
    encodeAbiParameters([{ type: "bytes32" }, { type: "bytes32" }], [challenger as Hex, lobbySalt]),
  );
}

/**
 * `keccak256(abi.encodePacked(lobbyId, playerEntity, move, salt))`.
 *
 * PACKED, and the move is a single byte because a Solidity enum packs as uint8. Encoding it as a
 * uint256 — the natural mistake — shifts the salt by 31 bytes and produces a commitment that can
 * never be opened.
 *
 * Binding lobby and player into the hash is phase 3.6: it stops a commitment being replayed in
 * another match or worn by another player.
 */
export function deriveCommitment(lobbyId: Hex, player: Entity, move: number, salt: Hex): Hex {
  return keccak256(
    encodePacked(["bytes32", "bytes32", "uint8", "bytes32"], [lobbyId, player as Hex, move, salt]),
  );
}

/** A fresh 32-byte salt. The salt is what hides the move — with only three of them, a weak one is
 * brute-forced instantly, so this uses the CSPRNG rather than Math.random. */
export function randomSalt(): Hex {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return `0x${Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("")}`;
}

// -----------------------------------------------------------------------------------------
// Secret storage
// -----------------------------------------------------------------------------------------

export type MatchSecret = {
  move: number;
  salt: Hex;
};

const STORAGE_PREFIX = "atlantysm:secret:";

function secretKey(lobbyId: Hex, player: Entity): string {
  return `${STORAGE_PREFIX}${lobbyId}:${player}`;
}

/**
 * Persist the (move, salt) pair BEFORE the commit transaction is sent.
 *
 * Order matters and is not a detail: if the transaction lands and the secret was never written,
 * the player holds a commitment they cannot open. They cannot re-derive it either — the salt is
 * random — so the match is lost by timeout with the wager already escrowed. Writing first means
 * the worst case is a stored secret for a transaction that failed, which is harmless.
 *
 * localStorage is the honest minimum, not a good answer: it is per-browser and per-origin, so
 * clearing site data or switching device loses the match. See the open points in b.txt.
 */
export function rememberSecret(lobbyId: Hex, player: Entity, secret: MatchSecret): void {
  localStorage.setItem(secretKey(lobbyId, player), JSON.stringify(secret));
}

export function recallSecret(lobbyId: Hex, player: Entity): MatchSecret | undefined {
  const raw = localStorage.getItem(secretKey(lobbyId, player));
  if (!raw) return undefined;
  try {
    const parsed = JSON.parse(raw) as MatchSecret;
    if (typeof parsed?.move !== "number" || typeof parsed?.salt !== "string") return undefined;
    return parsed;
  } catch {
    return undefined;
  }
}

export function forgetSecret(lobbyId: Hex, player: Entity): void {
  localStorage.removeItem(secretKey(lobbyId, player));
}

export function elementName(value: number): string {
  return (Object.keys(ELEMENT) as (keyof typeof ELEMENT)[]).find((k) => ELEMENT[k] === value) ?? "?";
}
