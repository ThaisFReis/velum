# Velum

> **Holder-attested compliance for Confidential Tokens on Stellar.**
> A regulated fund can hide its register of holders — and still prove it obeys the rules.
> Without revealing the amount to anyone. Including the verifier.

Submission to the **Stellar Summit SP 2026** (GrantFox), sub-lane **Enterprise, Compliance & RWA**
(OpenZeppelin + Nethermind). Live on testnet · MIT · [whitepaper](docs/Velum-Whitepaper-v0.1.pdf) ·
[one page](docs/Velum-OnePage.pdf) · [deck](docs/Velum-Deck.pdf)

---

## The problem

Compliance asks two questions of a fund's register. OpenZeppelin's `stellar-contracts` ships the
primitives for both, wired to neither.

| The question | Upstream today | Velum |
|---|---|---|
| **Who may hold?** | A flat **address allowlist**. No reason, no expiry, no attesting party — insufficient for a securities regime. Bridging to the RWA identity registry is their issue **#766**, open since 2026-07-06. | `velum-policy` — the token's authorization gate asks an **ERC-3643/T-REX identity registry**: does this holder carry a valid claim from an approved issuer? |
| **How much may they hold?** | **Structurally impossible.** `is_authorized(account, token) -> bool` receives an address and never a value, because balances are Pedersen commitments. The RWA modules that enforce caps demand cleartext `amount: i128`. The two cannot meet. | `disclose_balance_ge` + `velum-attest` — the **holder** proves *"my position ≥ T"* and a Soroban contract verifies it on-chain. Nothing is decrypted; there is nothing to decrypt. |

Under FHE a contract compares ciphertexts with no witness, so the check fits inside the transfer.
Under Pedersen commitments a proof *needs* a witness — and for any balance, exactly one party holds
it. So the check has to move: quantitative compliance cannot be transaction-gated, it must be
**holder-attested**. That argument, with its evidence, is the whitepaper.

---

## What is ours, and what is not

Velum runs on an **unmodified** upstream token. Nothing in `stellar-contracts` or in the reference
demo was patched to make this work.

**Ours** — everything in this repository:

| Component | What it is |
|---|---|
| `contracts/velum-policy` | Adapter: the token's `Policy` gate → the RWA `IdentityVerifier`. Also **fails closed** on a registry misconfiguration upstream ignores silently (finding 6). |
| `contracts/velum-attest` | On-chain verifier for position proofs — a component upstream's spec marks *out of scope* (§§5.4, 14). |
| `circuits/disclose_balance_ge` | The predicate circuit upstream **specifies** (`SELECTIVE_DISCLOSURE.md` §9) **and does not ship**. No public implementation exists in any repository, branch, tag or history — see [provenance](docs/WHITEPAPER.md). We bind `C_receive` as well, which the spec omits — finding 7. |
| `circuits/seize` + `contracts/velum-seize` | Answers upstream's open question on individual clawback: premise verified, circuit built, and a partial seizure **verified on-chain** — bounded by a position the ledger never reveals. |
| `experiments/` | Two research artifacts: the clawback premise, and a quantitative rule inside upstream's transfer circuit (+3 % cost). |
| `profiles/cvm175.json` | A jurisdiction as configuration — claim topics, thresholds, issuer controls — annotated with what is actually enforced and what is merely declared. |
| `scripts/` | The two demos below. |

**Theirs** — consumed as dependencies, never vendored into this repo: the Confidential Token, the
RWA/T-REX module, the UltraHonk verifier, and the reference demo's SDK. Study clones live in
`refs/` and are **git-ignored**, so nothing in this repository is someone else's code.

---

## Live on testnet

| Contract | Address |
|---|---|
| `velum-attest` | `CBCBSILY5B562Q263W4EDYU7IHBV3SSM3IFWA333MII3OK3QRGNCDXKY` |
| `velum-seize` | `CDVV37Y766VSLNRRIHRXBTUCEN7UJU7QQVROLWYVA6L7FRTKJO3Z2LE5` |
| `velum-policy` | `CDJET5BV36RDRNCNCNXJFYWUKPCX4VWXTUY4EGU4W5VUJ3FHLHIYFPKV` |
| identity-gated confidential token | `CBDT4EKUF66MS7HHDHMLDPDI7TOPZCV7AYYLC53ES7TEB67KAT3BFWV5` |

Two transactions worth opening:

- **A position proved on-chain** — [`f8ff2951…c13267`](https://stellar.expert/explorer/testnet/tx/f8ff2951ad2277d4337b590842762a60ee46b8936d9c9014f5154a0918c13267).
  A contract read the holder's commitment and viewing key from the token, the threshold from its own
  profile, verified an UltraHonk proof, and recorded that the position clears 500 000 — without the
  amount appearing anywhere.
- **A seizure proved on-chain** — [`282a2947…8c4cd`](https://stellar.expert/explorer/testnet/tx/282a2947b2998b2b2de56c9727d0a151d8aa0a9f8e55d10014e915309be8c4cd).
  An authority proved a seizure of 250 000 fits inside a confidential position, against commitments
  read live from the token. The ledger records the amount seized and never the position. No value
  moves and the key escrow is simulated — the caveats are in the contract's own module docs.
- **A wallet accepted by identity** — [`d9a1a33c…b78fd7`](https://stellar.expert/explorer/testnet/tx/d9a1a33cdadebd9f440c958a5557e29c7e030ad411e84335cb0307da1ab78fd7).
  The wallet without a claim gets `#3602 NotAuthorizedByPolicy` instead.

Every address, hash and console output: **[`docs/IMPLEMENTATION.md`](docs/IMPLEMENTATION.md)**.

---

## Run it yourself

```bash
# toolchain
noirup --version 1.0.0-beta.11        # nargo
bbup -v 0.87.0                        # bb (local circuit work only)
# plus: stellar-cli >= 25.2, Rust with wasm32v1-none, Node >= 20, pnpm 10

# circuits — 69 tests across four packages
cd circuits/disclose_balance_ge && nargo test      # 14
cd ../seize && nargo test                          # 12
cd ../../experiments/clawback-poc && nargo test    # 9

# the remaining 34 are two patches against upstream's transfer circuit, not a package:
cd refs/oz-stellar-contracts-main/packages/tokens/src/confidential/circuits/transfer
patch -p1 < ../../../../../../../../experiments/circuit-cap-poc/transfer-main.patch
patch -p1 < ../../../../../../../../experiments/circuit-cap-poc/transfer-tests.patch
nargo test && nargo info    # 34 tests, main goes 133 -> 137 ACIR opcodes; git checkout -- src/ to revert

# contracts
cd ../../contracts && stellar contract build

# the study clones the circuits path-depend on
git clone -b feat/confidential-verifier-ultrahonk \
  https://github.com/OpenZeppelin/stellar-contracts refs/oz-stellar-contracts-ct-branch
git clone https://github.com/brozorec/stellar-confidential-token-demo refs/ct-demo
cd refs/ct-demo && pnpm install && pnpm build:sdk
```

The two demos run against the deployed contracts above:

```bash
cd refs/ct-demo/packages/sdk

# position proved and verified on-chain, plus the false claim that cannot be built
VELUM_ATTEST=CBCBSILY5B562Q263W4EDYU7IHBV3SSM3IFWA333MII3OK3QRGNCDXKY \
  pnpm exec tsx ../../../../scripts/demo-attest.ts

# identity gating: one wallet with a claim, one without
VELUM_TOKEN=CBDT4EKUF66MS7HHDHMLDPDI7TOPZCV7AYYLC53ES7TEB67KAT3BFWV5 \
  pnpm exec tsx ../../../../scripts/demo-gate.ts

# a partial seizure proved against a position that stays unreadable
VELUM_SEIZE=CDVV37Y766VSLNRRIHRXBTUCEN7UJU7QQVROLWYVA6L7FRTKJO3Z2LE5 \
  pnpm exec tsx ../../../../scripts/demo-seize.ts

# nine adversarial probes: proof transplant, stale replay, alpha tampering, the owner gate
VELUM_ATTEST=CBCBSILY5B562Q263W4EDYU7IHBV3SSM3IFWA333MII3OK3QRGNCDXKY \
VELUM_SEIZE=CDVV37Y766VSLNRRIHRXBTUCEN7UJU7QQVROLWYVA6L7FRTKJO3Z2LE5 \
  pnpm exec tsx ../../../../scripts/stress.ts
```

> Run `demo-attest.ts` without `VELUM_ATTEST` and it prints the verification key needed to deploy
> your own `velum-attest`. **Derive that key from the same prover that will generate the proofs** —
> the CLI and the SDK use different transcripts, and mixing them fails only at verification time.
> That cost us an afternoon; §5 of the implementation record has the full diagnosis.

---

## Findings reported upstream

Seven, each with reproduction. Three are documentation or tooling; three are behavioural; one is a soundness gap in the specification itself.

1. **`addr_f` is not readable by third parties** — it lives in the token's instance storage and
   `address_to_field` is `pub(crate)`, so an external verifier can neither read nor recompute it,
   though the disclosure spec lists it as "recomputed from the token contract address".
2. **A documented command that cannot run** — `examples/rwa/sign-claim` is in the workspace
   `exclude` set while declaring `authors.workspace = true`.
3. **`--optimize=false` breaks on stellar-cli ≥ 25.2**, which treats `--optimize` as a flag.
4. **`examples/rwa/README.md` documents an impossible `initial_profiles` format** — the parameter is
   type-erased `Vec<Val>`, so the CLI requires raw XDR-JSON.
5. **`identity-registry` hardcodes `IdentityType::Individual`**, storing an organization as a
   natural person.
6. **A claim topic with no trusted issuer is silently ignored** — `verify_identity` skips it with no
   error and no event, so an operator who tightens the rules and forgets the issuer gets **no
   enforcement at all**. `velum-policy` fails closed on that state; the A/B demonstration is in the
   implementation record.
7. **`SELECTIVE_DISCLOSURE.md` §9 resolves only `C_spend`, which makes the specified
   `disclose_balance_le` evadable.** A confidential account holds value in two commitments;
   `C_receive` is not among the state the §9 verifier flow reads. For the `ge` shape this is sound
   but slack. For the `le` shape — introduced in the same sentence, as though a mirror image — it is
   a hole: a concentration ceiling is the obvious rule to build from it, and a holder can park value
   in `C_receive` and prove compliance while exceeding the cap. We bind both commitments; it costs
   43 → 67 ACIR opcodes.

## What we are not claiming

- **Not production.** Developer-preview primitives; the UltraHonk verifier is unaudited. Testnet
  only, no real value.
- **Not finished.** The clawback circuit verifies on-chain, but **no value moves** — executing a
  seizure needs an entry point inside the token contract, which we did not fork — and the key
  escrow it presumes (a register-circuit change plus re-registration) is designed and priced, not
  built. The on-chain demo simulates the escrow with a test account's keys.
- **Not solved.** Predicates over **encrypted aggregates across accounts** (concentration by
  tranche, subordination ratio between senior and subordinated) remain open, as far as we can
  determine on any chain.
- **Not invented.** We implement their specification. The novelty claim is bounded to what we can
  verify: no *public* implementation exists in any repository, branch, tag or history. Private work
  at OpenZeppelin cannot be excluded.

---

## Documents

| Doc | What it is |
|---|---|
| [`docs/Velum-Whitepaper-v0.1.pdf`](docs/Velum-Whitepaper-v0.1.pdf) | The thesis, architecture, evaluation, limits, and **Appendix A** sourcing every claim about upstream to a file and line |
| [`docs/IMPLEMENTATION.md`](docs/IMPLEMENTATION.md) | Addresses, hashes, console output, measured costs — and the failures that cost us time |
| [`docs/Velum-OnePage.pdf`](docs/Velum-OnePage.pdf) · [`docs/Velum-Deck.pdf`](docs/Velum-Deck.pdf) | One page; ten slides |
| [`circuits/README.md`](circuits/README.md) | Both circuits: constraints, results, reproduction |
| [`docs/REVISAO-ARQUITETURA-2026-08-06.md`](docs/REVISAO-ARQUITETURA-2026-08-06.md) | Architecture review: nine adversarial probes (9/9), and two findings that would bite on the next step |
| [`docs/SPIKE-CT-2026-08-04.md`](docs/SPIKE-CT-2026-08-04.md) | The de-risk that corrected our own first premise |

Anchor case: a Brazilian receivables fund (FIDC) under CVM 175 — **Plina Finance**. The kit serves
any regulated issuer facing the same paradox.
