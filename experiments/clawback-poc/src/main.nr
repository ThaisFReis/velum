// Clawback PoC -- Test A of the Velum whitepaper's Section 11.
//
// This package is a test harness, not a circuit: it verifies the cryptographic
// PREMISE of the viewing-key-escrow proposal in plain (non-constrained) Noir,
// using the exact library primitives the production circuits constrain.
//
// Premise under test: an auditor holding only the holder's viewing key `vk`
// and the public event nonce `sigma` can reconstruct the FULL opening
// (v_s, r_s) of the holder's spendable-balance commitment -- and can derive
// the canonical post-seizure blinding, so a partially-seized balance remains
// openable by the holder through ordinary wallet recovery.
//
// See src/tests.nr for the actual assertions. `main` exists only because a
// `bin` package requires one; it is not part of the experiment.

mod tests;

fn main() {}
