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
- **Crystals:** ERC-721 tokens.
- **Mana (Energy):** ERC-20 tokens.
- **Token Bound Accounts (TBA):** ERC-6551. EVERY Crystal is its own smart contract wallet holding its Mana.
- **Combat Resolution:** Handled by a stateless `ArenaSystem` contract.

## 4. Coding Guidelines for LLMs (STRICT)
- **Security First:** Always check for reentrancy (CEI pattern), front-running, and oracle manipulation.
- **Gas Optimization:** Pack structs tightly (e.g., uint128/uint96/uint32) in MUD `mud.config.ts`.
- **MUD Conventions:** Do not use standard mapping/arrays for game state. ALWAYS use MUD Tables (Components) defined in `mud.config.ts`. Game logic MUST reside in `System` contracts.
- **Testing:** Every System MUST have an equivalent `forge test` file. Assert state changes explicitly.

## 5. Tooling & Execution Strategy
- **Web research & documentation — Tavily only:** All web search, page retrieval and documentation lookups MUST go through the Tavily MCP tools (`tavily_search`, `tavily_extract`, `tavily_crawl`, `tavily_map`, `tavily_research`). Do not use any other web tool.
- **When unsure about MUD API:** Do NOT hallucinate. Use `tavily_extract` on the relevant page under `https://mud.dev/docs` (or `tavily_map` to locate it first) before writing any MUD-specific code.
- **When encountering unknown Foundry errors:** Use `tavily_search` on the specific error string.
- **File System Usage:** Inspect `packages/contracts/src` and `packages/contracts/test` with the built-in file reading and search tools before proposing a file overwrite, to ensure you understand the current state of the smart contracts.