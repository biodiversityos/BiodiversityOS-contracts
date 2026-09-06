#!/usr/bin/env node
/**
 * Seeds the registry from prepared field data.
 *
 * Records are submitted in batches sized to fit a block, with the on-chain
 * record id counter used as the resume point, so an interrupted run can be
 * restarted without duplicating rows.
 *
 * Usage:
 *   node import.mjs --data ../data/sightings.json --registry 0x.. [--dry-run]
 *                   [--batch-size 25] [--limit N]
 */
import { config as loadEnv } from "dotenv";
import { fileURLToPath } from "node:url";

// The key lives in the Foundry project root, one level up from tools/.
loadEnv({ path: fileURLToPath(new URL("../.env", import.meta.url)) });
import { readFileSync } from "node:fs";
import { createPublicClient, createWalletClient, http, formatEther, defineChain } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import * as chains from "viem/chains";

/** Trust the RPC for the chain id, so the same tool works against a local node. */
async function resolveChain(rpcUrl) {
  const probe = createPublicClient({ transport: http(rpcUrl) });
  const id = await probe.getChainId();
  const known = Object.values(chains).find((c) => c?.id === id);
  return (
    known ??
    defineChain({
      id,
      name: `chain-${id}`,
      nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
      rpcUrls: { default: { http: [rpcUrl] } },
    })
  );
}

const SIGHTING_TUPLE = {
  type: "tuple",
  components: [
    { name: "latitude",   type: "int256"  },
    { name: "longitude",  type: "int256"  },
    { name: "species",    type: "string"  },
    { name: "count",      type: "uint16"  },
    { name: "behavior",   type: "string"  },
    { name: "observedAt", type: "uint256" },
    { name: "mediaUrl",   type: "string"  },
    { name: "comment",    type: "string"  },
    { name: "siteName",   type: "string"  },
    { name: "depthFt",    type: "uint16"  },
    { name: "sizeClass",  type: "string"  },
  ],
};

const ABI = [
  {
    type: "function", name: "seedRecordBatch", stateMutability: "nonpayable",
    inputs: [{ ...SIGHTING_TUPLE, name: "batch", type: "tuple[]" }],
    outputs: [{ name: "firstRecordId", type: "uint256" }, { name: "lastRecordId", type: "uint256" }],
  },
  {
    type: "function", name: "submitRecordBatch", stateMutability: "nonpayable",
    inputs: [{ ...SIGHTING_TUPLE, name: "batch", type: "tuple[]" }],
    outputs: [{ name: "firstRecordId", type: "uint256" }, { name: "lastRecordId", type: "uint256" }],
  },
  {
    type: "function", name: "owner", stateMutability: "view",
    inputs: [], outputs: [{ type: "address" }],
  },
  {
    type: "function", name: "nextRecordId", stateMutability: "view",
    inputs: [], outputs: [{ type: "uint256" }],
  },
  {
    type: "function", name: "whitelist", stateMutability: "view",
    inputs: [{ type: "address" }], outputs: [{ type: "bool" }],
  },
];

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i === -1 ? fallback : process.argv[i + 1];
}
const flag = (name) => process.argv.includes(`--${name}`);

function toTuple(s) {
  return {
    latitude:   BigInt(s.latitude),
    longitude:  BigInt(s.longitude),
    species:    s.species,
    count:      s.count,
    behavior:   s.behavior,
    observedAt: BigInt(s.observedAt),
    mediaUrl:   s.mediaUrl ?? "",
    comment:    s.comment ?? "",
    siteName:   s.siteName ?? "",
    depthFt:    s.depthFt ?? 0,
    sizeClass:  s.sizeClass ?? "",
  };
}

async function main() {
  const dataPath = arg("data", "../data/sightings.json");
  const registry = arg("registry", process.env.REGISTRY);
  const batchSize = Number(arg("batch-size", 25));
  const limit = arg("limit") ? Number(arg("limit")) : Infinity;
  const dryRun = flag("dry-run");

  if (!registry) throw new Error("Pass --registry 0x.. or set REGISTRY");
  if (!process.env.PRIVATE_KEY) throw new Error("PRIVATE_KEY is not set");

  const rpcUrl = process.env.CELO_SEPOLIA_RPC_URL ?? "https://forno.celo-sepolia.celo-testnet.org";
  const account = privateKeyToAccount(process.env.PRIVATE_KEY);
  const chain = await resolveChain(rpcUrl);
  const publicClient = createPublicClient({ chain, transport: http(rpcUrl) });
  const walletClient = createWalletClient({ account, chain, transport: http(rpcUrl) });

  const all = JSON.parse(readFileSync(new URL(dataPath, import.meta.url), "utf8"));
  const sightings = all.slice(0, limit);

  console.log(`chain    : ${chain.name} (${chain.id})`);
  console.log(`registry : ${registry}`);
  console.log(`sender   : ${account.address}`);
  console.log(`records  : ${sightings.length} (batch size ${batchSize})`);

  const [balance, whitelisted, nextId, owner] = await Promise.all([
    publicClient.getBalance({ address: account.address }),
    publicClient.readContract({ address: registry, abi: ABI, functionName: "whitelist", args: [account.address] }),
    publicClient.readContract({ address: registry, abi: ABI, functionName: "nextRecordId" }),
    publicClient.readContract({ address: registry, abi: ABI, functionName: "owner" }),
  ]);

  const isOwner = owner.toLowerCase() === account.address.toLowerCase();
  const fn = isOwner ? "seedRecordBatch" : "submitRecordBatch";

  console.log(`balance  : ${formatEther(balance)} CELO`);
  console.log(`whitelist: ${whitelisted}`);
  console.log(`nextId   : ${nextId}`);
  console.log(`method   : ${fn}${isOwner ? " (owner, cheap path)" : ""}`);

  if (!whitelisted && !isOwner) throw new Error("Sender is not whitelisted on the registry");

  // Records already on chain are skipped, making reruns safe after a failure.
  const alreadyImported = Number(nextId) - 1;
  if (alreadyImported > 0) {
    console.log(`resuming: skipping the first ${alreadyImported} record(s) already on chain`);
  }
  const pending = sightings.slice(alreadyImported);
  if (pending.length === 0) {
    console.log("nothing to do");
    return;
  }

  let submitted = 0;
  let gasSpent = 0n;
  let budgetWarned = false;

  for (let i = 0; i < pending.length; i += batchSize) {
    const chunk = pending.slice(i, i + batchSize).map(toTuple);
    const label = `batch ${i / batchSize + 1} (${chunk.length} records, ids ${alreadyImported + i + 1}..${alreadyImported + i + chunk.length})`;

    const gas = await publicClient.estimateContractGas({
      address: registry, abi: ABI, functionName: fn,
      args: [chunk], account,
    });

    if (!dryRun && !budgetWarned) {
      const fees = await publicClient.estimateFeesPerGas();
      const perBatch = gas * (fees.maxFeePerGas ?? fees.gasPrice);
      const batchesLeft = BigInt(Math.ceil((pending.length - i) / batchSize));
      if (perBatch * batchesLeft > balance) {
        console.warn(
          `warning: balance may not cover the remaining ~${batchesLeft} batches. ` +
          `The run is resumable, so top up and rerun to continue.`,
        );
      }
      budgetWarned = true;
    }

    if (dryRun) {
      console.log(`${label}: would use ~${gas} gas`);
      gasSpent += gas;
      submitted += chunk.length;
      continue;
    }

    const hash = await walletClient.writeContract({
      address: registry, abi: ABI, functionName: fn,
      args: [chunk],
      gas: (gas * 12n) / 10n,
    });
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success") throw new Error(`${label} reverted: ${hash}`);

    gasSpent += receipt.gasUsed;
    submitted += chunk.length;
    console.log(`${label}: ok, gas ${receipt.gasUsed}, tx ${hash}`);
  }

  console.log(`\n${dryRun ? "DRY RUN — nothing broadcast." : "done."}`);
  console.log(`records ${dryRun ? "planned" : "submitted"}: ${submitted}`);
  console.log(`total gas ${dryRun ? "estimated" : "used"}: ${gasSpent}`);
}

main().catch((err) => {
  console.error("\nimport failed:", err.shortMessage ?? err.message);
  process.exit(1);
});
