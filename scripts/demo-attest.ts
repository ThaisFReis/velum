/**
 * Velum demo — on-chain proof of position against a regulatory threshold.
 *
 * Runs the whole path against Stellar testnet, on real state:
 *
 *   register -> deposit -> merge        (a real confidential balance)
 *     -> read the opening (v_s, r_s)    (from the account's own event history)
 *     -> prove "position >= threshold"  (disclose_balance_ge, UltraHonk)
 *     -> attest_position(account, proof) (velum-attest verifies ON-CHAIN)
 *
 * Nobody learns the amount. The verifier reads C_spend and PVK_A from the
 * token, the threshold from its own profile, and receives only a proof.
 *
 * It then runs the negative case: the same holder proving a threshold ABOVE
 * their position. The witness cannot be built, so no proof exists to submit.
 *
 * Usage (from the repo root):
 *   cd refs/ct-demo/packages/sdk && pnpm exec tsx ../../../../scripts/demo-attest.ts
 *
 * Requires: the CT stack deployed (refs/ct-demo/deployments/testnet.json),
 * `velum-attest` deployed with this circuit's VK, nargo + bb on PATH.
 */

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { Address, Keypair, Networks, xdr } from "@stellar/stellar-sdk";

import { ChainClient, keypairSigner } from "../refs/ct-demo/packages/sdk/src/chain/client.js";
import { submitRegister, submitDeposit, submitMerge } from "../refs/ct-demo/packages/sdk/src/chain/contract.js";
import { deriveKeys } from "../refs/ct-demo/packages/sdk/src/crypto/keys.js";
import { randomScalar } from "../refs/ct-demo/packages/sdk/src/crypto/field.js";
import { addressToField } from "../refs/ct-demo/packages/sdk/src/crypto/address.js";
import { buildRegisterWitness } from "../refs/ct-demo/packages/sdk/src/witness/register.js";
import { CircuitProver } from "../refs/ct-demo/packages/sdk/src/proving/prover.js";
import { loadCircuit } from "../refs/ct-demo/packages/sdk/src/proving/artifacts.js";
import { StateEngine, MemoryStore } from "../refs/ct-demo/packages/sdk/src/state/index.js";

// ---------------------------------------------------------------- config

const REPO = join(import.meta.dirname, "..");
const RPC_URL = "https://soroban-testnet.stellar.org";
const PASSPHRASE = Networks.TESTNET;
const FRIENDBOT = "https://friendbot.stellar.org";
const CIRCUIT = join(REPO, "circuits/disclose_balance_ge");
const AUDITOR_ID = 0;

/** Deposited so the position clears the profile's floor with room to spare. */
const DEPOSIT = 1_000_000n;

const hex = (v: bigint) => `0x${v.toString(16).padStart(64, "0")}`;
const sh = (s: string) => `${s.slice(0, 6)}…${s.slice(-4)}`;

async function friendbot(pk: string): Promise<void> {
  const r = await fetch(`${FRIENDBOT}?addr=${pk}`);
  if (!r.ok && r.status !== 400) throw new Error(`friendbot ${r.status}`);
}

// ---------------------------------------------------------------- proving

/**
 * Our circuit, driven through the SAME prover the confidential token uses.
 *
 * This matters more than convenience: the on-chain UltraHonk verifier consumes
 * KECCAK-transcript proofs, and `CircuitProver` produces exactly those. The
 * `bb` CLI defaults to a different transcript, so a CLI-generated proof (and
 * its verification key) parse fine and then fail verification on-chain. Same
 * circuit, same bb version, incompatible artifacts.
 */
function prover(): CircuitProver {
  const circuit = JSON.parse(
    readFileSync(join(CIRCUIT, "target/disclose_balance_ge.json"), "utf8"),
  );
  return new CircuitProver(circuit);
}

/**
 * Witness for `disclose_balance_ge`. Every public input here is one the
 * CONTRACT independently reassembles from chain state — building them is how
 * the prover commits to the same statement, not how it chooses one.
 */
function inputs(a: {
  sk: bigint; vS: bigint; rS: bigint; vR: bigint; rR: bigint; addrF: bigint;
  pvk: { x: bigint; y: bigint }; cSpend: { x: bigint; y: bigint };
  cReceive: { x: bigint; y: bigint }; threshold: bigint;
}) {
  return {
    sk: hex(a.sk),
    v_s: hex(a.vS),
    r_s: hex(a.rS),
    v_r: hex(a.vR),
    r_r: hex(a.rR),
    addr_f: hex(a.addrF),
    pvk_a_x: hex(a.pvk.x),
    pvk_a_y: hex(a.pvk.y),
    c_spend_x: hex(a.cSpend.x),
    c_spend_y: hex(a.cSpend.y),
    c_receive_x: hex(a.cReceive.x),
    c_receive_y: hex(a.cReceive.y),
    v_threshold: hex(a.threshold),
  };
}

// ---------------------------------------------------------------- main

async function main(): Promise<void> {
  const p = prover();
  const vk = await p.verificationKey();
  if (!process.env.VELUM_ATTEST) {
    console.log(`verification key (${vk.length} B) — deploy velum-attest with:\n`);
    console.log(Buffer.from(vk).toString("hex"));
    return;
  }
  const attest = process.env.VELUM_ATTEST;

  const dep = JSON.parse(readFileSync(join(REPO, "refs/ct-demo/deployments/testnet.json"), "utf8"));
  const client = new ChainClient({
    rpcUrl: RPC_URL,
    networkPassphrase: PASSPHRASE,
    contracts: { token: dep.contracts.token, verifier: dep.contracts.verifier, auditor: dep.contracts.auditor },
  });
  const addrF = addressToField(dep.contracts.token);

  console.log("token        =", dep.contracts.token);
  console.log("velum-attest =", attest);

  // --- a holder with a real confidential position -----------------------
  console.log("\n[1/4] holder");
  const kp = Keypair.random();
  await friendbot(kp.publicKey());
  const signer = keypairSigner(kp.secret(), PASSPHRASE);
  const keys = deriveKeys(randomScalar(), addrF);
  console.log(`  ${kp.publicKey()}`);

  const engine = new StateEngine({
    client, store: new MemoryStore(), keys,
    address: kp.publicKey(), fromLedger: dep.deployedAtLedger,
  });

  console.log("\n[2/4] register + deposit + merge");
  const w = buildRegisterWitness(keys);
  const { proof: regProof } = await new CircuitProver(loadCircuit("register")).prove(w.inputs);
  await submitRegister(client, signer, kp.publicKey(), AUDITOR_ID, w, regProof);
  await submitDeposit(client, signer, kp.publicKey(), kp.publicKey(), DEPOSIT);
  await submitMerge(client, signer, kp.publicKey());

  const state = await engine.sync();
  const onChain = await client.confidentialBalance(kp.publicKey());
  if (!onChain) throw new Error("account not registered on chain");
  const cSpend = onChain.spendableBalance.toAffine();
  const cReceive = onChain.receivingBalance.toAffine();
  const pvk = onChain.viewingPublicKey.toAffine();
  console.log(`  position established. On the explorer this balance is a commitment:`);
  console.log(`    C_spend.x = ${hex(cSpend.x)}`);

  // --- the honest proof -------------------------------------------------
  console.log("\n[3/4] prove position >= threshold, then verify ON-CHAIN");
  const threshold = 500_000n;
  const t0 = Date.now();
  const { proof } = await p.prove(inputs({
    sk: keys.sk, vS: state.spendable.v, rS: state.spendable.r,
    vR: state.receiving.v, rR: state.receiving.r,
    addrF, pvk, cSpend, cReceive, threshold,
  }));
  console.log(`  proof: ${proof.length} B in ${((Date.now() - t0) / 1000).toFixed(2)}s`);

  const res = await client.invoke(attest, "attest_position", [
    new Address(kp.publicKey()).toScVal(),
    xdr.ScVal.scvBytes(Buffer.from(proof)),
  ], signer);
  console.log(`  ✅ attested on-chain — tx ${sh(res.hash)}`);
  console.log(`     https://stellar.expert/explorer/testnet/tx/${res.hash}`);

  // The freshness window is the caller's to choose; there is no argument-free form.
  const FRESH = 1000; // ledgers ~ 1.5 h
  const isAttested = await client.simulate(attest, "is_attested",
    [new Address(kp.publicKey()).toScVal(), xdr.ScVal.scvU32(FRESH)]);
  console.log(`  is_attested(max_age=${FRESH} ledgers) = ${xdr.ScVal.fromXDR(isAttested.toXDR()).value()}`);
  const stale = await client.simulate(attest, "is_attested",
    [new Address(kp.publicKey()).toScVal(), xdr.ScVal.scvU32(0)]);
  console.log(`  is_attested(max_age=0)         = ${xdr.ScVal.fromXDR(stale.toXDR()).value()}  ← same record, stricter window`);
  console.log(`     the contract learned the position clears ${threshold} — and nothing else.`);

  // --- the dishonest one ------------------------------------------------
  console.log("\n[4/4] the same holder claiming a threshold above their position");
  try {
    await p.prove(inputs({
      sk: keys.sk, vS: state.spendable.v, rS: state.spendable.r,
      vR: state.receiving.v, rR: state.receiving.r,
      addrF, pvk, cSpend, cReceive,
      threshold: state.spendable.v + state.receiving.v + 1n,
    }));
    console.log("  ✗ UNEXPECTED: a proof was produced for a false claim");
    process.exitCode = 1;
  } catch {
    console.log("  ✅ refused: the witness cannot be built, so no proof exists to submit.");
    console.log("     A false claim fails before verification, not at it.");
  }
}

// The bb.js prover leaves worker handles open, so the process does not exit on its own once
// main() returns. Force it — but only after stdout has drained, or a piped run loses its tail.
main()
  .catch((e) => { console.error(e); process.exitCode = 1; })
  .finally(() => process.stdout.write("", () => process.exit(process.exitCode ?? 0)));
