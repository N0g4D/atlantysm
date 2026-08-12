import { useState } from "react";
import { formatEther, parseEther, type Hex } from "viem";
import type { Entity } from "@latticexyz/recs";

import { Panel } from "./Panel";
import { useAction } from "../hooks/useAction";
import { useCrystal, useMana, type OwnedCrystal } from "../hooks/useCrystals";
import {
  formatCountdown,
  isEmptyEntity,
  isLive,
  revealDeadline,
  useCommitment,
  useLobby,
  useLobbyIds,
  useNow,
  useResolvedMatches,
  type MatchResult,
} from "../hooks/useArena";
import {
  ELEMENT,
  LOBBY_STATUS,
  PLAYABLE_ELEMENTS,
  deriveCommitment,
  deriveLobbyId,
  elementName,
  forgetSecret,
  randomSalt,
  recallSecret,
  rememberSecret,
  type ElementName,
} from "../lib/commit";
import { truncateAddress } from "../lib/format";
import { useMud } from "../mud/MudProvider";
import { useSelectedCrystal } from "../mud/CrystalSelection";

const ACCENT: Record<ElementName, string> = {
  Fire: "bg-solarpunk-peach",
  Water: "bg-solarpunk-lavender",
  Earth: "bg-solarpunk-mint",
};

/** Three buttons and a way out. The move is chosen at the moment of committing, never stored first. */
function ElementPicker({
  onPick,
  onCancel,
  disabled,
}: {
  onPick: (element: ElementName) => void;
  onCancel: () => void;
  disabled?: boolean;
}) {
  return (
    <div className="flex flex-wrap items-center gap-2">
      {PLAYABLE_ELEMENTS.map((element) => (
        <button
          key={element}
          type="button"
          className={`btn ${ACCENT[element]}`}
          disabled={disabled}
          onClick={() => onPick(element)}
        >
          {element}
        </button>
      ))}
      <button type="button" className="btn" disabled={disabled} onClick={onCancel}>
        Annulla
      </button>
    </div>
  );
}

function CreateLobby({ crystal }: { crystal: OwnedCrystal }) {
  const { systemCalls } = useMud();
  const { pending, run } = useAction();
  const [wager, setWager] = useState("10");
  const [picking, setPicking] = useState(false);
  const mana = useMana(crystal.entity);

  const busy = pending === "create";
  let parsed: bigint | undefined;
  try {
    parsed = parseEther(wager);
  } catch {
    parsed = undefined;
  }
  const valid = parsed !== undefined && parsed > 0n && mana !== undefined && mana >= parsed;

  function commit(element: ElementName) {
    if (!parsed) return;

    void run("create", "Sfida creata. La tua mossa resta segreta.", async () => {
      // Both salts are independent: `lobbySalt` only makes the lobby id unique per challenger,
      // `salt` is what hides the move.
      const lobbySalt = randomSalt();
      const salt = randomSalt();
      const move = ELEMENT[element];

      // The id is derivable before the lobby exists — that is what lets the commitment bind to it.
      const lobbyId = deriveLobbyId(crystal.entity, lobbySalt);
      const commitment = deriveCommitment(lobbyId, crystal.entity, move, salt);

      // WRITTEN BEFORE THE TRANSACTION. If the tx lands and this did not, the move can never be
      // revealed: the salt is random and unrecoverable, and the wager is already escrowed.
      rememberSecret(lobbyId, crystal.entity, { move, salt });

      await systemCalls.createLobby(crystal.entity, lobbySalt, parsed, commitment);
      setPicking(false);
    });
  }

  return (
    <div className="panel-flat mb-6 px-4 py-4">
      <div className="mb-3 flex flex-wrap items-center gap-3">
        <label className="muted" htmlFor="wager">
          Posta
        </label>
        <input
          id="wager"
          className="chip w-28 bg-white"
          value={wager}
          inputMode="decimal"
          onChange={(event) => setWager(event.target.value)}
        />
        <span className="muted">MANA · disponibili {mana === undefined ? "…" : formatEther(mana)}</span>
      </div>

      {picking ? (
        <ElementPicker onPick={commit} onCancel={() => setPicking(false)} disabled={busy} />
      ) : (
        <button type="button" className="btn btn-primary" disabled={busy || !valid} onClick={() => setPicking(true)}>
          {busy ? "Creazione in corso…" : "Crea sfida"}
        </button>
      )}

      {!valid && !busy ? (
        <p className="muted mt-3">
          {parsed === undefined || parsed === 0n
            ? "Inserisci una posta valida."
            : "Mana insufficiente per questa posta."}
        </p>
      ) : null}
    </div>
  );
}

function LobbyRow({ lobbyEntity, crystal }: { lobbyEntity: Entity; crystal: OwnedCrystal }) {
  const { systemCalls } = useMud();
  const { pending, run } = useAction();
  const [picking, setPicking] = useState(false);
  const now = useNow();

  const lobby = useLobby(lobbyEntity);
  const mine = useCommitment(lobbyEntity, crystal.entity);
  const challengerSide = useCommitment(lobbyEntity, lobby?.challenger);
  const opponentSide = useCommitment(lobbyEntity, lobby?.opponent);

  if (!lobby || !isLive(lobby)) return null;

  const isChallenger = lobby.challenger === crystal.entity;
  const isOpponent = lobby.opponent === crystal.entity;
  const participant = isChallenger || isOpponent;
  const open = lobby.status === LOBBY_STATUS.Open;

  const deadline = revealDeadline(lobby);
  const expired = lobby.status === LOBBY_STATUS.Matched && now > deadline;
  const bothRevealed = Boolean(challengerSide?.revealed && opponentSide?.revealed);
  const secret = participant ? recallSecret(lobby.id, crystal.entity) : undefined;

  const busy = pending !== null;

  function join(element: ElementName) {
    void run("join", "Sfida accettata. La tua mossa resta segreta.", async () => {
      const salt = randomSalt();
      const move = ELEMENT[element];
      const commitment = deriveCommitment(lobby!.id, crystal.entity, move, salt);

      rememberSecret(lobby!.id, crystal.entity, { move, salt });
      await systemCalls.joinLobby(crystal.entity, lobby!.id, commitment);
      setPicking(false);
    });
  }

  function reveal() {
    if (!secret) return;
    void run("reveal", `Mossa svelata: ${elementName(secret.move)}.`, async () => {
      await systemCalls.revealMove(crystal.entity, lobby!.id, secret.move, secret.salt);
      // Only after it landed: a failed reveal must stay retryable.
      forgetSecret(lobby!.id, crystal.entity);
    });
  }

  return (
    <div className="panel-flat mb-3 px-4 py-3">
      <div className="mb-2 flex flex-wrap items-baseline gap-x-4 gap-y-1">
        <span className="font-mono text-xs">{truncateAddress(lobby.id, 8, 6)}</span>
        <span className="chip border-0 px-0 py-0">{open ? "Aperta" : "In corso"}</span>
        <span className="muted">posta {formatEther(lobby.wager)} MANA</span>
        {participant ? <span className="chip bg-solarpunk-mint">tu</span> : null}
      </div>

      <div className="muted mb-3">
        sfidante {truncateAddress(lobby.challenger, 6, 4)}
        {isEmptyEntity(lobby.opponent) ? "" : ` · avversario ${truncateAddress(lobby.opponent, 6, 4)}`}
        {lobby.status === LOBBY_STATUS.Matched
          ? ` · reveal ${expired ? "scaduto" : `fra ${formatCountdown(deadline - now)}`}`
          : ""}
      </div>

      {/* ---- Open ---- */}
      {open && isChallenger ? (
        <button
          type="button"
          className="btn"
          disabled={busy}
          onClick={() => run("cancel", "Sfida annullata, posta restituita.", () => systemCalls.cancelLobby(crystal.entity, lobby.id))}
        >
          {pending === "cancel" ? "Annullamento…" : "Annulla — in attesa di sfidanti"}
        </button>
      ) : null}

      {open && !isChallenger ? (
        picking ? (
          <ElementPicker onPick={join} onCancel={() => setPicking(false)} disabled={busy} />
        ) : (
          <button type="button" className="btn btn-primary" disabled={busy} onClick={() => setPicking(true)}>
            {pending === "join" ? "Ingresso in corso…" : "Sfida"}
          </button>
        )
      ) : null}

      {/* ---- Matched ---- */}
      {!open && participant && !mine?.revealed && !expired ? (
        secret ? (
          <button type="button" className="btn btn-primary" disabled={busy} onClick={reveal}>
            {pending === "reveal" ? "Svelamento…" : "Svela Mossa"}
          </button>
        ) : (
          <p className="muted">
            Segreto non trovato in questo browser: la mossa non è più svelabile. Alla scadenza
            potrai solo attendere l&apos;esito del timeout.
          </p>
        )
      ) : null}

      {!open && participant && mine?.revealed && !bothRevealed ? (
        <p className="muted">Mossa svelata. In attesa dell&apos;avversario.</p>
      ) : null}

      {!open && bothRevealed ? (
        <button
          type="button"
          className="btn btn-primary"
          disabled={busy}
          onClick={() => run("resolve", "Match risolto.", () => systemCalls.resolveMatch(lobby.id))}
        >
          {pending === "resolve" ? "Risoluzione…" : "Risolvi match"}
        </button>
      ) : null}

      {!open && participant && expired && !bothRevealed ? (
        <button
          type="button"
          className="btn"
          disabled={busy}
          onClick={() => run("timeout", "Timeout reclamato.", () => systemCalls.claimTimeout(crystal.entity, lobby.id))}
        >
          {pending === "timeout" ? "Reclamo…" : "Reclama (Timeout)"}
        </button>
      ) : null}
    </div>
  );
}

const OUTCOME = {
  win: { label: "Vittoria", accent: "bg-solarpunk-mint", sign: "+" },
  loss: { label: "Sconfitta", accent: "bg-solarpunk-peach", sign: "−" },
  draw: { label: "Pareggio", accent: "bg-white", sign: "" },
} as const;

function HistoryRow({ result }: { result: MatchResult }) {
  // The opponent's CURRENT level — the chain does not record the level they fought at.
  const opponent = useCrystal(result.opponent);
  const { label, accent, sign } = OUTCOME[result.outcome];

  return (
    <div className="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1 border-b border-dashed border-ink/25 py-2 last:border-b-0">
      <span className="text-sm">
        <span className={`chip mr-2 ${accent}`}>{label}</span>
        contro {truncateAddress(result.opponent, 6, 4)}
        {opponent ? ` (Livello ${opponent.level})` : ""}
      </span>
      <span className="font-mono text-sm">
        {sign}
        {formatEther(result.delta)} MANA
      </span>
    </div>
  );
}

function MatchHistory({ crystal }: { crystal: OwnedCrystal }) {
  const matches = useResolvedMatches(crystal.entity);

  return (
    <div className="panel-flat mt-6 px-4 py-4">
      <h3 className="heading mb-1 text-base">Ultime battaglie</h3>
      <p className="muted mb-3">
        Guadagno netto, non il piatto: chi vince aveva a sua volta messo la posta. Il livello è
        quello ATTUALE dell&apos;avversario — la chain non registra quello al momento dello scontro.
      </p>

      {matches.length === 0 ? (
        <p className="muted">Nessuna battaglia conclusa.</p>
      ) : (
        matches.map((result) => <HistoryRow key={result.lobby.id} result={result} />)
      )}
    </div>
  );
}

export function ArenaPanel() {
  const crystal = useSelectedCrystal();
  const lobbyIds = useLobbyIds();

  if (!crystal) {
    return (
      <Panel title="L'Arena" hint="commit-reveal, elementi, scommesse" accent="lavender">
        <p className="muted">Serve un cristallo per combattere. Passa dalla Forgia.</p>
      </Panel>
    );
  }

  return (
    <Panel title="L'Arena" hint="commit-reveal, elementi, scommesse" accent="lavender">
      <p className="muted mb-4">
        Le mosse restano nascoste finché entrambi non rivelano. Acqua batte Fuoco, Fuoco batte
        Terra, Terra batte Acqua; a parità di elemento decide il livello.
      </p>

      <CreateLobby crystal={crystal} />

      {lobbyIds.length === 0 ? (
        <p className="muted">Nessuna lobby.</p>
      ) : (
        lobbyIds.map((id) => <LobbyRow key={id} lobbyEntity={id} crystal={crystal} />)
      )}

      <MatchHistory crystal={crystal} />
    </Panel>
  );
}
