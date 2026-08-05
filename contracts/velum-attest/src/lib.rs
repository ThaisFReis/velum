//! Velum attestation — **on-chain** verification of a confidential-position
//! predicate.
//!
//! A holder proves *"my confidential position is at least `threshold`"* and this
//! contract checks it on-chain. Nothing is revealed: the proof carries no
//! ciphertext and there is nothing to decrypt. What lands in storage is a
//! boolean fact plus the ledger it was established at.
//!
//! Upstream verifies disclosure proofs **entirely off-chain**
//! (`SELECTIVE_DISCLOSURE.md` §15.1) and marks the on-chain verifier out of
//! scope (§§5.4, 14). The predicate form has no recipient binding, so it is the
//! shape an on-chain verifier consumes directly — this contract is that
//! verifier, paired with the `disclose_balance_ge` circuit in `circuits/`.
//!
//! ## Why this exists
//!
//! The confidential token's `Policy` interface answers one question about an
//! address and sees no values, because balances are Pedersen commitments. So
//! *quantitative* compliance — qualified-investor minimum, concentration cap —
//! cannot be enforced there. Nor can a transfer's sender prove anything about
//! the recipient's balance: it has no opening for it. The holder does. This
//! contract is where the holder's own proof becomes a fact other contracts can
//! read.
//!
//! ## Trust boundary (`SELECTIVE_DISCLOSURE.md` §5.2)
//!
//! Soundness rests on the prover supplying **only** the proof. Every public
//! input is sourced elsewhere:
//!
//! | Public input | Source |
//! |---|---|
//! | `PVK_A`, `C_spend` | read cross-contract from the confidential token, live |
//! | `addr_f` | pinned at construction (see below) |
//! | `v_threshold` | this contract's regulatory profile, owner-managed |
//!
//! A caller passing its own commitment would simply verify against a blob this
//! contract never assembles.
//!
//! **Upstream gap worth a PR:** `addr_f` lives in the token's instance storage
//! and `address_to_field` is `pub(crate)`, so a third-party verifier can neither
//! read nor recompute it. It is pinned here at construction instead — still not
//! prover-supplied, so the boundary holds, but a public `address_as_field()`
//! getter on `ConfidentialToken` would let this be read live like the rest.
//!
//! ## Freshness
//!
//! `C_spend` is read from live chain state, so a proof stops verifying the
//! moment the balance moves. An attestation is therefore a statement about the
//! position *as of* `attested_at_ledger`, and consumers that need a current
//! answer should re-attest rather than trust an old record.
//!
//! # ⚠️ Not Production Ready
//!
//! Built on the confidential-token developer preview; the UltraHonk backend and
//! the circuits are unaudited. Testnet only.

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

/// Slot this contract keeps its own verification key in.
///
/// `CircuitType` is upstream's closed enum for the token's six transaction
/// circuits and has no disclosure variant. The registry it keys, however, is
/// plain per-contract storage — so this contract runs its own one-entry
/// registry and the variant name carries no meaning beyond "the slot".
/// Registering a disclosure VK here never reaches the token's registry, which
/// lives in the token's own storage.
const DISCLOSE_BALANCE_GE: CircuitType = CircuitType::Register;

#[contracttype]
pub enum VelumAttestKey {
    /// Confidential token whose account records back every attestation.
    Token,
    /// `addr_f` of that token (see the module note on why it is pinned).
    AddrF,
    /// Current regulatory floor, as a canonical 32-byte field element.
    Threshold,
    /// Per-account attestation record.
    Attestation(Address),
}

/// A verified statement that an account's confidential position cleared the
/// floor that was in force at `attested_at_ledger`.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Attestation {
    /// The floor the proof was checked against.
    pub threshold: BytesN<32>,
    /// Ledger at which the proof verified. The position may have moved since.
    pub attested_at_ledger: u32,
}

#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
#[repr(u32)]
pub enum VelumAttestError {
    /// The proof did not verify against the assembled public inputs.
    ProofRejected = 2,
    /// A value read on-chain is not a canonical Bn254 field representative.
    NonCanonicalEncoding = 3,
    /// No attestation on record for this account.
    NotAttested = 4,
    /// A negative threshold cannot be encoded as a field element.
    NegativeThreshold = 5,
}

/// Emitted when a position proof verifies.
#[contractevent]
pub struct PositionAttested {
    #[topic]
    pub account: Address,
    pub threshold: BytesN<32>,
    pub ledger: u32,
}

/// Emitted when the owner moves the regulatory floor.
#[contractevent]
pub struct ThresholdSet {
    pub threshold: BytesN<32>,
}

#[contract]
pub struct VelumAttestContract;

#[contractimpl]
impl VelumAttestContract {
    /// Wires the contract to a confidential token and a regulatory floor.
    ///
    /// * `token` — the confidential token whose `confidential_balance` records
    ///   supply `PVK_A` and `C_spend`.
    /// * `addr_f` — that token's address-as-field element.
    /// * `vk` — UltraHonk verification key for `disclose_balance_ge`.
    /// * `threshold` — initial floor, in the underlying asset's units.
    pub fn __constructor(
        e: &Env,
        owner: Address,
        token: Address,
        addr_f: BytesN<32>,
        vk: Bytes,
        threshold: i128,
    ) {
        if !Grumpkin::is_canonical_field(&addr_f) {
            panic_with_error!(e, VelumAttestError::NonCanonicalEncoding);
        }
        set_owner(e, &owner);
        let s = e.storage().instance();
        s.set(&VelumAttestKey::Token, &token);
        s.set(&VelumAttestKey::AddrF, &addr_f);
        vk_registry::register_verification_key(e, DISCLOSE_BALANCE_GE, &vk);
        s.set(&VelumAttestKey::Threshold, &encode_threshold(e, threshold));
    }

    /// Verifies a `disclose_balance_ge` proof and records the attestation.
    ///
    /// The caller supplies **only** `proof`; every public input is assembled
    /// here from the token's live state and this contract's profile. On success
    /// the attestation replaces any previous one for `account`.
    ///
    /// No authorization is required: a proof is self-authenticating — D1/D2 bind
    /// it to the account's own viewing key, so nobody can produce one for an
    /// account they do not control, and submitting a valid proof on someone's
    /// behalf only records a fact that account could have recorded itself.
    ///
    /// # Errors
    ///
    /// * [`VelumAttestError::ProofRejected`] — the predicate does not hold, the
    ///   proof is malformed, or it was made against different state.
    pub fn attest_position(e: &Env, account: Address, proof: Bytes) -> Attestation {
        let s = e.storage().instance();
        let token: Address = s.get(&VelumAttestKey::Token).unwrap();
        let addr_f: BytesN<32> = s.get(&VelumAttestKey::AddrF).unwrap();
        let threshold: BytesN<32> = s.get(&VelumAttestKey::Threshold).unwrap();

        // Live account record: the prover contributes nothing here.
        let record = ConfidentialTokenClient::new(e, &token).confidential_balance(&account);

        // Public-input order mirrors `circuits/disclose_balance_ge/src/main.nr`:
        //   addr_f, PVK_A.x, PVK_A.y, C_spend.x, C_spend.y, v_threshold
        // A Grumpkin `Point` is `BytesN<64>` laid out `be(x) || be(y)`, so
        // appending the point yields its two coordinates in order. 192 bytes.
        let mut pi = Bytes::new(e);
        pi.append(&Bytes::from(addr_f));
        append_point(e, &mut pi, &record.viewing_public_key);
        append_point(e, &mut pi, &record.spendable_balance);
        pi.append(&Bytes::from(threshold.clone()));

        if !vk_registry::verify_proof(e, DISCLOSE_BALANCE_GE, &pi, &proof) {
            panic_with_error!(e, VelumAttestError::ProofRejected);
        }

        let ledger = e.ledger().sequence();
        let attestation = Attestation { threshold: threshold.clone(), attested_at_ledger: ledger };
        e.storage()
            .persistent()
            .set(&VelumAttestKey::Attestation(account.clone()), &attestation);

        PositionAttested { account, threshold, ledger }.publish(e);
        attestation
    }

    /// Returns the recorded attestation, or panics when there is none.
    pub fn attestation(e: &Env, account: Address) -> Attestation {
        e.storage()
            .persistent()
            .get(&VelumAttestKey::Attestation(account))
            .unwrap_or_else(|| panic_with_error!(e, VelumAttestError::NotAttested))
    }

    /// Whether `account` has an attestation on record. Consumers that care about
    /// staleness should read [`attestation`] and judge `attested_at_ledger`.
    ///
    /// [`attestation`]: VelumAttestContract::attestation
    pub fn is_attested(e: &Env, account: Address) -> bool {
        e.storage()
            .persistent()
            .has(&VelumAttestKey::Attestation(account))
    }

    /// The floor currently in force.
    pub fn threshold(e: &Env) -> BytesN<32> {
        e.storage().instance().get(&VelumAttestKey::Threshold).unwrap()
    }

    /// The confidential token this contract reads account records from.
    pub fn token(e: &Env) -> Address {
        e.storage().instance().get(&VelumAttestKey::Token).unwrap()
    }

    /// Moves the regulatory floor.
    ///
    /// Past attestations keep the threshold they were verified against, so
    /// raising the floor does not silently upgrade old records — consumers
    /// compare the attestation's own threshold against what they require.
    #[only_owner]
    pub fn set_threshold(e: &Env, threshold: i128, _operator: Address) {
        let encoded = encode_threshold(e, threshold);
        e.storage().instance().set(&VelumAttestKey::Threshold, &encoded);
        ThresholdSet { threshold: encoded }.publish(e);
    }
}

#[contractimpl(contracttrait)]
impl Ownable for VelumAttestContract {}

/// Appends a Grumpkin point, rejecting non-canonical coordinates for the same
/// reason upstream does: a non-canonical encoding is a different field element
/// than the circuit witnessed.
fn append_point(e: &Env, pi: &mut Bytes, p: &BytesN<64>) {
    if !Grumpkin::is_canonical_point(p) {
        panic_with_error!(e, VelumAttestError::NonCanonicalEncoding);
    }
    pi.append(&Bytes::from(p.clone()));
}

/// Encodes a non-negative `i128` as a canonical 32-byte big-endian field
/// element: 16 zero bytes followed by the amount's big-endian bytes.
fn encode_threshold(e: &Env, threshold: i128) -> BytesN<32> {
    if threshold < 0 {
        panic_with_error!(e, VelumAttestError::NegativeThreshold);
    }
    let mut out = [0u8; 32];
    out[16..].copy_from_slice(&threshold.to_be_bytes());
    BytesN::from_array(e, &out)
}
