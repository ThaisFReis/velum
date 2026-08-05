/**
 * Velum demo — identity gating on a confidential token.
 *
 * Two wallets try the same operation on a confidential token whose compliance
 * policy is `velum-policy`, which asks an ERC-3643/T-REX identity registry:
 *
 *   Alice — holds a KYC claim signed by an approved issuer  -> accepted
 *   Bob   — holds no identity at all                        -> refused
 *
 * The refusal is the point. Bob is not rejected for being absent from a list;
 * he is rejected because he carries no valid claim from an approved certifier,
 * and the same registry answers for the public asset and for this wrapper.
 *
 * Usage (from refs/ct-demo/packages/sdk):
 *   VELUM_TOKEN=<compliant token id> pnpm exec tsx ../../../../scripts/demo-gate.ts
 */

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { Keypair, Networks } from "@stellar/stellar-sdk";

import { ChainClient, keypairSigner } from "../refs/ct-demo/packages/sdk/src/chain/client.js";
import { submitRegister } from "../refs/ct-demo/packages/sdk/src/chain/contract.js";
import { deriveKeys } from "../refs/ct-demo/packages/sdk/src/crypto/keys.js";
import { randomScalar } from "../refs/ct-demo/packages/sdk/src/crypto/field.js";
import { addressToField } from "../refs/ct-demo/packages/sdk/src/crypto/address.js";
import { buildRegisterWitness } from "../refs/ct-demo/packages/sdk/src/witness/register.js";
import { CircuitProver } from "../refs/ct-demo/packages/sdk/src/proving/prover.js";
import { loadCircuit } from "../refs/ct-demo/packages/sdk/src/proving/artifacts.js";

const REPO = join(import.meta.dirname, "..");
const RPC_URL = "https://soroban-testnet.stellar.org";
const PASSPHRASE = Networks.TESTNET;
const AUDITOR_ID = 0;

/** Reads a secret from the local stellar CLI identity store. */
const secretOf = (name: string) =>
  execFileSync("stellar", ["keys", "show", name], { encoding: "utf8" }).trim();

async function main(): Promise<void> {
  const token = process.env.VELUM_TOKEN;
  if (!token) throw new Error("set VELUM_TOKEN to the compliance-gated confidential token id");

  const dep = JSON.parse(readFileSync(join(REPO, "refs/ct-demo/deployments/testnet.json"), "utf8"));
  const client = new ChainClient({
    rpcUrl: RPC_URL,
    networkPassphrase: PASSPHRASE,
    contracts: { token, verifier: dep.contracts.verifier, auditor: dep.contracts.auditor },
  });
  const addrF = addressToField(token);
  const prover = new CircuitProver(loadCircuit("register"));

  console.log("token (policy-gated) =", token);

  for (const [label, identityNote] of [
    ["velum-alice", "KYC claim from an approved issuer"],
    ["velum-bob", "no identity registered"],
  ] as const) {
    const kp = Keypair.fromSecret(secretOf(label));
    const keys = deriveKeys(randomScalar(), addrF);
    const w = buildRegisterWitness(keys);
    const { proof } = await prover.prove(w.inputs);

    console.log(`\n[${label}] ${identityNote}`);
    try {
      const r = await submitRegister(
        client, keypairSigner(kp.secret(), PASSPHRASE), kp.publicKey(), AUDITOR_ID, w, proof,
      );
      console.log(`  ✅ accepted — tx ${r.hash}`);
    } catch (e) {
      // The policy rejects by returning false, which the token turns into a
      // NotAuthorizedByPolicy error. A valid ZK proof is not enough: identity
      // is checked before the proof is even considered.
      const msg = String(e).match(/Error\(Contract, #\d+\)/)?.[0] ?? String(e).slice(0, 120);
      console.log(`  ⛔ refused by policy — ${msg}`);
    }
  }
}

main().catch((e) => { console.error(e); process.exit(1); });
