/**
 * generatePromoLinks.ts — onboarding for a live demo.
 *
 * Generates N throwaway burner wallets, funds each from a master account, and writes one URL per
 * wallet. Hand a link to a visitor and they land on Atlantysm already holding Sepolia ETH: no
 * wallet install, no faucet queue, no connect flow. The client picks the key up from `?burner=`
 * (see packages/client/src/mud/getNetworkConfig.ts).
 *
 *   pnpm promo:links              # generate + fund
 *   pnpm promo:links --dry-run    # generate + write links, spend nothing
 *   pnpm promo:links --force      # overwrite an existing promo_links.txt
 *
 * ---------------------------------------------------------------------------------------------
 * THESE URLS ARE BEARER SECRETS
 * ---------------------------------------------------------------------------------------------
 * A private key in a query string is a key anyone who sees it owns. That is acceptable here, and
 * only here, because each wallet is disposable, testnet-only, and holds ~$0. It is NOT a pattern to
 * carry anywhere near mainnet. `promo_links.txt` is gitignored; keep it that way, and do not paste
 * these links into a shared channel you would not paste a password into.
 */
import { existsSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

import dotenv from "dotenv";
import { createPublicClient, createWalletClient, formatEther, http, parseEther, type Hex } from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";

// -------------------------------------------------------------------------------------------
// Configuration — the things you are meant to edit
// -------------------------------------------------------------------------------------------

/** Your Vercel deployment, no trailing slash. CHANGE ME. */
const VERCEL_DOMAIN = "https://atlantysm.vercel.app";

const WALLET_COUNT = 50;

/** Per wallet. Covers the 0.01 ETH mint plus gas for the whole loop with room to spare. */
const AMOUNT_PER_WALLET = parseEther("0.02");

const OUTPUT_FILE = "promo_links.txt";

/**
 * Same default as the sepolia foundry profile and the client. Public and rate-limited: fine for 50
 * transfers, not for anything heavier. Override with RPC_URL in .env.
 */
const FALLBACK_RPC_URL = "https://ethereum-sepolia-rpc.publicnode.com";

/** A plain ETH transfer is exactly this. Used for the pre-flight cost estimate. */
const TRANSFER_GAS_LIMIT = 21_000n;

/** Politeness spacing between broadcasts, so a shared endpoint does not rate-limit us. */
const SEND_DELAY_MS = 250;
const SEND_ATTEMPTS = 3;

// -------------------------------------------------------------------------------------------

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const outputPath = join(repoRoot, OUTPUT_FILE);

dotenv.config({ path: join(repoRoot, ".env"), quiet: true });

const args = new Set(process.argv.slice(2));
const dryRun = args.has("--dry-run");
const force = args.has("--force");

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

function fail(message: string): never {
  console.error(`\n✗ ${message}\n`);
  process.exit(1);
}

function normalisePrivateKey(raw: string): Hex {
  const prefixed = (raw.startsWith("0x") ? raw : `0x${raw}`) as Hex;
  if (!/^0x[0-9a-fA-F]{64}$/.test(prefixed)) {
    fail("MASTER_PRIVATE_KEY is not a 32-byte hex private key.");
  }
  return prefixed;
}

async function main() {
  // ---------------------------------------------------------------------------------------
  // 1. Refuse to clobber keys that may already hold funds
  // ---------------------------------------------------------------------------------------
  if (existsSync(outputPath) && !force) {
    fail(
      `${OUTPUT_FILE} already exists.\n` +
        `  Those keys may already be funded, and overwriting them strands the ETH — nothing else\n` +
        `  records them. Move the file aside, or pass --force if you are sure.`,
    );
  }

  const masterPrivateKey = normalisePrivateKey(
    process.env.MASTER_PRIVATE_KEY ??
      fail(
        "MASTER_PRIVATE_KEY is not set.\n" +
          `  Create ${relative(process.cwd(), join(repoRoot, ".env"))} from .env.example and put your\n` +
          "  funded Sepolia key in it. The file is gitignored.",
      ),
  );

  const master = privateKeyToAccount(masterPrivateKey);
  const rpcUrl = process.env.RPC_URL ?? FALLBACK_RPC_URL;

  const publicClient = createPublicClient({ chain: sepolia, transport: http(rpcUrl) });
  const walletClient = createWalletClient({ account: master, chain: sepolia, transport: http(rpcUrl) });

  console.log(`\nAtlantysm promo links`);
  console.log(`  rpc      ${rpcUrl}`);
  console.log(`  master   ${master.address}`);

  // ---------------------------------------------------------------------------------------
  // 2. Confirm the chain BEFORE anything is signed
  // ---------------------------------------------------------------------------------------
  // `chain: sepolia` sets what viem *claims*, not what the endpoint *is*. If RPC_URL happens to
  // point at mainnet, every guard below still passes and the script sends 1 ETH of real money.
  // Ask the node.
  const chainId = await publicClient.getChainId();
  if (chainId !== sepolia.id) {
    fail(
      `RPC_URL is not Sepolia: the endpoint reports chain ${chainId}, expected ${sepolia.id}.\n` +
        `  Refusing to send ${formatEther(AMOUNT_PER_WALLET * BigInt(WALLET_COUNT))} ETH on the wrong chain.`,
    );
  }
  console.log(`  chain    ${chainId} (sepolia) ✓`);

  // ---------------------------------------------------------------------------------------
  // 3. Check the balance up front, not on transfer 38
  // ---------------------------------------------------------------------------------------
  const totalValue = AMOUNT_PER_WALLET * BigInt(WALLET_COUNT);
  const gasPrice = await publicClient.getGasPrice();
  const estimatedGas = gasPrice * TRANSFER_GAS_LIMIT * BigInt(WALLET_COUNT);
  const required = totalValue + estimatedGas;
  const balance = await publicClient.getBalance({ address: master.address });

  console.log(`  balance  ${formatEther(balance)} ETH`);
  console.log(
    `  need     ${formatEther(required)} ETH ` +
      `(${WALLET_COUNT} × ${formatEther(AMOUNT_PER_WALLET)} + ~${formatEther(estimatedGas)} gas)\n`,
  );

  if (!dryRun && balance < required) {
    fail(
      `Master wallet is short by ${formatEther(required - balance)} ETH.\n` +
        "  Stopping before the first transfer: a run that dies halfway leaves funded and unfunded\n" +
        "  links mixed in one file, with no way to tell them apart.",
    );
  }

  // ---------------------------------------------------------------------------------------
  // 4. Generate the keys, and WRITE THEM BEFORE SPENDING ANYTHING
  // ---------------------------------------------------------------------------------------
  // Same rule the client follows for commit-reveal salts (see lib/commit.ts): persist the secret
  // before the transaction that gives it value. A key written but not funded is a wasted line; a
  // key funded but never written is ETH nobody can reach, because nothing else knows it exists.
  //
  // generatePrivateKey() is viem's CSPRNG-backed generator (node:crypto), not Math.random.
  const wallets = Array.from({ length: WALLET_COUNT }, () => {
    const privateKey = generatePrivateKey();
    return { privateKey, address: privateKeyToAccount(privateKey).address };
  });

  const links = wallets.map(({ privateKey }) => `${VERCEL_DOMAIN}/?burner=${privateKey}`);
  writeFileSync(outputPath, links.join("\n") + "\n");
  console.log(`Wrote ${WALLET_COUNT} links to ${OUTPUT_FILE} (before funding — keys cannot be lost)\n`);

  if (dryRun) {
    console.log("--dry-run: no transactions sent.\n");
    return;
  }

  // ---------------------------------------------------------------------------------------
  // 5. Fund, with explicit nonces
  // ---------------------------------------------------------------------------------------
  // The nonce is read ONCE and incremented locally. Letting viem fetch it per transaction would
  // re-read a count that has not caught up with the 40 transactions still in the mempool, hand out
  // a nonce already in use, and get everything after it rejected as "nonce too low".
  //
  // Broadcasts are sequential but NOT confirmed one by one: waiting ~12s per receipt would take ten
  // minutes. Nonces are strictly ordered, so confirming the last one confirms every one before it.
  let nonce = await publicClient.getTransactionCount({ address: master.address, blockTag: "pending" });
  const startNonce = nonce;

  const hashes: (Hex | undefined)[] = [];

  for (const [index, wallet] of wallets.entries()) {
    let sent: Hex | undefined;
    let lastError: unknown;

    for (let attempt = 1; attempt <= SEND_ATTEMPTS; attempt++) {
      try {
        sent = await walletClient.sendTransaction({
          to: wallet.address,
          value: AMOUNT_PER_WALLET,
          nonce,
          gas: TRANSFER_GAS_LIMIT,
        });
        break;
      } catch (error) {
        lastError = error;
        if (attempt < SEND_ATTEMPTS) await sleep(SEND_DELAY_MS * attempt * 4);
      }
    }

    if (!sent) {
      // Stop rather than skip. Skipping would leave a hole in the nonce sequence, and every
      // transaction after it would sit unmined in the mempool forever — 50 links, none usable.
      console.error(`\n✗ transfer ${index + 1} failed after ${SEND_ATTEMPTS} attempts.`);
      console.error(`  ${lastError instanceof Error ? lastError.message.split("\n")[0] : String(lastError)}`);
      console.error(`  Broadcast ${index} of ${WALLET_COUNT}; lines ${index + 1}-${WALLET_COUNT} of`);
      console.error(`  ${OUTPUT_FILE} are NOT funded. Delete them, or re-run with --force.\n`);
      break;
    }

    hashes.push(sent);
    nonce++;

    // `\r` only redraws on a terminal. Piped to a file it concatenates into one unreadable line,
    // so fall back to a periodic newline when stdout is not a TTY.
    const progress = `broadcast ${hashes.length}/${WALLET_COUNT}  nonce ${startNonce}-${nonce - 1}`;
    if (process.stdout.isTTY) {
      process.stdout.write(`\r  ${progress}`);
    } else if (hashes.length % 10 === 0 || hashes.length === WALLET_COUNT) {
      console.log(`  ${progress}`);
    }

    await sleep(SEND_DELAY_MS);
  }

  const lastHash = hashes.at(-1);
  if (!lastHash) fail("Nothing was broadcast.");

  console.log(`\n\nWaiting for confirmation of the last transfer...`);
  await publicClient.waitForTransactionReceipt({ hash: lastHash });

  // ---------------------------------------------------------------------------------------
  // 6. Verify the money actually arrived
  // ---------------------------------------------------------------------------------------
  // A mined transaction is not the same claim as "the wallet is funded". Read the balances back:
  // it is 50 cheap `eth_getBalance` calls and it is the only thing that makes the success message
  // true rather than hopeful.
  const funded = await Promise.all(
    wallets.slice(0, hashes.length).map(({ address }) => publicClient.getBalance({ address })),
  );
  const short = funded.filter((value) => value < AMOUNT_PER_WALLET).length;

  console.log(`\n✓ ${funded.length - short}/${WALLET_COUNT} wallets hold ${formatEther(AMOUNT_PER_WALLET)} ETH`);
  if (short > 0) console.log(`✗ ${short} came up short — inspect before handing the links out`);
  console.log(`\n  ${OUTPUT_FILE}   ${WALLET_COUNT} links`);
  console.log(`  Remember: each URL carries a private key. Treat the file as a bag of cash.\n`);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
