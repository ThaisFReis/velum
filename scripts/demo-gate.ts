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
import { submitRegister, submitDeposit } from "../refs/ct-demo/packages/sdk/src/chain/contract.js";
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

/** Small public deposit used to probe the gate on an already-registered wallet. */
const PROBE_DEPOSIT = 1n;

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
    console.log(`\n[${label}] ${identityNote}`);

    // `register` is gated by the policy, so it is the cleanest probe — but it
    // is also once-per-account. On a repeat run an authorized wallet is
    // already registered, and reporting that as a policy refusal would slander
    // our own gate. So: register when we can, fall back to a deposit (gated by
    // the same policy) when we cannot, and always name the error we got.
    const already = await client.isRegistered(kp.publicKey());
    const signer = keypairSigner(kp.secret(), PASSPHRASE);

    try {
      if (already) {
        await submitDeposit(client, signer, kp.publicKey(), kp.publicKey(), PROBE_DEPOSIT);
        console.log(`  ✅ accepted — already registered; a policy-gated deposit went through`);
      } else {
        const keys = deriveKeys(randomScalar(), addrF);
        const w = buildRegisterWitness(keys);
        const { proof } = await prover.prove(w.inputs);
        const r = await submitRegister(client, signer, kp.publicKey(), AUDITOR_ID, w, proof);
        console.log(`  ✅ accepted — tx ${r.hash}`);
      }
    } catch (e) {
      const code = String(e).match(/Error\(Contract, #(\d+)\)/)?.[1];
      const known: Record<string, string> = {
        "3602": "NotAuthorizedByPolicy — the identity registry has no valid claim for this account",
        "3601": "AccountFrozen",
        "3603": "NotAuthorizedBySac",
        "3500": "AccountAlreadyRegistered — not a policy decision",
      };
      console.log(`  ⛔ refused — #${code ?? "?"} ${known[code ?? ""] ?? String(e).slice(0, 100)}`);
    }
  }
}

main().catch((e) => { console.error(e); process.exit(1); });
