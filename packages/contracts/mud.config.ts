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
     * Number of crystals held per owner. Exists solely so the ERC-721 facade can answer
     * `balanceOf` — `CrystalOwner` maps entity to owner, and inverting that on-chain would mean
     * iterating every entity, which is exactly the "impossible loop" a counter avoids.
     *
     * It is derived state and therefore a consistency risk: it must be updated by every write that
     * touches `CrystalOwner`, and nothing else may write it. Both writers live in the `app`
     * namespace (`CrystalForgeSystem` on mint, `TokenBridgeSystem` on transfer) and the test suite
     * asserts the two stay in agreement.
     *
     * Static width: 32 bytes, one slot.
     */
    CrystalBalance: {
      schema: {
        owner: "address",
        count: "uint256",
      },
      key: ["owner"],
    },

    /**
     * Circulating mana, for the ERC-20 facade's `totalSupply`. Same reasoning as `CrystalBalance`:
     * summing `ManaBalance` on-chain is impossible, so the figure has to be maintained.
     *
     * Only `ProgressionSystem` moves it — the faucet mints and levelling burns. Arena settlement is
     * zero-sum and deliberately does NOT touch it, and a mana transfer between two holders does not
     * either.
     *
     * Static width: 32 bytes, one slot.
     */
    ManaSupply: {
      schema: {
        value: "uint256",
      },
      key: [],
    },

    /**
     * Addresses of the two token facades. Singleton.
     *
     * This is the access-control anchor for the whole phase: the token Systems accept calls from
     * these addresses and from nobody else, which is what keeps the ERC-721/ERC-20 surface from
     * becoming a second, unguarded way to rewrite ownership or mana. Unset reads as address(0),
     * which no caller can ever be, so the gate fails closed before it is configured.
     *
     * Static width: 40 bytes, two slots.
     */
    TokenFacade: {
      schema: {
        crystalNft: "address",
        manaToken: "address",
      },
      key: [],
    },

    /**
     * Price of one mint, in native ETH wei. Singleton. This is the sybil gate: it is what stops the
     * forge — and through the faucet, the mana supply — from being an infinite free printer.
     *
     * `configured` is a deliberate sentinel rather than a "price 0 means free" convention. A
     * never-written record reads back as zero, so without the flag a deployment that simply forgot
     * to set a price would mint for free and look completely healthy. With it, minting is blocked
     * until someone states a price on purpose — and a genuinely free mint stays expressible, by
     * setting `configured = true` with `price = 0`.
     *
     * Unlike `ForgeConfig`, this table must NOT freeze after the first mint: identity derivation is
     * permanent, but a price is an economic lever that has to stay tunable.
     *
     * Static width: 1 + 32 = 33 bytes, two slots.
     */
    MintPrice: {
      schema: {
        configured: "bool",
        price: "uint256",
      },
      key: [],
    },

    /**
     * One-shot marker for the starter mana faucet, keyed by the crystal's entity.
     *
     * A separate table rather than a field on `CrystalData` for two reasons. MUD table schemas are
     * immutable once created, so extending `CrystalData` means replacing a table that three Systems
     * already read. And the faucet is progression state, not identity: keeping it out of
     * `CrystalData` means the hot read path (`_requireCrystal`, run on every arena action) does not
     * widen to carry a flag it never looks at.
     *
     * `claimed` is authoritative on its own — do not infer eligibility from `ManaBalance`, since a
     * crystal can legitimately hold zero mana after spending everything.
     *
     * Static width: 1 byte, one slot.
     */
    StarterManaClaimed: {
      schema: {
        id: "bytes32",
        claimed: "bool",
      },
      key: ["id"],
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
