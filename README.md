# Chain Fusion: a Solana wallet owned by an Internet Computer smart contract

An ICP canister that derives, holds, and spends its own Solana wallet using
threshold Ed25519 signing. No bridge. No private key stored anywhere.

> Status: work in progress, building in public.

## Why this exists

To control a Solana wallet you normally need a private key sitting on a server
or in a browser extension. That key is the thing that gets leaked, and it is the
reason most cross-chain setups rely on bridges, which keep getting drained.

Chain Fusion removes the key. An Internet Computer canister derives its own
Solana address with threshold Ed25519: the private key never exists in one place.
It is split across the nodes of an ICP subnet and only assembled, in pieces, at
signing time. The same canister can read Solana state and broadcast transactions
over RPC.

The result is a smart contract on one chain that holds and spends a wallet on
another, with no bridge and no stored key.

## What it does

- Derives the canister's own Solana address (threshold Ed25519)
- Reads its live SOL balance from Solana
- Builds, signs, and submits a SOL transfer on devnet
- A small web frontend showing the address, the balance, and a send action

## Architecture

_Diagram and flow to be added._

- Threshold Ed25519 via the IC management canister (Schnorr API)
- Solana reads and writes via Solana RPC
- The Solana transaction is built and serialized in Motoko

## Run it locally

_Steps to be added as each phase lands._

## License

MIT. See [LICENSE](LICENSE).
