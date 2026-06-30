import Blob "mo:base/Blob";
import Nat8 "mo:base/Nat8";
import Text "mo:base/Text";
import Buffer "mo:base/Buffer";
import Array "mo:base/Array";
import Iter "mo:base/Iter";

// Chain Fusion: a Solana wallet owned by an Internet Computer canister.
//
// Phase 2 (this file): derive the canister's own Solana address from its
// threshold Ed25519 public key. A Solana address is base58(public_key).

persistent actor {

  // ----- IC management canister: threshold Schnorr (Ed25519) -----
  type SchnorrAlgorithm = { #bip340secp256k1; #ed25519 };
  type SchnorrKeyId = { algorithm : SchnorrAlgorithm; name : Text };

  type ManagementCanister = actor {
    schnorr_public_key : ({
      canister_id : ?Principal;
      derivation_path : [Blob];
      key_id : SchnorrKeyId;
    }) -> async ({ public_key : Blob; chain_code : Blob });
  };

  let ic : ManagementCanister = actor ("aaaaa-aa");

  // Local replica uses "dfx_test_key". Mainnet: "key_1" (testnet: "test_key_1").
  let KEY_NAME : Text = "dfx_test_key";

  // ----- base58 encoding (Bitcoin / Solana alphabet) -----
  let ALPHABET : [Char] = Iter.toArray(
    "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".chars()
  );

  func base58Encode(bytes : [Nat8]) : Text {
    // leading zero bytes become leading '1' characters
    var zeros = 0;
    var stop = false;
    for (b in bytes.vals()) {
      if (not stop) {
        if (b == 0) { zeros += 1 } else { stop := true };
      };
    };

    // interpret the bytes as one big-endian number (Motoko Nat is unbounded)
    var n : Nat = 0;
    for (b in bytes.vals()) { n := n * 256 + Nat8.toNat(b) };

    let out = Buffer.Buffer<Char>(64);
    while (n > 0) {
      out.add(ALPHABET[n % 58]);
      n := n / 58;
    };
    var i = 0;
    while (i < zeros) { out.add('1'); i += 1 };

    Text.fromIter(Array.reverse(Buffer.toArray(out)).vals());
  };

  // ----- public API -----

  /// The canister's own Solana address (base58 of its threshold Ed25519 key).
  public func get_solana_address() : async Text {
    let { public_key } = await ic.schnorr_public_key({
      canister_id = null;
      derivation_path = [];
      key_id = { algorithm = #ed25519; name = KEY_NAME };
    });
    base58Encode(Blob.toArray(public_key));
  };

  public query func status() : async Text {
    "chain-fusion-solana-wallet: phase 2 (address derivation)";
  };
};
