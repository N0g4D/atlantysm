/**
 * Copy the ABIs the client imports out of Foundry's `out/` and into `abi/`, which IS committed.
 *
 * ---------------------------------------------------------------------------------------------
 * WHY THIS EXISTS
 * ---------------------------------------------------------------------------------------------
 * The client imports three Foundry artifacts. `out/` is gitignored, so on a clean checkout — a
 * Vercel build, say — those files simply are not there and `vite build` dies on the import.
 *
 * The alternative was to install Foundry in the cloud build and compile the whole Solidity tree
 * just to produce three JSON files: minutes of build time, a toolchain download, and a deploy that
 * breaks whenever foundryup does. Committing the ABIs makes the client buildable from source alone.
 *
 * ---------------------------------------------------------------------------------------------
 * THE DRIFT RISK, STATED PLAINLY
 * ---------------------------------------------------------------------------------------------
 * These files are derived state, and derived state can go stale. Change a System's signature,
 * commit without rebuilding, and the client ships an ABI that no longer matches the World — calls
 * would encode against a selector that does not exist.
 *
 * The mitigation is that this runs as part of `pnpm --filter contracts build`, so a normal build
 * refreshes them. What it cannot do is force you to COMMIT the refresh: treat `abi/` as part of the
 * contract diff, not as noise to discard.
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const contractsRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const outDir = join(contractsRoot, "out");
const abiDir = join(contractsRoot, "abi");

/** Artifact basenames. Foundry writes `out/<file>.sol/<name>.abi.json`. */
const artifacts = [
  { file: "IWorld.sol", name: "IWorld" },
  { file: "CrystalNFT.sol", name: "CrystalNFT" },
  { file: "AtlantysmAccount.sol", name: "AtlantysmAccount" },
];

mkdirSync(abiDir, { recursive: true });

const missing = [];
let written = 0;

for (const { file, name } of artifacts) {
  const source = join(outDir, file, `${name}.abi.json`);
  if (!existsSync(source)) {
    missing.push(relative(contractsRoot, source));
    continue;
  }

  // Re-serialise rather than copying bytes: `forge build` is not byte-stable across versions in its
  // whitespace, and a formatting-only churn in the committed diff hides the changes that matter.
  const abi = JSON.parse(readFileSync(source, "utf-8"));
  const serialised = JSON.stringify(abi, null, 2);

  // The `.d.ts` is not optional decoration. Left out, TypeScript falls back to `resolveJsonModule`
  // and widens every `"type": "function"` to `string`, which no longer satisfies viem's `Abi` —
  // `tsc --noEmit` fails even though `vite build` succeeds, because esbuild never typechecks.
  // This mirrors what `mud abi-ts` emits for `out/`, generated from the same parse so the JSON and
  // its declaration cannot disagree.
  const files = [
    [`${name}.abi.json`, serialised + "\n"],
    [`${name}.abi.json.d.ts`, `declare const abi: ${serialised};\n\nexport default abi;\n`],
  ];

  for (const [fileName, contents] of files) {
    const target = join(abiDir, fileName);
    if (existsSync(target) && readFileSync(target, "utf-8") === contents) continue;
    writeFileSync(target, contents);
    console.log(`export-abis: updated abi/${fileName}`);
    written++;
  }
}

if (missing.length > 0) {
  // Loud, not silent: a missing artifact means the client would build against whatever stale copy
  // happens to be committed, which is exactly the failure this script exists to prevent.
  console.error(
    `export-abis: missing Foundry artifacts:\n  ${missing.join("\n  ")}\n` +
      `Run \`pnpm --filter contracts build\` (which runs \`mud build\`) first.`,
  );
  process.exit(1);
}

console.log(written === 0 ? "export-abis: already up to date" : `export-abis: ${written} file(s) updated`);
