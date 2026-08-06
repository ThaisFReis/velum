//! Velum seize — **on-chain verification** of an individual-clawback proof.
//!
//! This contract verifies the `seize` circuit (`circuits/seize`, constraints Z1–Z7) against live
//! token state and records the verdict. It answers one question, and it is worth being exact
//! about which: *does a valid proof exist that this account's confidential position can absorb a
//! seizure of `alpha`, and that the post-seizure state was written under the protocol's canonical
//! derivations?*
//!
//! # What this contract is NOT
//!
//! **It does not move value, and it does not rewrite the token's state.** It cannot: the
//! commitments live in the confidential token's storage, and only that contract can write them.
//! Executing a seizure needs a `seize` entry point inside the token itself — a fork we did not
//! make. What runs here is the verification half, which is the half that was in doubt.
//!
//! **The escrow it presumes does not exist yet.** The circuit takes the holder's viewing key `vk`
//! as a private witness. For an auditor to hold `vk` without the holder's cooperation — the whole
//! point of a clawback — registration must escrow it (whitepaper §11.3: constraints R6–R8 on
//! upstream's register circuit). That is a breaking change requiring every account to re-register,
//! and it is not built. In this deployment the witness comes from a test account whose keys we
//! control, so what is demonstrated is that **the circuit verifies on-chain**, not that a
//! non-cooperating holder can be seized from today.
//!
//! Stating that plainly is the point. A verifier that runs is evidence; calling it a working
//! clawback would not be.
//!
//! # Trust boundary
//!
//! | Public input | Source | Why it is trustworthy |
//! |---|---|---|
//! | `PVK_A`, `C_spend`, `C_receive` | read cross-contract from the token, live | the prover cannot substitute another account's state |
//! | `alpha`, `sigma_new` | the seizure authority, admin-gated | a policy decision, public by design — the amount seized belongs on the ledger |
//! | `C_spend_new`, `b_tilde_new` | supplied with the proof | constrained by Z6/Z7 to equal `remaining` under the canonical derivations, so a lying authority can neither short-change the holder nor desynchronise its wallet |
//!
//! There is no `addr_f` among the public inputs, and none is needed: `PVK_A = vk · H` where
//! `vk = Poseidon2(δ_vk, sk, addr_f)` is contract-bound, so a proof built against one token's
//! account cannot verify against another token's record.
//!
//! # ⚠️ Not Production Ready
//!
//! Developer-preview primitives, unaudited verifier. Testnet only.

#![no_std]

use soroban_sdk::{
    contract, contracterror, contractevent, contractimpl, contracttype, panic_with_error, Address,
    Bytes, BytesN, Env,
};
use stellar_access::ownable::{set_owner, Ownable};
use stellar_contract_utils::crypto::grumpkin::Grumpkin;
use stellar_macros::only_owner;
use stellar_tokens::confidential::{
    verifier::{storage as vk_registry, CircuitType},
    ConfidentialTokenClient,
};

/// Slot this contract keeps its own verification key in. `CircuitType` is upstream's closed enum
/// for the token's transaction circuits and has no seize variant; the registry it keys is plain
/// per-contract storage, so this contract runs a one-entry registry of its own and the variant
/// name carries no meaning beyond "the slot".
const SEIZE: CircuitType = CircuitType::Register;

#[contracttype]
pub enum VelumSeizeKey {
    /// Confidential token whose account records back every verification.
    Token,
    /// Per-account record of the last verified seizure proof.
    Verified(Address),
}

/// A verified statement that a seizure of `amount` was provable against the account's position
/// as it stood at `verified_at_ledger`.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SeizeVerdict {
    /// The seized amount, public by design.
    pub amount: i128,
    /// Nonce the post-seizure state was written under.
    pub sigma_new: BytesN<32>,
    /// Ledger at which the proof verified against live state.
    pub verified_at_ledger: u32,
}

#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
#[repr(u32)]
pub enum VelumSeizeError {
    /// The proof did not verify against the assembled public inputs.
    ProofRejected = 1,
    /// A value read on-chain is not a canonical Bn254 field representative.
    NonCanonicalEncoding = 2,
    /// No verdict on record for this account.
    NotVerified = 3,
    /// A negative seizure amount cannot be encoded as a field element.
    NegativeAmount = 4,
}

/// Emitted when a seizure proof verifies. The amount is deliberately in the clear: a seizure the
/// ledger cannot see is not a seizure a regulator can audit.
#[contractevent]
pub struct SeizureProven {
    #[topic]
    pub account: Address,
    pub amount: i128,
    pub ledger: u32,
}

#[contract]
pub struct VelumSeizeContract;

#[contractimpl]
impl VelumSeizeContract {
    /// * `owner` — the seizure authority; only it may submit proofs.
    /// * `token` — the confidential token whose records supply the account state.
    /// * `vk` — UltraHonk verification key for `circuits/seize`.
    pub fn __constructor(e: &Env, owner: Address, token: Address, vk: Bytes) {
        set_owner(e, &owner);
        e.storage().instance().set(&VelumSeizeKey::Token, &token);
        vk_registry::register_verification_key(e, SEIZE, &vk);
    }

    /// Verifies a seizure proof against the account's live commitments.
    ///
    /// Owner-gated, unlike `velum-attest`: a position attestation is self-authenticating and
    /// harmless to relay, whereas a seizure is an assertion *about* someone by an authority. The
    /// gate does not make the proof any more valid — it records who claimed it.
    ///
    /// # Errors
    ///
    /// * [`VelumSeizeError::ProofRejected`] — `alpha` exceeds the position, the post-seizure state
    ///   does not follow the canonical derivations, or the witness belongs to another account.
    #[only_owner]
    pub fn verify_seizure(
        e: &Env,
        account: Address,
        amount: i128,
        sigma_new: BytesN<32>,
        c_spend_new: BytesN<64>,
        b_tilde_new: BytesN<32>,
        proof: Bytes,
        _operator: Address,
    ) -> SeizeVerdict {
        if amount < 0 {
            panic_with_error!(e, VelumSeizeError::NegativeAmount);
        }
        let token: Address = e.storage().instance().get(&VelumSeizeKey::Token).unwrap();
        let record = ConfidentialTokenClient::new(e, &token).confidential_balance(&account);

        // Public-input order mirrors circuits/seize/src/main.nr:
        //   PVK_A, C_spend, C_receive, alpha, sigma_new, C_spend_new, b_tilde_new
        // A Grumpkin point is BytesN<64> laid out be(x) || be(y), so appending a point yields its
        // two coordinates in order. 11 field elements, 352 bytes.
        let mut pi = Bytes::new(e);
        append_point(e, &mut pi, &record.viewing_public_key);
        append_point(e, &mut pi, &record.spendable_balance);
        append_point(e, &mut pi, &record.receiving_balance);
        pi.append(&Bytes::from(encode_amount(e, amount)));
        append_field(e, &mut pi, &sigma_new);
        append_point(e, &mut pi, &c_spend_new);
        append_field(e, &mut pi, &b_tilde_new);

        if !vk_registry::verify_proof(e, SEIZE, &pi, &proof) {
            panic_with_error!(e, VelumSeizeError::ProofRejected);
        }

        let ledger = e.ledger().sequence();
        let verdict = SeizeVerdict { amount, sigma_new, verified_at_ledger: ledger };
        e.storage()
            .persistent()
            .set(&VelumSeizeKey::Verified(account.clone()), &verdict);

        SeizureProven { account, amount, ledger }.publish(e);
        verdict
    }

    /// Returns the recorded verdict, or panics when there is none.
    pub fn verdict(e: &Env, account: Address) -> SeizeVerdict {
        e.storage()
            .persistent()
            .get(&VelumSeizeKey::Verified(account))
            .unwrap_or_else(|| panic_with_error!(e, VelumSeizeError::NotVerified))
    }

    /// The confidential token this contract reads account records from.
    pub fn token(e: &Env) -> Address {
        e.storage().instance().get(&VelumSeizeKey::Token).unwrap()
    }
}

#[contractimpl(contracttrait)]
impl Ownable for VelumSeizeContract {}

fn append_point(e: &Env, pi: &mut Bytes, p: &BytesN<64>) {
    if !Grumpkin::is_canonical_point(p) {
        panic_with_error!(e, VelumSeizeError::NonCanonicalEncoding);
    }
    pi.append(&Bytes::from(p.clone()));
}

fn append_field(e: &Env, pi: &mut Bytes, f: &BytesN<32>) {
    if !Grumpkin::is_canonical_field(f) {
        panic_with_error!(e, VelumSeizeError::NonCanonicalEncoding);
    }
    pi.append(&Bytes::from(f.clone()));
}

/// Encodes a non-negative `i128` as a canonical 32-byte big-endian field element.
fn encode_amount(e: &Env, amount: i128) -> BytesN<32> {
    let mut out = [0u8; 32];
    out[16..].copy_from_slice(&amount.to_be_bytes());
    BytesN::from_array(e, &out)
}
