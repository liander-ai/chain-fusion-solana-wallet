import Blob "mo:base/Blob";
import Nat "mo:base/Nat";
import Nat8 "mo:base/Nat8";
import Nat32 "mo:base/Nat32";
import Char "mo:base/Char";
import Text "mo:base/Text";
import Buffer "mo:base/Buffer";
import Array "mo:base/Array";
import Iter "mo:base/Iter";

// Chain Fusion: a Solana wallet owned by an Internet Computer canister.
//
//   Phase 2  derive the canister's Solana address (threshold Ed25519)
//   Phase 3  read its SOL balance from Solana via an HTTPS outcall
//
// No private key is ever stored: the key is derived with the IC's threshold
// Ed25519 protocol and only assembled, in pieces, at signing time.

persistent actor {

  // ---------- IC management canister ----------
  type SchnorrAlgorithm = { #bip340secp256k1; #ed25519 };
  type SchnorrKeyId = { algorithm : SchnorrAlgorithm; name : Text };

  type HttpHeader = { name : Text; value : Text };
  type HttpMethod = { #get; #head; #post };
  type HttpResponse = { status : Nat; headers : [HttpHeader]; body : Blob };
  type TransformArgs = { response : HttpResponse; context : Blob };
  type TransformContext = {
    function : shared query (TransformArgs) -> async HttpResponse;
    context : Blob;
  };
  type HttpRequest = {
    url : Text;
    max_response_bytes : ?Nat64;
    headers : [HttpHeader];
    body : ?Blob;
    method : HttpMethod;
    transform : ?TransformContext;
  };

  type ManagementCanister = actor {
    schnorr_public_key : ({
      canister_id : ?Principal;
      derivation_path : [Blob];
      key_id : SchnorrKeyId;
    }) -> async ({ public_key : Blob; chain_code : Blob });
    http_request : HttpRequest -> async HttpResponse;
  };

  transient let ic : ManagementCanister = actor ("aaaaa-aa");

  // Local replica uses "dfx_test_key". Mainnet: "key_1" (testnet: "test_key_1").
  transient let KEY_NAME : Text = "dfx_test_key";

  // Solana JSON-RPC endpoint (devnet).
  transient let SOLANA_RPC : Text = "https://api.devnet.solana.com";

  // ---------- base58 (Bitcoin / Solana alphabet) ----------
  transient let ALPHABET : [Char] = Iter.toArray(
    "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".chars()
  );

  func base58Encode(bytes : [Nat8]) : Text {
    var zeros = 0;
    var stop = false;
    for (b in bytes.vals()) {
      if (not stop) { if (b == 0) { zeros += 1 } else { stop := true } };
    };
    var n : Nat = 0;
    for (b in bytes.vals()) { n := n * 256 + Nat8.toNat(b) };
    let out = Buffer.Buffer<Char>(64);
    while (n > 0) { out.add(ALPHABET[n % 58]); n := n / 58 };
    var i = 0;
    while (i < zeros) { out.add('1'); i += 1 };
    Text.fromIter(Array.reverse(Buffer.toArray(out)).vals());
  };

  // ---------- small numeric helpers ----------
  func parseLeadingNat(t : Text) : ?Nat {
    var n : Nat = 0;
    var any = false;
    label scan for (c in t.chars()) {
      let d = Char.toNat32(c);
      if (d >= 48 and d <= 57) { n := n * 10 + Nat32.toNat(d - 48); any := true }
      else { break scan };
    };
    if (any) { ?n } else { null };
  };

  func padLeft(t : Text, width : Nat) : Text {
    var s = t;
    while (s.size() < width) { s := "0" # s };
    s;
  };

  func lamportsToSol(l : Nat) : Text {
    let whole = l / 1_000_000_000;
    let frac = l % 1_000_000_000;
    Nat.toText(whole) # "." # padLeft(Nat.toText(frac), 9);
  };

  // ---------- address derivation (Phase 2) ----------
  func deriveAddress() : async Text {
    let { public_key } = await ic.schnorr_public_key({
      canister_id = null;
      derivation_path = [];
      key_id = { algorithm = #ed25519; name = KEY_NAME };
    });
    base58Encode(Blob.toArray(public_key));
  };

  public func get_solana_address() : async Text {
    await deriveAddress();
  };

  // ---------- balance via HTTPS outcall (Phase 3) ----------

  // The raw getBalance response contains a volatile "slot" that would break
  // cross-replica consensus, so the transform keeps only the lamport value:
  // every replica then produces an identical response body.
  func extractLamports(body : Blob) : ?Nat {
    switch (Text.decodeUtf8(body)) {
      case null { null };
      case (?text) {
        let parts = Iter.toArray(Text.split(text, #text "\"value\":"));
        if (parts.size() < 2) { null } else { parseLeadingNat(parts[1]) };
      };
    };
  };

  public query func transform(args : TransformArgs) : async HttpResponse {
    let lamports = switch (extractLamports(args.response.body)) {
      case (?n) { n };
      case null { 0 };
    };
    {
      status = args.response.status;
      headers = [];
      body = Text.encodeUtf8(Nat.toText(lamports));
    };
  };

  public func get_balance() : async { address : Text; lamports : Nat; sol : Text } {
    let address = await deriveAddress();
    let payload = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getBalance\",\"params\":[\"" # address # "\"]}";
    let request : HttpRequest = {
      url = SOLANA_RPC;
      max_response_bytes = ?2000;
      headers = [{ name = "Content-Type"; value = "application/json" }];
      body = ?Text.encodeUtf8(payload);
      method = #post;
      transform = ?{ function = transform; context = Blob.fromArray([]) };
    };
    let response = await (with cycles = 230_949_972_000) ic.http_request(request);
    let bodyText = switch (Text.decodeUtf8(response.body)) { case (?t) { t }; case null { "" } };
    let lamports = switch (parseLeadingNat(bodyText)) { case (?n) { n }; case null { 0 } };
    { address; lamports; sol = lamportsToSol(lamports) };
  };

  public query func status() : async Text {
    "chain-fusion-solana-wallet: phase 3 (read SOL balance)";
  };
};
