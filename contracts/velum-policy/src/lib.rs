//! Velum identity policy — the bridge between the Confidential Token and the
//! RWA (T-REX) identity registry.
//!
//! The confidential token gates every state-changing operation through an
//! external [`Policy`] contract, asking a single question:
//!
//! ```text
//! fn is_authorized(account: Address, token: Address) -> bool
//! ```
//!
//! The reference policies that ship with the confidential-token demo answer it
//! from a **flat address list** (allowlist / blocklist). A regulated fund cannot:
//! an address on a list carries no reason, no expiry, and no issuer. What a
//! securities regulator asks is *"does this holder carry a valid claim — say,
//! qualified investor — attested by an approved issuer?"*, which is exactly what
//! the RWA module's [`IdentityVerifier`] answers.
//!
//! This contract is the adapter between the two. It is deliberately tiny: the
//! whole point is that the claim logic stays in the RWA registry (shared with the
//! public asset) and the confidentiality logic stays in the token. One KYC
//! registry then governs the public asset *and* the confidential wrapper.
//!
//! ## Impedance mismatch it resolves
//!
//! The two interfaces disagree on how failure is signalled:
//!
//! | Side | Signature | On failure |
//! |------|-----------|------------|
//! | RWA | `verify_identity(e, account)` | panics (`IdentityVerificationFailed`) |
//! | CT  | `is_authorized(e, account, token) -> bool` | returns `false` |
//!
//! A panic inside a cross-contract call would abort the whole transaction rather
//! than let the token reject the operation cleanly, so the call goes through the
//! generated client's `try_` variant and the error is folded into `false`.
//!
//! ## What this policy does NOT enforce
//!
//! `is_authorized` receives an address and nothing else — no amount, no balance.
//! Under a confidential token those values are Pedersen commitments, so *any*
//! quantitative rule (per-investor cap, minimum ticket, concentration limit) is
//! structurally out of reach at this interface. Identity, jurisdiction and
//! time-based rules are expressible here; amount-based rules need a
//! zero-knowledge predicate inside the transfer circuit — see
//! `experiments/circuit-cap-poc/`.
//!
//! # ⚠️ Not Production Ready
//!
//! Built on the confidential-token developer preview, whose UltraHonk verifier
//! and circuits are unaudited. Testnet only.

#![no_std]

use soroban_sdk::{contract, contractimpl, Address, Env};
use stellar_access::ownable::{set_owner, Ownable};
use stellar_macros::only_owner;
use stellar_tokens::{
    confidential::compliance::Policy,
    rwa::identity_verifier::IdentityVerifierClient,
};

/// Instance-storage keys.
#[soroban_sdk::contracttype]
pub enum VelumPolicyKey {
    /// Address of the RWA `IdentityVerifier` consulted on every check.
    IdentityVerifier,
}

#[contract]
pub struct VelumPolicyContract;

#[contractimpl]
impl VelumPolicyContract {
    /// Binds the identity verifier and sets the owner allowed to rotate it.
    ///
    /// * `owner` — authority allowed to call [`set_identity_verifier`].
    /// * `identity_verifier` — an RWA `IdentityVerifier` contract. The same
    ///   instance can back the public RWA token and any number of confidential
    ///   wrappers, which is what keeps one KYC registry authoritative.
    ///
    /// [`set_identity_verifier`]: VelumPolicyContract::set_identity_verifier
    pub fn __constructor(e: &Env, owner: Address, identity_verifier: Address) {
        set_owner(e, &owner);
        e.storage()
            .instance()
            .set(&VelumPolicyKey::IdentityVerifier, &identity_verifier);
    }

    /// Returns the identity verifier currently consulted.
    pub fn identity_verifier(e: &Env) -> Address {
        e.storage()
            .instance()
            .get(&VelumPolicyKey::IdentityVerifier)
            .expect("identity verifier not set")
    }

    /// Points the policy at a different identity verifier.
    ///
    /// Rotation is the migration path when the fund changes its KYC provider or
    /// the claim topology moves; the token needs no redeploy because it only
    /// knows this policy's address.
    #[only_owner]
    pub fn set_identity_verifier(e: &Env, identity_verifier: Address, _operator: Address) {
        e.storage()
            .instance()
            .set(&VelumPolicyKey::IdentityVerifier, &identity_verifier);
    }
}

/// The confidential token's authorization hook.
#[contractimpl]
impl Policy for VelumPolicyContract {
    /// Authorized iff the RWA identity registry verifies `account`'s claims.
    ///
    /// `token` is accepted for interface conformance and ignored: one verifier
    /// serves every wrapper of the same fund, so the claim requirement does not
    /// vary per token. A deployment needing per-token claim topics would branch
    /// here.
    fn is_authorized(e: Env, account: Address, _token: Address) -> bool {
        let verifier = Self::identity_verifier(&e);
        IdentityVerifierClient::new(&e, &verifier)
            .try_verify_identity(&account)
            .is_ok()
    }
}

#[contractimpl(contracttrait)]
impl Ownable for VelumPolicyContract {}
