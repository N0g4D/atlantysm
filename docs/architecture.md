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