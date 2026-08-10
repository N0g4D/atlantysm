import { defineWorld } from "@latticexyz/world";

export default defineWorld({
  namespace: "app",
  enums: {
    /**
     * Index 0 is a `None` sentinel on purpose: MUD returns a zero-filled record
     * for keys that were never written, so without it a non-existent lobby
     * would be indistinguishable from an open one.
     */
    LobbyStatus: ["None", "Open", "Matched", "Resolved", "Cancelled"],

    /**
     * Elemental move, chosen under commit-reveal. `None` at index 0 is again a sentinel:
     * an unrevealed commitment record reads back as zero, so without it a player who never
     * revealed would look like they had played a real move.
     *
     * The triangle is a strict cycle — Water > Fire > Earth > Water — so every element
     * beats exactly one and loses to exactly one. No element is dominant.
     */
    Element: ["None", "Fire", "Water", "Earth"],
  },
  tables: {
    /**
     * Per-crystal identity. Keyed by the ECS entity id, not by tokenId, so the
     * entity stays the stable reference across the ERC-721 and its ERC-6551 account.
     * `tokenId` is uint256 to stay bit-for-bit compatible with ERC-721, which
     * permits hashed or otherwise non-sequential ids.
     * Static width: 32 + 1 = 33 bytes, two storage slots.
     */
    CrystalData: {
      schema: {
        id: "bytes32",
        tokenId: "uint256",
        level: "uint8",
      },
      key: ["id"],
    },

    /**
     * In-game mana ledger, keyed by entity (a crystal's ERC-6551 account).
     * uint128 holds 3.4e38 base units — ~3.4e20 tokens at 18 decimals — while
     * costing half a slot instead of a full one.
     */
    ManaBalance: {
      schema: {
        id: "bytes32",
        amount: "uint128",
      },
      key: ["id"],
    },

    /**
     * Pending and resolved arena matches. ArenaSystem is stateless, so all match
     * state lives here. `wager` matches ManaBalance.amount width so staking mana
     * can never truncate.
     *
     * `winner` is bytes32(0) until settlement, and stays bytes32(0) on a draw — read it
     * together with `status`, never on its own.
     *
     * `matchedAt` is when the lobby left `Open`, and it is what the reveal deadline is
     * measured from. It cannot be folded into `createdAt`: a lobby may sit open for days
     * before someone joins, so a deadline derived from creation time could already be
     * expired the instant the match starts. Both are uint32 seconds and overflow in 2106.
     *
     * Static width: 32 + 32 + 32 + 16 + 4 + 4 + 1 = 121 bytes, four slots. Note that the
     * previous 85-byte version already cost three slots and `winner` alone pushes it to
     * four, so `matchedAt` is free in storage terms.
     */
    ArenaLobby: {
      schema: {
        id: "bytes32",
        challenger: "bytes32",
        opponent: "bytes32",
        winner: "bytes32",
        wager: "uint128",
        createdAt: "uint32",
        matchedAt: "uint32",
        status: "LobbyStatus",
      },
      key: ["id"],
    },

    /**
     * Commit-reveal state, one record per player per match. Keyed by both so the two
     * sides of a match never collide and each can be read independently.
     *
     * `commitment` is keccak256(abi.encodePacked(move, salt)) and is written when the
     * player enters the match; `move` stays `None` until that player reveals.
     * `revealed` is the authoritative flag — do not infer it from `move != None`, since
     * a future move enum could legitimately include a zero-valued entry.
     *
     * Static width: 32 + 1 + 1 = 34 bytes, two slots.
     */
    MatchCommitment: {
      schema: {
        lobbyId: "bytes32",
        playerEntity: "bytes32",
        commitment: "bytes32",
        move: "Element",
        revealed: "bool",
      },
      key: ["lobbyId", "playerEntity"],
    },

    /**
     * Provisional ownership ledger, keyed by the crystal's entity (its ERC-6551 account).
     *
     * This is a STOPGAP and is deliberately not the long-term source of truth. Once the ERC-721
     * facade exists, `ownerOf(tokenId)` becomes authoritative and this table must either be
     * retired or demoted to a mirror kept in sync by the facade. Two writers for one fact is a
     * divergence bug waiting to happen, so it must never be left as-is after the facade lands.
     *
     * Note the asymmetry that makes this safe in the meantime: the OWNER is an EOA (or any
     * contract) and may change hands freely, while the ENTITY is the token bound account and is
     * immutable for the life of the crystal. Everything the game keys on — CrystalData,
     * ManaBalance, ArenaLobby — hangs off the entity, so a transfer of ownership moves no game
     * state at all.
     *
     * Static width: 20 bytes, one slot.
     */
    CrystalOwner: {
      schema: {
        id: "bytes32",
        owner: "address",
      },
      key: ["id"],
    },

    /**
     * The ERC-6551 inputs needed to derive a crystal's token bound account, and through it the
     * crystal's entity. Singleton.
     *
     * This table exists because the entity key is PERMANENT: CrystalData, ManaBalance and
     * ArenaLobby all hang off it. Deriving it from placeholder values now would mean every crystal
     * minted before the real ERC-721 exists sits at an address that will never be its account —
     * unrecoverable without a migration. So minting is hard-gated on this being set, and the
     * addresses are configuration rather than constants.
     *
     * `accountSalt` is the ERC-6551 salt, not a randomness source; it is fixed per deployment so
     * that account derivation stays reproducible.
     *
     * Static width: 20 + 20 + 20 + 32 = 92 bytes, three slots.
     */
    ForgeConfig: {
      schema: {
        accountRegistry: "address",
        accountImplementation: "address",
        tokenContract: "address",
        accountSalt: "bytes32",
      },
      key: [],
    },

    /**
     * Monotonic counter used ONLY as an entropy input to token id derivation, never as the id
     * itself. Singleton.
     *
     * It exists to fix a concrete collision, not a theoretical one: without it, two mints in the
     * same block from the same sender to the same recipient share every other preimage input
     * (timestamp, sender, recipient) and would derive an identical token id. See the token id
     * discussion in CrystalForgeSystem.
     *
     * Static width: 32 bytes, one slot.
     */
    ForgeNonce: {
      schema: {
        value: "uint256",
      },
      key: [],
    },
  },
});
