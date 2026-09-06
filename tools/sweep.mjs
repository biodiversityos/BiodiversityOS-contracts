#!/usr/bin/env node
/**
 * Moves the entire balance of OLD_PRIVATE_KEY's account to a destination.
 *
 * Testnet gas tokens only: this exists because the original deployer key is
 * being retired and its remaining balance would otherwise be stranded.
 * The transfer is sized to leave exactly zero, so nothing is left behind.
 *
 * Usage:
 *   node sweep.mjs --to 0x.. [--dry-run]
 */
import { config as loadEnv } from "dotenv";
import { fileURLToPath } from "node:url";

// The key lives in the Foundry project root, one level up from tools/.
loadEnv({ path: fileURLToPath(new URL("../.env", import.meta.url)) });
import { createPublicClient, createWalletClient, http, formatEther, isAddress } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import * as chains from "viem/chains";

const GAS_LIMIT = 21_000n;

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i === -1 ? fallback : process.argv[i + 1];
}

async function main() {
  const to = arg("to");
  const dryRun = process.argv.includes("--dry-run");

  if (!to || !isAddress(to)) throw new Error("Pass a valid --to 0x..");
  if (!process.env.OLD_PRIVATE_KEY) {
    throw new Error("OLD_PRIVATE_KEY is not set in .env");
  }

  const rpcUrl = process.env.CELO_SEPOLIA_RPC_URL ?? "https://forno.celo-sepolia.celo-testnet.org";
  const account = privateKeyToAccount(process.env.OLD_PRIVATE_KEY);

  const probe = createPublicClient({ transport: http(rpcUrl) });
  const chainId = await probe.getChainId();
  const chain = Object.values(chains).find((c) => c?.id === chainId);
  if (!chain) throw new Error(`Unknown chain id ${chainId}`);
  if (chain.id === 42220) throw new Error("Refusing to run against Celo mainnet");

  const publicClient = createPublicClient({ chain, transport: http(rpcUrl) });
  const walletClient = createWalletClient({ account, chain, transport: http(rpcUrl) });

  const [balance, fees] = await Promise.all([
    publicClient.getBalance({ address: account.address }),
    publicClient.estimateFeesPerGas(),
  ]);

  // Reserve the exact worst-case cost of this one transfer, so the account is
  // emptied without the transaction becoming unpayable.
  const maxFee = fees.maxFeePerGas ?? fees.gasPrice;
  const reserve = GAS_LIMIT * maxFee;
  const value = balance - reserve;

  console.log(`chain   : ${chain.name} (${chain.id})`);
  console.log(`from    : ${account.address}`);
  console.log(`to      : ${to}`);
  console.log(`balance : ${formatEther(balance)} CELO`);
  console.log(`gas res : ${formatEther(reserve)} CELO`);
  console.log(`sending : ${formatEther(value < 0n ? 0n : value)} CELO`);

  if (value <= 0n) throw new Error("Balance does not cover the transfer fee");

  if (dryRun) {
    console.log("\nDRY RUN — nothing broadcast.");
    return;
  }

  const hash = await walletClient.sendTransaction({
    to,
    value,
    gas: GAS_LIMIT,
    maxFeePerGas: fees.maxFeePerGas,
    maxPriorityFeePerGas: fees.maxPriorityFeePerGas,
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`transfer reverted: ${hash}`);

  const [left, arrived] = await Promise.all([
    publicClient.getBalance({ address: account.address }),
    publicClient.getBalance({ address: to }),
  ]);
  console.log(`\ndone. tx ${hash}`);
  console.log(`left behind : ${formatEther(left)} CELO`);
  console.log(`destination : ${formatEther(arrived)} CELO`);
}

main().catch((err) => {
  console.error("\nsweep failed:", err.shortMessage ?? err.message);
  process.exit(1);
});
