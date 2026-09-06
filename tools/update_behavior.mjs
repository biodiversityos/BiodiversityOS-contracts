#!/usr/bin/env node
/**
 * Rewrites the behaviour of records whose field note describes one.
 *
 * The seeding pass wrote "unknown" everywhere, which discarded what the
 * reporters had actually written down. updateRecord re-emits the whole record,
 * so every other field is sent back unchanged and re-derived identically.
 *
 * Usage: node update_behavior.mjs --registry 0x.. [--dry-run] [--limit N]
 */
import { config as loadEnv } from "dotenv";
import { fileURLToPath } from "node:url";
loadEnv({ path: fileURLToPath(new URL("../.env", import.meta.url)) });

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { createPublicClient, createWalletClient, http, formatEther } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import * as chains from "viem/chains";

const SIGHTING_TUPLE = {
  type: "tuple",
  components: [
    { name: "latitude", type: "int256" }, { name: "longitude", type: "int256" },
    { name: "species", type: "string" }, { name: "count", type: "uint16" },
    { name: "behavior", type: "string" }, { name: "observedAt", type: "uint256" },
    { name: "mediaUrl", type: "string" }, { name: "comment", type: "string" },
    { name: "siteName", type: "string" }, { name: "depthFt", type: "uint16" },
    { name: "sizeClass", type: "string" },
  ],
};

const ABI = [
  { type: "function", name: "updateRecord", stateMutability: "nonpayable",
    inputs: [{ name: "recordId", type: "uint256" }, { ...SIGHTING_TUPLE, name: "s" }], outputs: [] },
  { type: "function", name: "reporterOf", stateMutability: "view",
    inputs: [{ type: "uint256" }], outputs: [{ type: "address" }] },
];

const arg = (n, d) => { const i = process.argv.indexOf(`--${n}`); return i === -1 ? d : process.argv[i + 1]; };
const dryRun = process.argv.includes("--dry-run");
const PROGRESS = fileURLToPath(new URL("../data/.behaviour-updated.json", import.meta.url));

const toTuple = (s) => ({
  latitude: BigInt(s.latitude), longitude: BigInt(s.longitude), species: s.species,
  count: s.count, behavior: s.behavior, observedAt: BigInt(s.observedAt),
  mediaUrl: s.mediaUrl ?? "", comment: s.comment ?? "", siteName: s.siteName ?? "",
  depthFt: s.depthFt ?? 0, sizeClass: s.sizeClass ?? "",
});

async function main() {
  const registry = arg("registry", process.env.REGISTRY);
  const limit = arg("limit") ? Number(arg("limit")) : Infinity;
  if (!registry) throw new Error("Pass --registry 0x..");
  if (!process.env.PRIVATE_KEY) throw new Error("PRIVATE_KEY is not set");

  const rpcUrl = process.env.CELO_SEPOLIA_RPC_URL ?? "https://forno.celo-sepolia.celo-testnet.org";
  const account = privateKeyToAccount(process.env.PRIVATE_KEY);
  const probe = createPublicClient({ transport: http(rpcUrl) });
  const chainId = await probe.getChainId();
  const chain = Object.values(chains).find((c) => c?.id === chainId);
  if (!chain) throw new Error(`Unknown chain id ${chainId}`);
  const publicClient = createPublicClient({ chain, transport: http(rpcUrl) });
  const walletClient = createWalletClient({ account, chain, transport: http(rpcUrl) });

  const url = (n) => fileURLToPath(new URL(n, import.meta.url));
  const next = JSON.parse(readFileSync(url("../data/sightings.json"), "utf8"));
  const prev = JSON.parse(readFileSync(url("../data/sightings.prev.json"), "utf8"));

  // Record ids are the seeding order, which is the file order.
  const pending = [];
  next.forEach((n, i) => {
    if (n.behavior !== prev[i].behavior) pending.push({ id: i + 1, sighting: n, from: prev[i].behavior });
  });

  // Order by how much the behaviour tells you. If the run stops early — funds
  // are tight — the records worth having are the ones already written.
  const VALUE = { mating: 0, stranded: 1, feeding: 2, hunting: 3, sheltering: 4, resting: 5, swimming: 6 };
  pending.sort((a, b) => (VALUE[a.sighting.behavior] ?? 9) - (VALUE[b.sighting.behavior] ?? 9) || a.id - b.id);

  const done = new Set(
    existsSync(PROGRESS) ? JSON.parse(readFileSync(PROGRESS, "utf8")) : [],
  );
  const work = pending.filter((w) => !done.has(w.id)).slice(0, limit);
  if (done.size) console.log(`resuming: ${done.size} already written`);

  const [balance, fees] = await Promise.all([
    publicClient.getBalance({ address: account.address }),
    publicClient.estimateFeesPerGas(),
  ]);
  console.log(`chain    : ${chain.name} (${chain.id})`);
  console.log(`sender   : ${account.address}`);
  console.log(`balance  : ${formatEther(balance)} CELO`);
  console.log(`to update: ${work.length}`);

  // One estimate stands in for the rest: the payload shape is identical.
  const sample = await publicClient.estimateContractGas({
    address: registry, abi: ABI, functionName: "updateRecord",
    args: [BigInt(work[0].id), toTuple(work[0].sighting)], account,
  });
  const perTx = sample * (fees.maxFeePerGas ?? fees.gasPrice);
  console.log(`gas/record: ~${sample}`);
  console.log(`estimated : ~${formatEther(perTx * BigInt(work.length))} CELO for ${work.length} records`);

  if (dryRun) {
    const counts = {};
    for (const w of work) counts[w.sighting.behavior] = (counts[w.sighting.behavior] ?? 0) + 1;
    console.log("\nbreakdown:");
    for (const [k, v] of Object.entries(counts).sort((a, b) => b[1] - a[1])) console.log(`  ${String(v).padStart(4)}  ${k}`);
    console.log("\nDRY RUN — nothing broadcast.");
    return;
  }

  let written = 0, gasSpent = 0n;
  const RESERVE = perTx * 2n;
  for (const w of work) {
    const left = await publicClient.getBalance({ address: account.address });
    if (left < perTx + RESERVE) {
      console.log(`\nstopping: ${formatEther(left)} CELO left, not enough to continue safely.`);
      console.log(`${written} written, ${work.length - written} still pending. Top up and rerun.`);
      break;
    }
    const hash = await walletClient.writeContract({
      address: registry, abi: ABI, functionName: "updateRecord",
      args: [BigInt(w.id), toTuple(w.sighting)],
    });
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success") throw new Error(`record ${w.id} reverted: ${hash}`);
    gasSpent += receipt.gasUsed;
    written++;
    done.add(w.id);
    writeFileSync(PROGRESS, JSON.stringify([...done]));
    if (written % 25 === 0 || written === work.length) {
      console.log(`  ${written}/${work.length} updated, gas so far ${gasSpent}`);
    }
  }
  console.log(`\ndone. ${written} records, total gas ${gasSpent}`);
}

main().catch((e) => { console.error("\nupdate failed:", e.shortMessage ?? e.message); process.exit(1); });
