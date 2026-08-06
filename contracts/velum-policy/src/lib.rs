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
//! ## Failing closed on a misconfigured registry
//!
//! Upstream's `verify_identity` walks `(claim_topic, issuers)` pairs and, for each, requires a
//! valid claim from one of that topic's trusted issuers. A topic whose issuer list is **empty**
//! never enters the inner loop, so it never raises — the topic is skipped in silence.
//!
//! The operational consequence is nasty: an operator who registers a claim topic to tighten the
//! rules, and forgets to authorise an issuer for it, gets **no enforcement of that topic at all**,
//! with no error, no event, and a registry that reads as if the rule were active. Every holder
//! keeps passing.
//!
//! This adapter refuses to be the quiet half of that mistake. Before delegating, it reads the
//! topic/issuer map and returns `false` if any registered topic has no issuer. A deployment in
//! that state is not "permissive", it is **unconfigured** — and a compliance gate that cannot
//! tell the difference should reject, not admit.
//!
//! The cost is two cross-contract reads per authorization check, on every gated operation. For a
//! gate whose failure mode is silent under-enforcement, that is the right side to err on; a
//! deployment that wants the cheaper path can pin the check to configuration time instead.
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
    rwa::identity_verification::{
        claim_topics_and_issuers::ClaimTopicsAndIssuersClient, IdentityVerifierClient,
    },
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
        let verifier_client = IdentityVerifierClient::new(&e, &verifier);

        // A registered topic with no trusted issuer is silently skipped upstream.
        // Treat that as an unconfigured deployment and refuse, rather than
        // reporting an authorization the registry never actually checked.
        let cti = verifier_client.claim_topics_and_issuers();
        let topics = ClaimTopicsAndIssuersClient::new(&e, &cti).get_claim_topics_and_issuers();
        for (_topic, issuers) in topics.iter() {
            if issuers.is_empty() {
                return false;
            }
        }

        verifier_client.try_verify_identity(&account).is_ok()
    }
}

#[contractimpl(contracttrait)]
impl Ownable for VelumPolicyContract {}
