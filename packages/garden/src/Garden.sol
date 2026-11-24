// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FHE, ebool, euint8, euint16, euint64, externalEbool} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/**
 * @title Garden
 * @notice Atlantysm Season 0 (docs/RULES.md). Every crystal is an ERC-721 token whose element, level and MANA only
 *         its owner can read.
 * @dev One contract holds every encrypted value, and nobody can change it (docs/SEASON0.md §2): no owner, no admin,
 *      no proxy, no pause, no setter. A fix is a new deployment. Every rule parameter is fixed at construction.
 *
 *      The protocol derives a handle from its operation, its operands and the block, so whoever is allowed on every
 *      operand of an operation can recompute its result in that block and grant it to anyone, and anyone can
 *      recompute a trivial encryption. No handle this contract stores can be recomputed by anyone but itself and the
 *      crystal's owner (SEASON0.md §2.2, Handles).
 */
contract Garden is ZamaEthereumConfig, ERC721, ReentrancyGuardTransient {
    /// The parameters of RULES.md §12, fixed at deployment.
    struct Params {
        /// The ETH a crystal holds: paid to forge it, returned when it is shattered.
        uint256 charge;
        /// The MANA every crystal receives a day.
        uint64 manaPerDay;
        /// How long a season lasts, in seconds.
        uint256 seasonLength;
        /// A rise from level L to L + 1 costs `levelCost × L²` MANA.
        uint64 levelCost;
        /// The highest level a crystal can reach.
        uint8 maxLevel;
        /// The bounds of an Arena stake, in MANA.
        uint64 minStake;
        uint64 maxStake;
        /// How long a lobby must wait before its creator can cancel it, in seconds.
        uint256 lobbyTimeout;
        /// How long after a season ends it can be closed, in seconds: time to publish its last duels.
        uint256 seasonCloseDelay;
        /// The percent of a closed season's centre credited to each of its top three crystals, first place first.
        uint8[3] prizeShares;
    }

    /// SEASON0.md §2.1. A crystal's handles are granted to this contract and to its owner only.
    struct Crystal {
        euint8 element; // 0 = Fire, 1 = Earth, 2 = Water
        euint8 level;
        euint64 mana; // whole MANA, credited up to lastAccrual
        uint64 lastAccrual;
        /// The lobby the crystal waits in, 0 when none. A waiting crystal cannot be transferred, shattered or entered
        /// in another lobby (RULES.md §4 and §7).
        uint256 openLobby;
    }

    /// A crystal's lifetime wins and losses. Public and permanent (RULES.md §4), so kept apart from the crystal and
    /// never deleted: they outlive a shattered crystal.
    struct Record {
        uint32 wins;
        uint32 losses;
    }

    enum LobbyStatus {
        None,
        Open,
        Cancelled,
        Fought
    }

    /// SEASON0.md §2.1. Everything about a lobby is public except whether its creator could pay the stake.
    struct Lobby {
        /// The creator's crystal.
        uint256 crystal;
        uint64 stake;
        uint64 openedAt;
        LobbyStatus status;
        /// Whether the creator's MANA covered the stake when the lobby opened. Granted to this contract alone. The creator
        /// can recompute it in the opening block, from its own balance and the public stake, and learns only what it knew.
        ebool creatorPaid;
    }

    /// SEASON0.md §2.1. The outcome is a handle until someone publishes it with its proof.
    struct Duel {
        uint256 creatorCrystal;
        uint256 challengerCrystal;
        /// The season the duel was fought in, which it counts for once published (RULES.md §8).
        uint256 season;
        uint64 stake;
        bool published;
        /// Whether the creator won: publicly decryptable, the only value a duel reveals (RULES.md §3, invariant 3).
        ebool creatorWins;
    }

    /// A crystal's wins and losses counted in one season, and the latest of those wins (RULES.md §8).
    struct Score {
        uint32 wins;
        uint32 losses;
        /// The id of the latest duel, in the order duels were fought, among the wins counted so far: when the crystal
        /// reached its score. Duel ids grow by one per join, so they never outgrow 64 bits.
        uint64 lastWin;
    }

    /// SEASON0.md §2.1. Everything about a season is public but its pot, which `_pots` holds.
    struct Season {
        /// The three best crystals, best first: the most wins, then the first to reach them. 0 marks an empty place,
        /// and places fill from the first. A crystal shattered since keeps its place.
        uint256[3] top;
        bool closed;
        mapping(uint256 tokenId => Score) scores;
    }

    /// What anyone can read about a crystal: its public fields, and the handles that only its owner can decrypt.
    struct CrystalView {
        address owner;
        euint8 element;
        euint8 level;
        euint64 mana;
        uint64 lastAccrual;
        /// The MANA accrued since `lastAccrual` and not yet credited. It joins `mana` when the crystal next acts, so
        /// the balance as of now is `mana` plus this.
        uint64 pendingMana;
        /// The lobby the crystal waits in, 0 when none.
        uint256 openLobby;
        uint32 wins;
        uint32 losses;
    }

    uint256 public immutable CHARGE;
    uint64 public immutable MANA_PER_DAY;
    /// Accrual counts whole MANA, one every SECONDS_PER_MANA.
    uint64 public immutable SECONDS_PER_MANA;
    uint256 public immutable SEASON_LENGTH;
    /// A rise from level L to L + 1 costs LEVEL_COST × L² MANA (RULES.md §6).
    uint64 public immutable LEVEL_COST;
    uint8 public immutable MAX_LEVEL;
    /// An Arena stake is between MIN_STAKE and MAX_STAKE MANA, both included (RULES.md §7).
    uint64 public immutable MIN_STAKE;
    uint64 public immutable MAX_STAKE;
    /// The creator of a lobby nobody has joined can cancel it this long after opening it (RULES.md §7).
    uint256 public immutable LOBBY_TIMEOUT;
    /// A season can be closed this long after it ends (RULES.md §8).
    uint256 public immutable SEASON_CLOSE_DELAY;
    /// The percent of a closed season's centre that its first, second and third crystals receive (RULES.md §8).
    uint8 public immutable FIRST_SHARE;
    uint8 public immutable SECOND_SHARE;
    uint8 public immutable THIRD_SHARE;
    /// The deployment time, when season 1 starts.
    uint256 public immutable GENESIS;
    /// An encrypted zero that only this contract holds, drawn at construction. A value that must be unreachable starts
    /// from it rather than from an encrypted plaintext 0, which anyone can reproduce.
    euint64 internal immutable GARDEN_ZERO;

    /// Live crystals: forged and not shattered.
    uint256 public totalSupply;
    /// The id of the latest crystal forged. Ids start at 1 and are never reused.
    uint256 public lastTokenId;
    /// The ids of the latest lobby opened and the latest duel fought. Both start at 1, so 0 means none.
    uint256 public lastLobbyId;
    uint256 public lastDuelId;

    mapping(uint256 tokenId => Crystal) internal _crystals;
    /// The centre (RULES.md §8), one pot per season. Only this contract can use a pot: nobody may read its total. A
    /// closed season's pot has been paid out, and is empty.
    mapping(uint256 season => euint64) internal _pots;
    /// Every input handle `attune` has accepted. A handle sits in the calldata, so the same one twice would show
    /// everyone that two attunements made the same choice.
    mapping(bytes32 inputHandle => bool) internal _usedChoices;
    mapping(uint256 tokenId => Record) internal _records;
    mapping(uint256 lobbyId => Lobby) internal _lobbies;
    mapping(uint256 duelId => Duel) internal _duels;
    mapping(uint256 season => Season) internal _seasons;

    // Public data only (SEASON0.md §2.3, rule 2).
    event Forged(uint256 indexed tokenId, address indexed owner);
    event Shattered(uint256 indexed tokenId);
    /// The same for a rise, a refused rise and a hold (RULES.md §6).
    event Attuned(uint256 indexed tokenId);
    event LobbyOpened(uint256 indexed lobbyId, uint256 indexed tokenId, uint64 stake);
    event LobbyCancelled(uint256 indexed lobbyId);
    /// The same whether the stakes moved or not (RULES.md §7): the outcome stays a handle until it is published.
    event DuelFought(
        uint256 indexed duelId,
        uint256 lobbyId,
        uint256 indexed creatorCrystal,
        uint256 indexed challengerCrystal,
        uint256 season
    );
    event DuelPublished(uint256 indexed duelId, uint256 indexed winner, uint256 indexed loser);
    /// The season's top three, 0 for an empty place. The centre's total and the shares stay encrypted.
    event SeasonClosed(uint256 indexed season, uint256 first, uint256 second, uint256 third);

    error InvalidParams();
    error WrongCharge();
    error NotOwner();
    error ChargeNotReturned();
    error TransfersNotOpen();
    error MissingProof();
    error ChoiceReused();
    error StakeOutOfBounds();
    error CrystalWaiting();
    error LobbyNotOpen();
    error TooEarlyToCancel();
    error UnknownDuel();
    error AlreadyPublished();
    error UnknownSeason();
    error TooEarlyToClose();
    error AlreadyClosed();

    constructor(Params memory params) ERC721("Atlantysm Crystal", "CRYSTAL") {
        // Accrual credits one MANA every SECONDS_PER_MANA, so a day must divide into whole steps (SEASON0.md §2.2).
        bool wholeSteps = params.manaPerDay != 0 && 1 days % params.manaPerDay == 0;
        // A crystal is born at level 1, so the maximum must leave a level to rise to, and a rise must cost something.
        // Every value `attune` computes stays exact: it squares the level in a euint8, which holds 15² = 225 but not
        // 16², and the cost, up to levelCost × maxLevel², must fit in its euint64. A rise is paid only below the
        // maximum, so a wrap at the maximum itself would do no harm, but exact values are simpler to check.
        bool levels = params.maxLevel >= 2 && params.maxLevel <= 15 && params.levelCost != 0
            && uint256(params.levelCost) * params.maxLevel * params.maxLevel <= type(uint64).max;
        // A stake is never symbolic (RULES.md §7), and the bounds must leave a stake to choose. A duel's winner takes
        // both stakes, encrypted from the public 2 × stake, which must fit in 64 bits. A crystal waiting in a lobby that
        // nobody joins cannot be shattered before the timeout, so the timeout may not outlast a season: the charge must
        // come back within reach (RULES.md §3, invariant 1).
        bool arena = params.minStake != 0 && params.minStake <= params.maxStake
            && params.maxStake <= type(uint64).max / 2 && params.lobbyTimeout <= params.seasonLength;
        // The centre goes to the top three in full (RULES.md §8), so the shares add up to 100, and what a closed season
        // keeps back, the shares nobody takes and what rounding leaves, is never negative. No place takes more than the
        // one above it. And the close delay may not outlast a season, so that a season's prize is always within reach
        // before the next season ends.
        uint8[3] memory shares = params.prizeShares;
        bool seasons = uint256(shares[0]) + shares[1] + shares[2] == 100 && shares[0] >= shares[1]
            && shares[1] >= shares[2] && params.seasonCloseDelay <= params.seasonLength;
        if (params.charge == 0 || !wholeSteps || params.seasonLength == 0 || !levels || !arena || !seasons) {
            revert InvalidParams();
        }
        CHARGE = params.charge;
        MANA_PER_DAY = params.manaPerDay;
        SECONDS_PER_MANA = uint64(1 days / params.manaPerDay);
        SEASON_LENGTH = params.seasonLength;
        LEVEL_COST = params.levelCost;
        MAX_LEVEL = params.maxLevel;
        MIN_STAKE = params.minStake;
        MAX_STAKE = params.maxStake;
        LOBBY_TIMEOUT = params.lobbyTimeout;
        SEASON_CLOSE_DELAY = params.seasonCloseDelay;
        FIRST_SHARE = shares[0];
        SECOND_SHARE = shares[1];
        THIRD_SHARE = shares[2];
        GENESIS = block.timestamp;
        // Zero, whatever the draw. Nobody else is ever allowed on the draw, so nobody else can reproduce the handle.
        GARDEN_ZERO = FHE.allowThis(FHE.and(FHE.randEuint64(), 0));
    }

    // -- Crystals (RULES.md §4) --------------------------------------------------------------------------------

    /// Forges a crystal for the sender, who pays the charge. Its element is drawn here, and nobody chooses it.
    function forge() external payable returns (uint256 tokenId) {
        if (msg.value != CHARGE) revert WrongCharge();
        tokenId = ++lastTokenId;
        ++totalSupply;
        // `_mint`, not `_safeMint`: the forger is the caller, and a safe mint would call back into it mid-forge.
        _mint(msg.sender, tokenId);

        Crystal storage crystal = _crystals[tokenId];
        euint16 draw = FHE.randEuint16();
        // One chance in three each, from encrypted on-chain randomness. 65,536 mod 3 = 1, so Fire (0) has one more
        // draw than Earth or Water out of 65,536.
        crystal.element = _seal(FHE.asEuint8(FHE.rem(draw, 3)), msg.sender);
        // Level 1 and no MANA are public facts, but `asEuint8(1)` and `asEuint64(0)` would give every crystal forged
        // in this block the same two handles, which any contract could also make and grant to anyone. Computed from
        // the draw, which only this contract ever holds, they belong to this crystal alone. The zero runs beside the
        // element's `rem`, so it adds nothing to the depth.
        euint16 zero = FHE.and(draw, 0);
        crystal.level = _seal(FHE.asEuint8(FHE.or(zero, 1)), msg.sender);
        crystal.mana = _seal(FHE.asEuint64(zero), msg.sender);
        crystal.lastAccrual = uint64(block.timestamp);
        emit Forged(tokenId, msg.sender);
    }

    /**
     * @notice Burns the sender's crystal and returns its charge. In Season 0 the crystal's unspent MANA returns to
     *         the centre.
     */
    function shatter(uint256 tokenId) external nonReentrant {
        // `ownerOf` reverts for a crystal that was never forged or is already shattered.
        if (ownerOf(tokenId) != msg.sender) revert NotOwner();
        // RULES.md §4: a crystal waiting in an open lobby cannot be shattered. A challenger could still join, and the
        // duel would have no crystal to fight with.
        if (_crystals[tokenId].openLobby != 0) revert CrystalWaiting();

        // The MANA accrued so far goes with the rest (SEASON0.md §2.2), into the pot of the season in progress.
        uint256 season = currentSeason();
        _pots[season] = FHE.allowThis(FHE.add(_potOf(season), _accrue(_crystals[tokenId])));

        delete _crystals[tokenId];
        --totalSupply;
        _burn(tokenId);
        emit Shattered(tokenId);

        // Last, after every effect (SEASON0.md §2.3, rule 6). RULES.md §3, invariant 1: the charge always returns.
        (bool sent,) = msg.sender.call{value: CHARGE}("");
        if (!sent) revert ChargeNotReturned();
    }

    // -- The Sanctuary (RULES.md §6) ---------------------------------------------------------------------------

    /**
     * @notice Attunes the sender's crystal with an encrypted choice, rise or hold. On a rise that its MANA covers,
     *         below MAX_LEVEL, the crystal pays LEVEL_COST × level² MANA into the centre and rises one level.
     *         Otherwise nothing changes. A rise, a refused rise and a hold look the same from outside.
     * @param rise  `true` to rise, encrypted for this contract and the sender. Each input serves one attunement.
     * @param proof The input's proof, which must not be empty.
     */
    function attune(uint256 tokenId, externalEbool rise, bytes calldata proof) external {
        // `ownerOf` reverts for a crystal that was never forged or is already shattered.
        address owner = ownerOf(tokenId);
        if (owner != msg.sender) revert NotOwner();
        // Only the owner may know the choice (RULES.md §6). With an empty proof, `FHE.fromExternal` would take the
        // zero handle as an encrypted plaintext `false`, a hold that anyone reads in the calldata, or any ebool that
        // the sender and this contract may use, whose value can be public too. With a proof, the input was encrypted
        // for this contract and for the owner, who submits it.
        if (proof.length == 0) revert MissingProof();
        // The handle sits in the calldata. Used twice, it would show everyone that two attunements made the same
        // choice, so each attunement takes a fresh encryption. Both checks read only public data.
        bytes32 input = externalEbool.unwrap(rise);
        if (_usedChoices[input]) revert ChoiceReused();
        _usedChoices[input] = true;

        Crystal storage crystal = _crystals[tokenId];
        euint64 mana = _accrue(crystal);
        euint8 level = crystal.level;
        // The level never exceeds MAX_LEVEL, at most 15, so its square fits in a euint8. The constructor keeps the
        // cost within a euint64.
        euint64 cost = FHE.mul(FHE.asEuint64(FHE.mul(level, level)), LEVEL_COST);
        // Every operation runs whatever the secrets are, and `select` keeps one side (SEASON0.md §2.3, rule 1). The
        // MANA check goes last because it waits on the cost, so only one `and` follows the cost.
        ebool rises = FHE.and(FHE.and(FHE.fromExternal(rise, proof), FHE.lt(level, MAX_LEVEL)), FHE.ge(mana, cost));
        // On a hold or a refused rise, `spent` is an encrypted 0 and the level keeps its value. Every value stored below
        // still gets a new handle: an unchanged handle would tell everyone that nothing had changed.
        euint64 spent = FHE.select(rises, cost, FHE.asEuint64(0));

        crystal.level = _seal(FHE.select(rises, FHE.add(level, 1), level), owner);
        crystal.mana = _seal(FHE.sub(mana, spent), owner);
        // RULES.md §3, invariant 5: what a rise spends goes to the centre, into the pot of the season in progress.
        uint256 season = currentSeason();
        _pots[season] = FHE.allowThis(FHE.add(_potOf(season), spent));
        emit Attuned(tokenId);
    }

    // -- The Arena (RULES.md §7) -------------------------------------------------------------------------------

    /**
     * @notice Opens a lobby with the sender's crystal and a public stake, from MIN_STAKE to MAX_STAKE MANA. The crystal
     *         puts up the stake now, from its encrypted balance, if that covers it. One that cannot puts up nothing, and
     *         the stakes of its duel will stay where they are. The duel itself looks the same from outside either way.
     */
    function openLobby(uint256 tokenId, uint64 stake) external returns (uint256 lobbyId) {
        // `ownerOf` reverts for a crystal that was never forged or is already shattered.
        address owner = ownerOf(tokenId);
        if (owner != msg.sender) revert NotOwner();
        Crystal storage crystal = _crystals[tokenId];
        // A crystal waits in one open lobby at a time (RULES.md §7).
        if (crystal.openLobby != 0) revert CrystalWaiting();
        // The stake and its bounds are public, so the check reveals nothing.
        if (stake < MIN_STAKE || stake > MAX_STAKE) revert StakeOutOfBounds();

        euint64 mana = _accrue(crystal);
        // Nothing reverts on the balance (SEASON0.md §2.3, rule 1): a crystal that cannot pay pays 0, and its MANA
        // still gets a new handle.
        ebool paid = FHE.ge(mana, stake);
        crystal.mana = _seal(FHE.sub(mana, FHE.select(paid, FHE.asEuint64(stake), FHE.asEuint64(0))), owner);

        lobbyId = ++lastLobbyId;
        crystal.openLobby = lobbyId;
        _lobbies[lobbyId] = Lobby({
            crystal: tokenId,
            stake: stake,
            openedAt: uint64(block.timestamp),
            status: LobbyStatus.Open,
            creatorPaid: FHE.allowThis(paid)
        });
        emit LobbyOpened(lobbyId, tokenId, stake);
    }

    /**
     * @notice Cancels a lobby that nobody has joined, from LOBBY_TIMEOUT after it opened, and gives the creator back
     *         the stake it put up. Only the owner of the crystal waiting in it can.
     */
    function cancelLobby(uint256 lobbyId) external {
        Lobby storage lobby = _lobbies[lobbyId];
        if (lobby.status != LobbyStatus.Open) revert LobbyNotOpen();
        uint256 tokenId = lobby.crystal;
        // A waiting crystal cannot be transferred, so its owner is the one who opened the lobby.
        address owner = ownerOf(tokenId);
        if (owner != msg.sender) revert NotOwner();
        // Subtracted rather than added, so that no timeout can overflow and lock the crystal.
        if (block.timestamp - lobby.openedAt < LOBBY_TIMEOUT) revert TooEarlyToCancel();

        lobby.status = LobbyStatus.Cancelled;
        Crystal storage crystal = _crystals[tokenId];
        crystal.openLobby = 0;
        // The stake comes back only if it was paid. Either way the MANA gets a new handle, so nothing tells which.
        euint64 refund = FHE.select(lobby.creatorPaid, FHE.asEuint64(lobby.stake), FHE.asEuint64(0));
        crystal.mana = _seal(FHE.add(_accrue(crystal), refund), owner);
        emit LobbyCancelled(lobbyId);
    }

    /**
     * @notice Joins an open lobby with the sender's crystal, and the duel is fought at once. Elements and levels decide
     *         the winner. The challenger puts up the stake now if its balance covers it, and the stakes change hands,
     *         still encrypted, only if both crystals covered them. Only the outcome becomes publicly decryptable, for
     *         anyone to `publish`.
     */
    function joinLobby(uint256 lobbyId, uint256 tokenId) external returns (uint256 duelId) {
        Lobby storage lobby = _lobbies[lobbyId];
        if (lobby.status != LobbyStatus.Open) revert LobbyNotOpen();
        address challenger = ownerOf(tokenId);
        if (challenger != msg.sender) revert NotOwner();
        Crystal storage b = _crystals[tokenId];
        // A waiting crystal cannot enter another lobby. This also refuses the creator's crystal, which waits in this one.
        if (b.openLobby != 0) revert CrystalWaiting();

        // The lobby closes, and the creator's crystal is free again, before the duel calls into the FHE executor and
        // the ACL (SEASON0.md §2.3, rule 6).
        uint256 creatorCrystal = lobby.crystal;
        Crystal storage a = _crystals[creatorCrystal];
        lobby.status = LobbyStatus.Fought;
        a.openLobby = 0;

        duelId = ++lastDuelId;
        uint256 season = currentSeason();
        Duel storage duel = _duels[duelId];
        duel.creatorCrystal = creatorCrystal;
        duel.challengerCrystal = tokenId;
        duel.season = season;
        duel.stake = lobby.stake;
        duel.creatorWins = _fight(a, ownerOf(creatorCrystal), b, challenger, lobby.stake, lobby.creatorPaid);
        emit DuelFought(duelId, lobbyId, creatorCrystal, tokenId, season);
    }

    /**
     * @notice Publishes a duel's outcome with the proof of its public decryption. Anyone can, once per duel, so no
     *         player can stall a result by staying away (RULES.md §7). The result counts in both crystals' lifetime
     *         records, also when one of them has been shattered since, and in the ranking of the season the duel was
     *         fought in, unless that season is closed (RULES.md §8).
     * @param creatorWon The decrypted outcome: whether the crystal that opened the lobby won.
     * @param proof      The KMS signatures over the stored outcome handle and this value.
     */
    function publish(uint256 duelId, bool creatorWon, bytes calldata proof) external {
        if (duelId == 0 || duelId > lastDuelId) revert UnknownDuel();
        Duel storage duel = _duels[duelId];
        if (duel.published) revert AlreadyPublished();
        // Marked before the proof is checked, so the call ends with effects done. A proof that fails reverts it all.
        duel.published = true;

        // The stored handle, never one the caller names: a proof then fits only the duel it was made for, and only
        // the value the KMS decrypted (RULES.md §3, invariant 6).
        bytes32[] memory handles = new bytes32[](1);
        handles[0] = FHE.toBytes32(duel.creatorWins);
        FHE.checkSignatures(handles, abi.encode(creatorWon), proof);

        (uint256 winner, uint256 loser) =
            creatorWon ? (duel.creatorCrystal, duel.challengerCrystal) : (duel.challengerCrystal, duel.creatorCrystal);
        _records[winner].wins++;
        _records[loser].losses++;
        // A duel counts for the season it was fought in until that season is closed, and afterwards only in the records.
        Season storage season = _seasons[duel.season];
        if (!season.closed) {
            Score storage score = season.scores[winner];
            score.wins++;
            // The latest win by duel id, not by publication: ids grow as duels are fought, so this is when the crystal
            // reached its score, whatever order the results come in.
            if (duelId > score.lastWin) score.lastWin = uint64(duelId);
            season.scores[loser].losses++;
            _rank(season, winner);
        }
        emit DuelPublished(duelId, winner, loser);
    }

    // -- Seasons (RULES.md §8) ---------------------------------------------------------------------------------

    /**
     * @notice Closes a season from SEASON_CLOSE_DELAY after it ends, and credits its centre to its top three crystals
     *         in encrypted shares. Anyone can, once per season. A share with no crystal to take it, for an empty place
     *         or a crystal shattered since, stays in the centre for the season in progress. The centre's total is never
     *         published: each winner can read only its own balance.
     */
    function closeSeason(uint256 season) external {
        if (season == 0) revert UnknownSeason();
        uint256 current = currentSeason();
        // The season in progress, and any later one, has not ended. An earlier one ended in the past, so subtracting its
        // end from now cannot underflow, and no season number can overflow.
        if (season >= current || block.timestamp - (GENESIS + season * SEASON_LENGTH) < SEASON_CLOSE_DELAY) {
            revert TooEarlyToClose();
        }
        Season storage closing = _seasons[season];
        if (closing.closed) revert AlreadyClosed();
        // Closed, and its pot emptied, before any FHE call (SEASON0.md §2.3, rule 6). Nothing adds to a past season's pot,
        // so the pot read here is all there is, and below it goes to the winners and to the season in progress.
        closing.closed = true;
        euint64 pot = _potOf(season);
        _pots[season] = euint64.wrap(0);

        euint64 rest = pot;
        for (uint256 place; place < 3; ++place) {
            uint256 tokenId = closing.top[place];
            // An empty place, or a crystal shattered since, has no owner, and its share stays in the rest. Both are
            // public, so the branch reveals nothing (SEASON0.md §2.3, rule 1).
            address owner = _ownerOf(tokenId);
            if (owner == address(0)) continue;
            // pot × share fits in 64 bits while the pot holds less than 2^64 / 100 MANA. A pot holds at most the MANA
            // ever accrued: at one MANA a second, the fastest rate the constructor allows, a million crystals would take
            // 5,800 years to accrue that much. The shares are floors of fractions that add up to one, so together they
            // never exceed the pot, and the rest never wraps.
            euint64 share = FHE.div(FHE.mul(pot, _shareOf(place)), 100);
            Crystal storage crystal = _crystals[tokenId];
            crystal.mana = _seal(FHE.add(_accrue(crystal), share), owner);
            rest = FHE.sub(rest, share);
        }
        // To the season in progress, which cannot be closed yet, rather than to `season + 1`, which a late close may find
        // already closed.
        _pots[current] = FHE.allowThis(FHE.add(_potOf(current), rest));
        emit SeasonClosed(season, closing.top[0], closing.top[1], closing.top[2]);
    }

    // -- Views -------------------------------------------------------------------------------------------------

    /// A live crystal's public fields and its handles. Reverts for a crystal that does not exist.
    function crystalOf(uint256 tokenId) external view returns (CrystalView memory) {
        address owner = _requireOwned(tokenId);
        Crystal storage crystal = _crystals[tokenId];
        return CrystalView({
            owner: owner,
            element: crystal.element,
            level: crystal.level,
            mana: crystal.mana,
            lastAccrual: crystal.lastAccrual,
            pendingMana: _pendingMana(crystal),
            openLobby: crystal.openLobby,
            wins: _records[tokenId].wins,
            losses: _records[tokenId].losses
        });
    }

    /**
     * @notice The crystals `owner` holds among the ids from `cursor` to `cursor + count - 1`, and the id the next
     *         page starts from, 0 when no id is left. A cursor of 0 starts from the first id. A page scans `count`
     *         ids however many it finds, so its cost does not grow with the number of crystals.
     */
    function crystalsOf(address owner, uint256 cursor, uint256 count)
        external
        view
        returns (uint256[] memory tokenIds, uint256 next)
    {
        // Shattered crystals belong to the zero address, which owns nothing, as for `balanceOf`.
        if (owner == address(0)) revert ERC721InvalidOwner(address(0));
        uint256 end;
        (cursor, end, next) = _page(cursor, count, lastTokenId);
        tokenIds = new uint256[](end + 1 - cursor);
        uint256 found;
        for (uint256 id = cursor; id <= end; ++id) {
            if (_ownerOf(id) == owner) tokenIds[found++] = id;
        }
        _trim(tokenIds, found);
    }

    /// A crystal's lifetime wins and losses, public and permanent (RULES.md §4). It answers for a shattered crystal
    /// too, and gives 0 and 0 for an id never forged.
    function recordOf(uint256 tokenId) external view returns (uint32 wins, uint32 losses) {
        Record storage record = _records[tokenId];
        return (record.wins, record.losses);
    }

    /// A lobby, all zero for an id never used.
    function lobbyOf(uint256 lobbyId) external view returns (Lobby memory) {
        return _lobbies[lobbyId];
    }

    /// A duel, all zero for an id never used.
    function duelOf(uint256 duelId) external view returns (Duel memory) {
        return _duels[duelId];
    }

    /// The open lobbies among the ids from `cursor` to `cursor + count - 1`, paged like `crystalsOf`.
    function openLobbies(uint256 cursor, uint256 count)
        external
        view
        returns (uint256[] memory lobbyIds, uint256 next)
    {
        uint256 end;
        (cursor, end, next) = _page(cursor, count, lastLobbyId);
        lobbyIds = new uint256[](end + 1 - cursor);
        uint256 found;
        for (uint256 id = cursor; id <= end; ++id) {
            if (_lobbies[id].status == LobbyStatus.Open) lobbyIds[found++] = id;
        }
        _trim(lobbyIds, found);
    }

    /// The duels fought and not yet published among the ids from `cursor` to `cursor + count - 1`, paged like
    /// `crystalsOf`. Anyone can publish them.
    function pendingDuels(uint256 cursor, uint256 count)
        external
        view
        returns (uint256[] memory duelIds, uint256 next)
    {
        uint256 end;
        (cursor, end, next) = _page(cursor, count, lastDuelId);
        duelIds = new uint256[](end + 1 - cursor);
        uint256 found;
        for (uint256 id = cursor; id <= end; ++id) {
            if (!_duels[id].published) duelIds[found++] = id;
        }
        _trim(duelIds, found);
    }

    /// Seasons follow one another from the deployment, the first numbered 1.
    function currentSeason() public view returns (uint256) {
        return (block.timestamp - GENESIS) / SEASON_LENGTH + 1;
    }

    /// The handle of a season's pot, 0 until a crystal attunes or is shattered in that season, and 0 again once the
    /// season is closed and its pot paid out. Nobody can decrypt it.
    function potOf(uint256 season) external view returns (euint64) {
        return _pots[season];
    }

    /**
     * @notice A season's ranking (RULES.md §8): its three best crystals, best first, their wins in the season, and
     *         whether the season is closed. An empty place is 0. A crystal shattered since keeps its place.
     */
    function rankingOf(uint256 season)
        external
        view
        returns (uint256[3] memory crystals, uint32[3] memory wins, bool closed)
    {
        Season storage s = _seasons[season];
        crystals = s.top;
        for (uint256 place; place < 3; ++place) {
            wins[place] = s.scores[crystals[place]].wins;
        }
        closed = s.closed;
    }

    /// A crystal's wins and losses counted in a season, and the id of the latest duel among those wins, which breaks
    /// ties in the ranking. All zero for a crystal that has nothing counted there.
    function scoreOf(uint256 season, uint256 tokenId) external view returns (Score memory) {
        return _seasons[season].scores[tokenId];
    }

    // -- Internal ----------------------------------------------------------------------------------------------

    /**
     * @dev SEASON0.md §2.2, Join: the duel, on encrypted data. A is the creator's crystal, which put up the stake when
     *      the lobby opened if `paidA`, and B the challenger's, which puts it up here if it covers it. Elements and
     *      levels decide the winner, and the stake changes hands only if both covered it (RULES.md §7). Every line runs
     *      on every join and `select` picks the results (SEASON0.md §2.3, rule 1), so a duel whose stakes moved and one
     *      whose stakes stayed run the same operations and look the same from outside. Returns whether A won, granted
     *      to this contract and publicly decryptable.
     */
    function _fight(Crystal storage a, address ownerA, Crystal storage b, address ownerB, uint64 stake, ebool paidA)
        internal
        returns (ebool aWins)
    {
        euint64 manaA = _accrue(a);
        euint64 manaB = _accrue(b);
        // The stake is public, so encrypting it reveals nothing (SEASON0.md §2.3, rule 3).
        euint64 staked = FHE.asEuint64(stake);
        euint64 zero = FHE.asEuint64(0);

        // MANA never wins a duel: the outcome reads no payment, so it cannot reveal one.
        aWins = _outcome(a, b);

        // The stake changes hands only if both crystals covered it.
        ebool both = FHE.and(paidA, FHE.ge(manaB, stake));
        euint64 moved = FHE.select(both, staked, zero);
        // A put up its stake at opening if it covered it. When both covered, the winner takes both stakes; otherwise A
        // takes its own back. The constructor keeps 2 × stake within 64 bits, and no sum here can wrap: each is at most
        // the MANA in existence, which only accrual creates.
        euint64 toA =
            FHE.select(both, FHE.select(aWins, FHE.asEuint64(2 * stake), zero), FHE.select(paidA, staked, zero));
        a.mana = _seal(FHE.add(manaA, toA), ownerA);
        // B puts up its stake and settles it in this same call, so its balance moves only by the stake that changes
        // hands. `moved` is nonzero only if B covered it, so the subtraction cannot wrap.
        b.mana = _seal(FHE.select(aWins, FHE.sub(manaB, moved), FHE.add(manaB, moved)), ownerB);

        FHE.allowThis(aWins);
        // The only value a duel reveals (SEASON0.md §2.3, rule 4).
        FHE.makePubliclyDecryptable(aWins);
    }

    /// Whether A beats B, on elements and levels alone: the triangle, then the higher level in a mirror, then a coin.
    function _outcome(Crystal storage a, Crystal storage b) internal returns (ebool) {
        ebool same = FHE.eq(a.element, b.element);
        // Fire > Earth > Water > Fire: with 0 = Fire, 1 = Earth and 2 = Water, each element beats the next one.
        ebool aBeatsB = FHE.eq(b.element, FHE.rem(FHE.add(a.element, 1), 3));
        // Drawn on every join, not only in a mirror of equal levels, so that nothing depends on the inputs.
        ebool coin = FHE.randEbool();
        ebool mirror = FHE.select(FHE.eq(a.level, b.level), coin, FHE.gt(a.level, b.level));
        return FHE.select(same, mirror, aBeatsB);
    }

    /**
     * @dev SEASON0.md §2.2, Publish: places `winner`, which has just won, among the season's top three. A crystal's key,
     *      its wins and then its latest counted win, changes only when it wins, and then it improves. So the top three
     *      stay exact if the winner moves up past every crystal it is now ahead of, coming in through the first empty
     *      place or in place of the third, and no other crystal needs to be looked at.
     */
    function _rank(Season storage season, uint256 winner) internal {
        uint256[3] memory top = season.top;
        // The winner's place if it is ranked, else the first empty place, else 3: outside a full top three.
        uint256 place;
        while (place < 3 && top[place] != winner && top[place] != 0) ++place;
        if (place == 3) {
            if (!_ahead(season, winner, top[2])) return;
            place = 2;
        }
        while (place > 0 && _ahead(season, winner, top[place - 1])) {
            top[place] = top[place - 1];
            --place;
        }
        top[place] = winner;
        season.top = top;
    }

    /// Whether `a` ranks ahead of `b` in the season: more wins, or as many reached first (RULES.md §8). Two ranked
    /// crystals never tie: each duel has one winner, so no two crystals share their latest counted win.
    function _ahead(Season storage season, uint256 a, uint256 b) internal view returns (bool) {
        Score storage x = season.scores[a];
        Score storage y = season.scores[b];
        return x.wins > y.wins || (x.wins == y.wins && x.lastWin < y.lastWin);
    }

    /// The percent of the centre that the crystal in `place`, 0 for the first, receives.
    function _shareOf(uint256 place) internal view returns (uint64) {
        return place == 0 ? FIRST_SHARE : place == 1 ? SECOND_SHARE : THIRD_SHARE;
    }

    /**
     * @dev The ids a page scans, from `first` to `end`, out of ids 1 to `last`, and the cursor of the next page, 0 when
     *      no id is left. A cursor of 0 starts from id 1. With `count` at 0, or past the last id, `end` falls just
     *      before `first`, so the page is empty.
     */
    function _page(uint256 cursor, uint256 count, uint256 last)
        internal
        pure
        returns (uint256 first, uint256 end, uint256 next)
    {
        first = cursor == 0 ? 1 : cursor;
        if (first > last) return (first, first - 1, 0);
        end = count > last - first ? last : first + count - 1;
        next = end < last ? end + 1 : 0;
    }

    /// Shortens `ids` to its first `length` entries, the ones a page found.
    function _trim(uint256[] memory ids, uint256 length) internal pure {
        assembly ("memory-safe") {
            mstore(ids, length)
        }
    }

    /**
     * @dev SEASON0.md §2.2, Accrual: plaintext, and first in every call that touches a crystal's MANA. Credits the
     *      whole MANA accrued since `lastAccrual` to `crystal.mana`, and returns the new balance. `lastAccrual` moves
     *      by whole MANA, not to now, so the remainder waits for the next call.
     *
     *      The credit is stored, and kept for this contract, at once. So a call that reads `crystal.mana` afterwards,
     *      or accrues twice, still finds it. And a call that ends without granting the owner its balance cannot lock
     *      the crystal: the next action, or a shatter, still computes on it. Granting the owner the balance the call
     *      ends with is the caller's part.
     */
    function _accrue(Crystal storage crystal) internal returns (euint64 mana) {
        uint64 units = _pendingMana(crystal);
        crystal.lastAccrual += units * SECONDS_PER_MANA;
        mana = FHE.allowThis(FHE.add(crystal.mana, units));
        crystal.mana = mana;
    }

    function _pendingMana(Crystal storage crystal) internal view returns (uint64) {
        return (uint64(block.timestamp) - crystal.lastAccrual) / SECONDS_PER_MANA;
    }

    /**
     * @dev A season's pot, from GARDEN_ZERO while it is empty. For an empty handle `FHE.add` would use an encrypted
     *      plaintext 0, and a shatterer holding the crystal's MANA handle could then recompute the season's first pot
     *      in the same block.
     */
    function _potOf(uint256 season) internal view returns (euint64 pot) {
        pot = _pots[season];
        if (!FHE.isInitialized(pot)) pot = GARDEN_ZERO;
    }

    /// A stored handle is granted to this contract, to use it later, and to the crystal's owner, to read it, and to
    /// nobody else (SEASON0.md §2.3, rule 5).
    function _seal(euint8 value, address owner) internal returns (euint8) {
        FHE.allowThis(value);
        FHE.allow(value, owner);
        return value;
    }

    function _seal(euint64 value, address owner) internal returns (euint64) {
        FHE.allowThis(value);
        FHE.allow(value, owner);
        return value;
    }

    /**
     * @dev Crystals only appear and disappear for now: forging mints, shattering burns. A transfer must seal the level
     *      and MANA again for the new owner, so that the previous owner loses sight of them (RULES.md §4). Until it
     *      does (T07), a transfer would leave them readable by the previous owner and unreadable by the new one, so
     *      it is refused.
     */
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (to != address(0) && _ownerOf(tokenId) != address(0)) {
            // RULES.md §4: a crystal waiting in an open lobby cannot be transferred. Checked first, so that the lock
            // already holds when transfers open.
            if (_crystals[tokenId].openLobby != 0) revert CrystalWaiting();
            revert TransfersNotOpen();
        }
        return super._update(to, tokenId, auth);
    }
}
