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
     * can never truncate. Static width: 32 + 32 + 16 + 4 + 1 = 85 bytes.
     */
    ArenaLobby: {
      schema: {
        id: "bytes32",
        challenger: "bytes32",
        opponent: "bytes32",
        wager: "uint128",
        createdAt: "uint32",
        status: "LobbyStatus",
      },
      key: ["id"],
    },
  },
});
