# Phase 2: On-Chain Data Structures
**Goal:** Definire lo stato in `mud.config.ts`.
**Constraints:**
1. Lavora SOLO sul file `mud.config.ts`.
2. Crea le tabelle:
   - `CrystalData` (EntityID -> `tokenId uint256`, `level uint8`). `tokenId` è `uint256` per
     compatibilità piena con ERC-721, che ammette id non sequenziali o derivati da hash.
   - `ManaBalance` (EntityID -> `amount uint128`). Questa tabella è l'**unica fonte di verità**
     del Mana in-game: non esiste alcun ERC-20 da sincronizzare. L'interfaccia ERC-20 sarà un
     Facade/Wrapper costruito sopra questa tabella. I System devono leggere solo da qui.
   - `ArenaLobby` (EntityID -> `challenger bytes32`, `opponent bytes32`, `wager uint128`,
     `createdAt uint32`, `status LobbyStatus`). `ArenaSystem` è stateless, quindi tutto lo stato
     del match vive qui. `challenger` e `opponent` sono entity id ECS (`bytes32`) e non tokenId:
     si privilegia l'integrità del pattern ECS rispetto al risparmio di storage.
   - Enum `LobbyStatus`: `None` in posizione 0 come sentinella. MUD restituisce un record
     azzerato per chiavi mai scritte, quindi senza `None` una lobby inesistente sarebbe
     indistinguibile da una aperta.
3. Non scrivere i System contracts.
4. Esegui `pnpm build` per rigenerare le interfacce Solidity e verifica la compilazione.

**Nota sul packing.** In MUD i campi statici sono serializzati consecutivamente in `staticData`
senza padding a 32 byte: conta la larghezza totale dei tipi, non il loro ordine (a differenza
delle struct Solidity). L'unico vincolo d'ordine è che i campi statici devono precedere quelli
dinamici, e la chiave ammette solo tipi a lunghezza fissa.