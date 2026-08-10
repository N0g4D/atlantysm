# Atlantysm - System Architecture & Coding Guidelines

## 1. Project Overview
Atlantysm is a Fully On-Chain Game (FOCG) built on EVM. It features a techno-fantasy setting where Magic Crystals act as autonomous entities.
The game logic is 100% on-chain, relying on the MUD framework (Entity-Component-System).

## 2. Tech Stack
- **Framework:** MUD (mud.dev) v2.
- **Smart Contracts:** Solidity ^0.8.24.
- **Testing:** Foundry (forge).
- **Frontend:** React + TypeScript + viem/wagmi (managed in a separate workspace package).
- **Architecture:** ECS (Entity-Component-System).

## 3. Core Mechanics & Standards
- **Crystals:** ERC-721 tokens. `tokenId` is stored as `uint256` so any ERC-721 id — sequential, hashed or random — round-trips without truncation.
- **Mana (Energy):** the MUD table `ManaBalance` is the **single and absolute source of truth** in-game. There is no ERC-20 contract to keep in sync, and therefore no synchronisation rule and no risk of divergence. An ERC-20 interface may be added later strictly as a **facade/wrapper** that reads and writes this table; it is never authoritative. Systems MUST settle mana against `ManaBalance` only, and MUST NOT read a balance from, or write one to, any token contract.
- **Token Bound Accounts (TBA):** ERC-6551. EVERY Crystal is its own smart contract wallet. The TBA is the crystal's **identity**: an ECS entity id is the account address widened to `bytes32`, and `ManaBalance` is keyed by that entity. The account does not custody an ERC-20 mana balance — see above.
- **Identity — RATIFIED, and binding on every future System.** An entity is **always** `bytes32(uint256(uint160(tokenBoundAccount)))`. This is not a convention that may be revisited per-System; it is forced by `ArenaSystem`, which resolves a fighter as `bytes32(uint256(uint160(_msgSender())))`. Three consequences follow, and each rules out a simpler-looking alternative:
  - An entity **cannot be the owner's address**. Ownership is transferable and one owner may hold many crystals, but crystal state is keyed by entity — so an owner-keyed model would cap every address at one crystal and would move a crystal's whole history on each sale.
  - An entity **cannot be an arbitrary hash** of the `tokenId`. Nothing can ever call as such a value, so the crystal could be minted but could never fight.
  - Therefore the entity **must be derived at mint time** from the real ERC-6551 inputs. The entity key is permanent and load-bearing for `CrystalData`, `ManaBalance` and `ArenaLobby`, so a crystal written at a placeholder address is stranded with no migration path. `CrystalForgeSystem` is hard-gated on `ForgeConfig` for exactly this reason, and that config freezes on the first mint.
  - **A human forges, a crystal fights.** `mintCrystal(address to)` accepts an EOA as `to`; that address is the *owner*, recorded in `CrystalOwner`, and it is never the entity. Any System that needs "who is acting" must use the entity; any System that needs "who profits" must use the owner.
- **Ownership before the ERC-721 facade:** tracked provisionally in the `CrystalOwner` table, written only by `CrystalForgeSystem`. When the ERC-721 facade lands, `ownerOf(tokenId)` becomes authoritative and this table MUST be retired or demoted to a facade-maintained mirror — two independent writers for one fact is how ownership silently diverges. Note that no `tokenId → entity` index exists or is needed: the mapping is pure derivation (`crystalEntityOf`), so an index would be redundant state to keep in sync.
- **Native ETH vs Mana — two different currencies, and ETH never reaches a System.** ETH is the *external* currency (it gates minting); Mana is the *internal* one (`ManaBalance`). They must never be conflated. Critically, MUD does **not** forward `msg.value` to a System: `SystemCall` credits `Balances[namespaceId]` inside the **World** and then invokes the System with `call{value: 0}`, appending the original value to calldata as trusted context. Three rules follow, and they are binding on every future System:
  - Read a payment with **`_msgValue()`**, never `msg.value` — the latter is always 0 inside a namespaced System.
  - A System function that must receive ETH has to be declared **`payable`**, not because it ever holds ETH, but because worldgen mirrors the mutability onto `IWorld.<ns>__<fn>`; without it the World rejects the transaction before the System runs.
  - **Never write a `withdraw()` over `address(this).balance` in a System** — it is permanently zero, so the function would silently transfer nothing. Withdraw with `IWorld.transferBalanceToAddress(namespaceId, to, amount)`, which MUD ships already gated on namespace access.
- **Combat Resolution:** Handled by a stateless `ArenaSystem` contract, using **commit-reveal**. Moves are hidden until both players reveal, so no outcome is knowable before joining a match.

## 4. Coding Guidelines for LLMs (STRICT)
- **Security First:** Always check for reentrancy (CEI pattern), front-running, and oracle manipulation.
- **Gas Optimization — MUD packs by TOTAL WIDTH, not by field order.** Do not apply Solidity struct-packing reasoning to `mud.config.ts`. In a Solidity struct, field *order* matters because each field is padded into 32-byte slots. In MUD it does not: static fields are serialised **consecutively into a single `staticData` blob with no padding** (the official example places `uint200` + `uint8` + `uint16` back to back). What costs storage is only the **sum of the field widths**, rounded up to whole 32-byte slots. So: pick the narrowest type that cannot truncate the real value range (`uint128`/`uint32`/`uint8`), and do not waste effort reordering fields. The only real ordering constraint is that **static fields must precede dynamic ones**, and a key may only use fixed-length types. Verify the result rather than assuming it: the first 2 bytes of the generated `FieldLayout` constant are the total static width in bytes.
- **MUD Conventions:** Do not use standard mapping/arrays for game state. ALWAYS use MUD Tables (Components) defined in `mud.config.ts`. Game logic MUST reside in `System` contracts.
- **Testing:** Every System MUST have an equivalent `forge test` file. Assert state changes explicitly.

## 5. Tooling & Execution Strategy
- **Web research & documentation — Tavily only:** All web search, page retrieval and documentation lookups MUST go through the Tavily MCP tools (`tavily_search`, `tavily_extract`, `tavily_crawl`, `tavily_map`, `tavily_research`). Do not use any other web tool.
- **When unsure about MUD API:** Do NOT hallucinate. Use `tavily_extract` on the relevant page under `https://mud.dev/docs` (or `tavily_map` to locate it first) before writing any MUD-specific code.
- **When encountering unknown Foundry errors:** Use `tavily_search` on the specific error string.
- **File System Usage:** Inspect `packages/contracts/src` and `packages/contracts/test` with the built-in file reading and search tools before proposing a file overwrite, to ensure you understand the current state of the smart contracts.