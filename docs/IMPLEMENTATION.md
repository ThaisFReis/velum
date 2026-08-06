# Implementation record

What exists, how it was built, and the evidence that it runs. Every number and hash below was
produced on testnet or on the authors' machine — nothing here is projected.

Last run: **2026-08-05**. Network: **Stellar testnet**.

---

## 1. What is deployed

### Ours

| Contract | Address | Notes |
|---|---|---|
| `velum-attest` | `CDEDFUYUNNQLU4C7ISKXJ26AIPIR42UJPW7XO72EZFEC3Y6VT6OO7LPK` | 36 937 B wasm. Constructor: owner, token, `addr_f`, VK, threshold=500 000 |
| `velum-policy` | `CDJET5BV36RDRNCNCNXJFYWUKPCX4VWXTUY4EGU4W5VUJ3FHLHIYFPKV` | 8 101 B wasm. Delegates to the identity verifier, and fails closed on an issuer-less topic (§6.3). The gated token points here |
| `velum-policy` (v1, superseded) | `CCCQ7Z6FYLCIXHBQDSIUJ46YMS63VDHY3ZM5ISGWGFJ5EXONOWOXQXDK` | 7 808 B. Kept deployed as the control in the A/B below |
| identity-gated token | `CBDT4EKUF66MS7HHDHMLDPDI7TOPZCV7AYYLC53ES7TEB67KAT3BFWV5` | Confidential token deployed through upstream's factory, bound to `velum-policy`, `sac_passthrough: true` |

### Confidential-token stack (upstream code, deployed by us)

| Contract | Address |
|---|---|
| token | `CDO7PJCVNL2H3HVQDMPYBDAWWBE62YXZLZULHCAIYVHBZSP2CNAI4KB7` |
| verifier | `CDYCNTXK2DJA4YSOCKXP4L64T54RCT3FFR4LAT43HU6WF2QJCL4MH4DR` |
| auditor | `CDR2EBDLPI4L7HLXU7I4C2356HP6YNIIMBP5QHTNM4TPQJR6WLZ6ZCJH` |
| allowlist / blocklist | `CAOM4HLC…6DND` / `CB3A3EIU…7TWQR` |
| factory | `CD2SJ43LIYK4LNZE75D66EAB7FGYXJVBMN6HVRAVMLSHHRFP7ENIXXSC` |
| underlying (native SAC) | `CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC` |

`addr_f` of the token: `0x22c4a8e478bce4b5212b0518bface4cf5510db8333293ff99d6046f8a0d51fa8`

### RWA identity stack (upstream code, deployed by us)

| Contract | Address |
|---|---|
| claim-topics-and-issuers | `CB7ODYCJLLCWHMCYSZ6IUT3OQEQ5KEGX2OXNM3I2CIMI3IQ3QOTB226N` |
| claim-issuer | `CBLUFPON4LW4OXPOZP6LYHFPFQJXDW6M5O52ES2TALKWBN4REUX665IA` |
| identity (holder) | `CDLHCYRNG5BKYJMLUGVTIVJBST2BTDYEDMGT3VCYJCK3Q63DZDB3SST7` |
| identity-registry | `CDG2WQ3CSIDHUB5CYHONFSSOQJ3GUUDVLWZUXUU7WEUITO2ZHDJSL25H` |
| identity-verifier | `CBZS626ZJMLC2ILCJCV4RLSLR7MZYBDEV7DNAEY5CZRKUFQQUPVH5M22` |

Claim topic 1 (KYC) registered; the claim issuer is trusted for it; an Ed25519 signing key is
authorised; the holder's identity contract carries a signed KYC claim; and the holder is
registered in the identity registry with a Brazilian residence profile
(tx `da8c0a6c…376e`, events `IdentityStored` + `country_data_added`). That last call needed the
XDR-JSON payload in §6.4 — the format documented upstream cannot work.

---

## 2. The headline result: a position proved on-chain

`scripts/demo-attest.ts` runs the whole path against testnet, on real state:

```
[1/4] holder
  GCCYQYZNQZBV66J4IJG2CLNZNH4Z2PGGPFM3HYDBG5IDI6Y2GIDZI34G

[2/4] register + deposit + merge
  position established. On the explorer this balance is a commitment:
    C_spend.x = 0x1c37cfd2395d01244935ca8eef123da331b2a55b4b86f600b43262373b50e429

[3/4] prove position >= threshold, then verify ON-CHAIN
  proof: 14592 B in 3.81s
  ✅ attested on-chain — tx f8ff29…3267
     https://stellar.expert/explorer/testnet/tx/f8ff2951ad2277d4337b590842762a60ee46b8936d9c9014f5154a0918c13267
  is_attested = true
     the contract learned the position clears 500000 — and nothing else.

[4/4] the same holder claiming a threshold above their position
  ✅ refused: the witness cannot be built, so no proof exists to submit.
     A false claim fails before verification, not at it.
```

**Attestation transaction:**
`f8ff2951ad2277d4337b590842762a60ee46b8936d9c9014f5154a0918c13267`

What that transaction proves: a Soroban contract read the holder's commitment and viewing key
from the token, read the threshold from its own profile, verified an UltraHonk proof, and
recorded that the position clears 500 000 — **without the amount appearing anywhere**, the
verifier included.

The negative case matters as much. Asked to prove a threshold above the real position, the
prover cannot build a witness: the failure happens before a proof exists, so there is nothing
to submit and nothing for the verifier to reject.

### Public inputs the contract reassembles

192 bytes, six field elements, in circuit order. From the run above:

| # | Field | Source at verification time |
|---|---|---|
| 0 | `22c4a8e4…1fa8` | `addr_f`, pinned at construction |
| 1–2 | `1fe490fe…9d02` / `1a1f7369…c1e1` | `PVK_A`, read from the token |
| 3–4 | `1c37cfd2…e429` / `20c1afb4…1cdd` | `C_spend`, read from the token |
| 5 | `…0007a120` | threshold (500 000), the contract's own profile |

The prover supplies only the proof. A caller substituting its own commitment would verify
against a blob the contract never assembles.

---

## 2.1 Identity gating: the same question, two answers

`velum-policy` is deployed against the identity verifier and answers the token's authorization
question for two wallets. Alice carries a KYC claim issued by an approved certifier; Bob carries
nothing.

```
=== is_authorized(ALICE — KYC claim registered):
true

=== is_authorized(BOB — no identity):
CBZS626Z… - Failure - Log: {"vec":[{"string":"VM call trapped with HostError"},
                                   {"symbol":"verify_identity"},{"error":{"contract":321}}]}
false
```

Error 321 is `IdentityNotFound`, raised by the RWA verifier. The log line is the evidence that
the adapter does its job: the RWA side signals failure by **panicking**, the token's `Policy`
expects a **boolean**, and a panic crossing a cross-contract call would abort the whole
transaction instead of letting the token reject the operation cleanly. `velum-policy` calls
through the generated client's `try_` variant and folds the trap into `false`.

The distinction that matters for a regulated fund: Bob is not refused because he is absent from
a list. He is refused because he carries no valid claim from an approved issuer — and the same
registry answers for the public asset and the confidential wrapper.

### Through the token, not just the interface

`scripts/demo-gate.ts` has both wallets attempt the same operation — `register` — on the
identity-gated token above:

```
token (policy-gated) = CBDT4EKUF66MS7HHDHMLDPDI7TOPZCV7AYYLC53ES7TEB67KAT3BFWV5

[velum-alice] KYC claim from an approved issuer
  ✅ accepted — tx d9a1a33cdadebd9f440c958a5557e29c7e030ad411e84335cb0307da1ab78fd7

[velum-bob] no identity registered
  ⛔ refused by policy — Error(Contract, #3602)
```

`3602` is `NotAuthorizedByPolicy`. Note what it is not: Bob produced a **valid zero-knowledge
proof** for the register circuit, and it never mattered. Identity is checked before the proof is
considered, so cryptographic correctness cannot buy entry to a regulated asset.

The token was created through upstream's own factory (`deploy_compliant_token`) with our policy
address; the deployment event records `policy = CCCQ7Z6F…OXQXDK, sac_passthrough: true`. Nothing
upstream was modified to make this work.

### Three distinct outcomes, all on the gated token

The same probe, three states of the world:

| Wallet / state | Result |
|---|---|
| Alice — KYC claim, not frozen | accepted (`register` tx `d9a1a33c…8fd7`; on repeat runs, a policy-gated deposit) |
| Alice — **frozen by the issuer** | `#3601 AccountFrozen` |
| Bob — no identity | `#3602 NotAuthorizedByPolicy` |

Freeze was exercised end to end: `freeze(velum-alice)` emitted `Frozen`, `is_frozen` returned
`true`, her next gated operation failed with 3601 — distinguishable from a policy refusal — and
`unfreeze` restored her. The issuer control and the identity gate are independent and both work.

### A demo bug worth recording

The first version of `demo-gate.ts` was not idempotent, and worse, it misattributed the failure.
On a second run Alice fails with `#3500 AccountAlreadyRegistered`, and the script's catch-all
labelled every failure "refused by policy" — so a judge running it twice would have seen our own
gate appear to reject an authorized wallet. Fixed: the script probes with `register` when the
account is new and with a policy-gated `deposit` when it is not, and it names the actual error
code in every branch.

## 3. Circuits

| Package | Tests | Cost | Proof |
|---|---|---|---|
| `circuits/disclose_balance_ge` | 11 ✅ | — | 14 592 B · 6 public inputs · 0.25 s (CLI) / 3.81 s (bb.js, in-process) |
| `circuits/seize` | 12 ✅ | 93 ACIR opcodes | 14 592 B · 0.33 s · verified |
| `experiments/clawback-poc` | 9 ✅ | — | premise verification, no circuit |
| `experiments/circuit-cap-poc` | 34 ✅ | 133 → 137 opcodes (+3 %) | patch against upstream's transfer circuit |

**66 tests, all passing.**

`disclose_balance_ge` implements `SELECTIVE_DISCLOSURE.md` §9 (constraints D1, D2, DB3, D5, DB4),
plus one constraint beyond the spec: DB4b range-checks the threshold, so a malformed public input
cannot make the predicate vacuous.

`seize` (Z1–Z7) answers upstream's open question on individual clawback: it opens both
commitments, bounds `alpha <= v_s + v_r`, and writes the post-seizure state under the protocol's
canonical derivations, so the holder's wallet keeps working afterwards.

---

## 4. Contracts

**`velum-policy`** — implements the confidential token's `Policy` trait by delegating to the RWA
`IdentityVerifier`. The two interfaces disagree on failure signalling: RWA panics, the token
expects a boolean. The call goes through the generated client's `try_` variant, folding the error
into `false`; a panic crossing a cross-contract call would abort the transaction instead of
letting the token reject cleanly.

**`velum-attest`** — verifies `disclose_balance_ge` proofs on-chain and records
`Attestation { threshold, attested_at_ledger }`. It runs its own single-entry VK registry, because
upstream's `CircuitType` enum is closed and carries no disclosure variant. `addr_f` is pinned at
construction: the token keeps it in instance storage and `address_to_field` is `pub(crate)`, so a
third-party verifier can neither read nor recompute it (§6, finding 1). It is still not
prover-supplied, so the trust boundary holds.

No authorization is required to submit an attestation: D1/D2 bind the proof to the account's own
viewing key, so relaying a valid proof only records a fact that account could have recorded itself.

---

## 5. Two failures worth recording

Both cost real time and neither is in any documentation.

### 5.1 The verification key had the wrong shape (error 3403)

The first attestation attempt failed with `Error(Contract, #3403)` —
`InvalidVerificationKey`. A VK produced by `bb write_vk` measured **1764 bytes**; every VK
committed in the demo measures **1760**.

Generating a VK for upstream's own `register` circuit with our toolchain and diffing byte by byte
located the difference exactly: **4 bytes inserted at offset 32**, holding the public-input count
(`00000005` for register, `00000006` for ours). `ours[:32] + ours[36:]` reproduces the committed
artifact exactly.

### 5.2 …and stripping those bytes was the wrong fix (error 2)

With the trimmed VK the contract stopped rejecting the key and started rejecting the proof
(`ProofRejected`). Verifying the trimmed VK locally explained why:

```
Reason : Not enough public inputs to extract pairing points
```

The real difference was never the byte layout. The on-chain verifier consumes **keccak-transcript**
proofs; the `bb` CLI defaults to a different transcript. Same circuit, same bb version, artifacts
that parse and then fail.

The fix removed the CLI from the path entirely: `scripts/demo-attest.ts` drives our circuit through
the SDK's `CircuitProver`, the same prover the token uses, and takes the VK from
`prover.verificationKey()`. Both are keccak by construction. **Consequence for anyone building on
this: derive the VK from the same prover that will generate the proofs, never from the CLI.**

---

## 6. Findings reported upstream

Five, all with reproduction.

1. **`addr_f` is not readable by third parties.** It lives in the token's instance storage and
   `address_to_field` is `pub(crate)`. §5.3 of the disclosure spec lists it as "recomputed from the
   token contract address", which no third-party contract can do. A public `address_as_field()`
   accessor would fix it.
2. **A documented command that cannot run.** `examples/rwa/sign-claim` sits in the workspace
   `exclude` set while declaring `authors.workspace = true`; the README's `cargo run
   --manifest-path` fails with *"failed to find a workspace root"*.
3. **`--optimize=false` is incompatible with stellar-cli ≥ 25.2**, which treats `--optimize` as a
   boolean flag. The demo's deploy script fails at the first contract.
4. **`examples/rwa/README.md` documents an impossible `initial_profiles` format.** The parameter is
   `Vec<Val>` — type-erased in the contract spec — so the CLI requires raw XDR-JSON. The README's
   human-readable form is a two-key map and collides with `ScVal`'s externally-tagged serde,
   producing *"invalid value: map, expected map with a single key"*. Working payload:
   ```json
   [{"map":[{"key":{"symbol":"country"},"val":{"vec":[{"symbol":"Individual"},
   {"vec":[{"symbol":"Residence"},{"u32":76}]}]}},{"key":{"symbol":"metadata"},"val":"void"}]}]
   ```
5. **`identity-registry` hardcodes `IdentityType::Individual`** in `add_identity`, so a
   `CountryRelation::Organization` profile is stored as a natural person.
6. **A required claim topic with no trusted issuer is silently ignored.** `verify_identity`
   iterates `(topic, issuers)` pairs; a topic whose issuer list is empty never enters the inner
   loop, so it never raises. An operator who registers a topic to tighten the rules — and forgets
   the issuer — gets **silent non-enforcement**, with no error and no event to notice. Verified
   both ways on testnet: topic 2 registered alone left an unqualified holder authorized; the same
   topic with the issuer trusted for it flipped that holder to refused.

---

## 6.1 Regulatory profile

`profiles/cvm175.json` expresses the jurisdiction as configuration. Audited against what is
actually enforced, which turned up an overclaim of our own: the minimum position was marked
`enforced`. It is not — it is **attestable**. A holder proves it and a contract records it, but
nothing compels the holder to attest and no operation is blocked for its absence; a consumer
decides what to require. Enforcing it inside a transfer needs the rule in the circuit
(`experiments/circuit-cap-poc`). The field now reads `enforced: false, attestable: true`, and
every claim carries `verified_on_testnet` where we exercised it.

## 6.2 Seals, and one we had not earned

Every claim in the profile now carries `verified_on_testnet` only where we exercised it. Two
corrections came out of the audit:

- **`sac_passthrough` lost its seal.** It is configured — the deployment event records it — but
  its effect cannot be exercised here: the underlying is the native XLM SAC, which has no admin
  and whose `authorized()` is always `true`, so no issuer can deauthorize anyone. Testing the
  cascade needs an underlying with a real issuer. We had marked it verified on the strength of the
  configuration event, which is exactly the mistake this section exists to prevent.
- **Claim topic 2 earned one.** Not because it is active — it is not — but because we proved the
  switch works, in both directions, and restored the state afterwards.

## 6.3 The silent-non-enforcement footgun, and our fix

Finding 6 above is not just a report: `velum-policy` now defends against it. Before delegating,
the adapter reads the topic/issuer map and returns `false` if any registered topic has no issuer.
A deployment in that state is not permissive, it is **unconfigured**, and a compliance gate that
cannot tell the difference should reject.

Demonstrated A/B against the same chain state — topic 2 registered, no issuer bound to it:

| Policy | `is_authorized(alice)` | Meaning |
|---|---|---|
| v1, `CCCQ7Z6F…QXDK` | `true` | the topic is silently unenforced; the holder passes a check that never ran |
| v2, `CDJET5BV…FPKV` | `false` | refuses, because the registry cannot answer what it claims to enforce |

With the registry correctly configured, both return `true` — the guard costs nothing in the
healthy case. State was restored after the test, and the gated token now points at v2
(`ComplianceConfigChanged`); `demo-gate.ts` reproduces unchanged.

**The cost:** two extra cross-contract reads per authorization, on every gated operation. For a
gate whose failure mode is silent under-enforcement, that is the right side to err on. A
deployment that wants the cheaper path can move the check to configuration time — at the price of
going stale when the registry changes.

## 6.4 Wall-clock cost of the demos

Measured end to end on testnet, because it changes how the demo can be presented:

| Script | Real time | Where it goes |
|---|---|---|
| `demo-attest.ts` | **3 m 39 s** | transaction confirmation — register, deposit, merge, attest |
| `demo-gate.ts` | **1 m 55 s** | same |
| the proof itself | **2.06 s** | the fast part |

Proving is not the bottleneck; testnet confirmation is. A three-minute video cannot run both live,
so `docs/VIDEO-SCRIPT.md` records each separately and speeds up the waiting visibly rather than
cutting it — the honest edit, not the flattering one.

## 7. Toolchain

`nargo 1.0.0-beta.11` · `bb 0.87.0` (CLI, for local circuit work only) · `@aztec/bb.js 0.87.0`
(the prover that matters — keccak transcript) · `stellar-cli 25.2.0` · Rust + `wasm32v1-none` ·
soroban-sdk `=26.1.0` · OpenZeppelin `stellar-contracts` rev `539968f`.

Noir rejects non-ASCII source, comments included.

Reproduction steps: `circuits/README.md` for the circuits, and for the on-chain demo:

```bash
cd refs/ct-demo/packages/sdk
VELUM_ATTEST=<contract-id> pnpm exec tsx ../../../../scripts/demo-attest.ts
```

Run without `VELUM_ATTEST` to print the verification key needed to deploy `velum-attest`.

---

## 8. What is not done

- The clawback migration (register-circuit escrow, new VK, re-registration) is designed and
  priced in the whitepaper §11.6, not built.
- Aggregates across accounts — concentration by tranche, subordination ratio — remain open.

Testnet only. The UltraHonk verifier is developer preview and unaudited.
