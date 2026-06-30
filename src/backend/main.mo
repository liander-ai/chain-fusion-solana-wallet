import Blob "mo:base/Blob";
import Nat "mo:base/Nat";
import Nat8 "mo:base/Nat8";
import Nat32 "mo:base/Nat32";
import Char "mo:base/Char";
import Text "mo:base/Text";
import Buffer "mo:base/Buffer";
import Array "mo:base/Array";
import Iter "mo:base/Iter";
import Error "mo:base/Error";

// Chain Fusion: a Solana wallet owned by an Internet Computer canister.
//
//   Phase 2  derive the canister's Solana address (threshold Ed25519)
//   Phase 3  read its SOL balance via a direct HTTPS outcall + transform
//   Phase 5  build, threshold-sign, and submit a SOL transfer
//
// No private key is ever stored. The key is derived with the IC's threshold
// Ed25519 protocol and only assembled, in pieces, at signing time.
//
// RPC design: stable reads (balance) use a direct HTTPS outcall with a transform.
// The send uses the official SOL RPC canister, because a fresh blockhash cannot
// reach raw-outcall consensus (it changes ~every 400ms across subnet nodes); the
// SOL RPC canister rounds the slot so nodes agree, then fetches a stable block.

persistent actor {

  // ============================================================
  //  IC management canister (threshold Schnorr + HTTPS outcalls)
  // ============================================================
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
    sign_with_schnorr : ({
      message : Blob;
      derivation_path : [Blob];
      key_id : SchnorrKeyId;
      aux : ?{ #bip341 : { merkle_root_hash : Blob } };
    }) -> async ({ signature : Blob });
    http_request : HttpRequest -> async HttpResponse;
  };

  transient let ic : ManagementCanister = actor ("aaaaa-aa");

  // ============================================================
  //  SOL RPC canister (subset of its interface that we use)
  // ============================================================
  type SolanaCluster = { #Mainnet; #Devnet; #Testnet };
  type RpcEndpoint = { url : Text; headers : ?[HttpHeader] };
  type RpcSource = { #Custom : RpcEndpoint };
  type RpcSources = { #Default : SolanaCluster; #Custom : [RpcSource] };
  type ConsensusStrategy = { #Equality; #Threshold : { total : ?Nat8; min : Nat8 } };
  type GetSlotRpcConfig = {
    responseSizeEstimate : ?Nat64;
    responseConsensus : ?ConsensusStrategy;
    roundingError : ?Nat64;
  };
  type RpcConfig = {
    responseSizeEstimate : ?Nat64;
    responseConsensus : ?ConsensusStrategy;
  };
  type CommitmentLevel = { #processed; #confirmed; #finalized };

  type RejectionCode = {
    #NoError; #CanisterError; #SysTransient; #DestinationInvalid;
    #Unknown; #SysFatal; #CanisterReject;
  };
  type RpcError = {
    #JsonRpcError : { code : Int64; message : Text };
    #ProviderError : {
      #TooFewCycles : { expected : Nat; received : Nat };
      #InvalidRpcConfig : Text;
      #UnsupportedCluster : Text;
    };
    #ValidationError : Text;
    #HttpOutcallError : {
      #IcError : { code : RejectionCode; message : Text };
      #InvalidHttpJsonRpcResponse : { status : Nat16; body : Text; parsingError : ?Text };
    };
  };

  type GetSlotParams = { commitment : ?CommitmentLevel; minContextSlot : ?Nat64 };
  type GetSlotResult = { #Ok : Nat64; #Err : RpcError };
  // We force Equality consensus, so we expect the Consistent variant.
  type MultiGetSlotResult = { #Consistent : GetSlotResult };

  type TransactionDetails = { #accounts; #none; #signatures };
  type GetBlockParams = {
    slot : Nat64;
    transactionDetails : ?TransactionDetails;
    commitment : ?{ #confirmed; #finalized };
    maxSupportedTransactionVersion : ?Nat8;
    rewards : ?Bool;
  };
  type ConfirmedBlock = { blockhash : Text }; // we only need the blockhash
  type GetBlockResult = { #Ok : ?ConfirmedBlock; #Err : RpcError };
  type MultiGetBlockResult = { #Consistent : GetBlockResult };

  type SendTransactionEncoding = { #base58; #base64 };
  type SendTransactionParams = {
    transaction : Text;
    encoding : ?SendTransactionEncoding;
    skipPreflight : ?Bool;
    preflightCommitment : ?CommitmentLevel;
    maxRetries : ?Nat32;
    minContextSlot : ?Nat64;
  };
  type SendTransactionResult = { #Ok : Text; #Err : RpcError }; // Ok = signature
  type MultiSendTransactionResult = { #Consistent : SendTransactionResult };

  type SolRpc = actor {
    getSlot : (RpcSources, ?GetSlotRpcConfig, ?GetSlotParams) -> async MultiGetSlotResult;
    getBlock : (RpcSources, ?RpcConfig, GetBlockParams) -> async MultiGetBlockResult;
    sendTransaction : (RpcSources, ?RpcConfig, SendTransactionParams) -> async MultiSendTransactionResult;
  };
  transient let solRpc : SolRpc = actor ("tghme-zyaaa-aaaar-qarca-cai");

  // ============================================================
  //  Config
  // ============================================================
  // Local replica uses "dfx_test_key". Mainnet: "key_1" (testnet: "test_key_1").
  transient let KEY_NAME : Text = "dfx_test_key";
  transient let SOLANA_RPC : Text = "https://api.devnet.solana.com";
  transient let EQUALITY : ConsensusStrategy = #Equality;
  // Use the public devnet endpoint directly, so no provider API key is required.
  transient let SOL_SOURCES : RpcSources = #Custom([#Custom({ url = SOLANA_RPC; headers = null })]);
  // Generous; the SOL RPC canister refunds unused cycles. Tune via *CyclesCost on mainnet.
  transient let RPC_CYCLES : Nat = 1_000_000_000_000;
  transient let SIGN_CYCLES : Nat = 30_000_000_000;
  transient let OUTCALL_CYCLES : Nat = 230_949_972_000;

  // ============================================================
  //  base58 (Bitcoin / Solana alphabet)
  // ============================================================
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

  func alphaIndex(c : Char) : ?Nat {
    var i = 0;
    for (a in ALPHABET.vals()) { if (a == c) { return ?i }; i += 1 };
    null;
  };

  func base58Decode(s : Text) : ?[Nat8] {
    var n : Nat = 0;
    for (c in s.chars()) {
      switch (alphaIndex(c)) {
        case null { return null };
        case (?d) { n := n * 58 + d };
      };
    };
    var zeros = 0;
    var stop = false;
    for (c in s.chars()) {
      if (not stop) { if (c == '1') { zeros += 1 } else { stop := true } };
    };
    let le = Buffer.Buffer<Nat8>(64);
    while (n > 0) { le.add(Nat8.fromNat(n % 256)); n := n / 256 };
    let be = Array.reverse(Buffer.toArray(le));
    let out = Buffer.Buffer<Nat8>(zeros + be.size());
    var i = 0;
    while (i < zeros) { out.add(0); i += 1 };
    for (b in be.vals()) { out.add(b) };
    ?Buffer.toArray(out);
  };

  // ============================================================
  //  base64 (standard alphabet)
  // ============================================================
  transient let B64 : [Char] = Iter.toArray(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".chars()
  );

  func base64Encode(bytes : [Nat8]) : Text {
    let n = bytes.size();
    let out = Buffer.Buffer<Char>(n * 2);
    var i = 0;
    while (i < n) {
      let b0 = Nat8.toNat(bytes[i]);
      let b1 = if (i + 1 < n) { Nat8.toNat(bytes[i + 1]) } else { 0 };
      let b2 = if (i + 2 < n) { Nat8.toNat(bytes[i + 2]) } else { 0 };
      let triple = b0 * 65536 + b1 * 256 + b2;
      out.add(B64[triple / 262144 % 64]);
      out.add(B64[triple / 4096 % 64]);
      if (i + 1 < n) { out.add(B64[triple / 64 % 64]) } else { out.add('=') };
      if (i + 2 < n) { out.add(B64[triple % 64]) } else { out.add('=') };
      i += 3;
    };
    Text.fromIter(out.vals());
  };

  // ============================================================
  //  numeric helpers
  // ============================================================
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
    Nat.toText(l / 1_000_000_000) # "." # padLeft(Nat.toText(l % 1_000_000_000), 9);
  };

  func u32le(v : Nat) : [Nat8] {
    let b = Buffer.Buffer<Nat8>(4);
    var n = v; var i = 0;
    while (i < 4) { b.add(Nat8.fromNat(n % 256)); n := n / 256; i += 1 };
    Buffer.toArray(b);
  };

  func u64le(v : Nat) : [Nat8] {
    let b = Buffer.Buffer<Nat8>(8);
    var n = v; var i = 0;
    while (i < 8) { b.add(Nat8.fromNat(n % 256)); n := n / 256; i += 1 };
    Buffer.toArray(b);
  };

  // Solana compact-u16 (shortvec) length prefix.
  func shortvec(len : Nat) : [Nat8] {
    let b = Buffer.Buffer<Nat8>(3);
    var n = len;
    var done = false;
    while (not done) {
      var byte = n % 128;
      n := n / 128;
      if (n != 0) { byte += 128 };
      b.add(Nat8.fromNat(byte));
      if (n == 0) { done := true };
    };
    Buffer.toArray(b);
  };

  func appendBytes(buf : Buffer.Buffer<Nat8>, arr : [Nat8]) {
    for (b in arr.vals()) { buf.add(b) };
  };

  // ============================================================
  //  threshold Ed25519: address + signing
  // ============================================================
  func pubkeyBytes() : async [Nat8] {
    let { public_key } = await ic.schnorr_public_key({
      canister_id = null;
      derivation_path = [];
      key_id = { algorithm = #ed25519; name = KEY_NAME };
    });
    Blob.toArray(public_key);
  };

  func signMessage(message : [Nat8]) : async [Nat8] {
    let { signature } = await (with cycles = SIGN_CYCLES) ic.sign_with_schnorr({
      message = Blob.fromArray(message);
      derivation_path = [];
      key_id = { algorithm = #ed25519; name = KEY_NAME };
      aux = null;
    });
    Blob.toArray(signature);
  };

  public func get_solana_address() : async Text {
    base58Encode(await pubkeyBytes());
  };

  // ============================================================
  //  Phase 3: balance via direct HTTPS outcall
  // ============================================================
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
    let lamports = switch (extractLamports(args.response.body)) { case (?n) { n }; case null { 0 } };
    { status = args.response.status; headers = []; body = Text.encodeUtf8(Nat.toText(lamports)) };
  };

  public func get_balance() : async { address : Text; lamports : Nat; sol : Text } {
    let address = base58Encode(await pubkeyBytes());
    let payload = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getBalance\",\"params\":[\"" # address # "\"]}";
    let request : HttpRequest = {
      url = SOLANA_RPC;
      max_response_bytes = ?2000;
      headers = [{ name = "Content-Type"; value = "application/json" }];
      body = ?Text.encodeUtf8(payload);
      method = #post;
      transform = ?{ function = transform; context = Blob.fromArray([]) };
    };
    let response = await (with cycles = OUTCALL_CYCLES) ic.http_request(request);
    let bodyText = switch (Text.decodeUtf8(response.body)) { case (?t) { t }; case null { "" } };
    let lamports = switch (parseLeadingNat(bodyText)) { case (?n) { n }; case null { 0 } };
    { address; lamports; sol = lamportsToSol(lamports) };
  };

  // ============================================================
  //  Phase 5: build + threshold-sign + submit a SOL transfer
  // ============================================================
  func rpcErrText(e : RpcError) : Text {
    switch (e) {
      case (#JsonRpcError(j)) { "JSON-RPC error: " # j.message };
      case (#ValidationError(t)) { "validation error: " # t };
      case (#ProviderError(_)) { "provider error" };
      case (#HttpOutcallError(_)) { "http outcall error" };
    };
  };

  // A blockhash that all subnet nodes agree on: round the slot down so nodes
  // converge, then fetch that (stable) finalized block, skipping empty slots.
  func recentBlockhash() : async Text {
    let slotRes = await (with cycles = RPC_CYCLES) solRpc.getSlot(
      SOL_SOURCES,
      ?{ responseSizeEstimate = null; responseConsensus = ?EQUALITY; roundingError = ?20 },
      ?{ commitment = ?#finalized; minContextSlot = null },
    );
    let slot : Nat64 = switch (slotRes) {
      case (#Consistent(#Ok(s))) { s };
      case (#Consistent(#Err(e))) { throw Error.reject("getSlot: " # rpcErrText(e)) };
    };

    var i : Nat64 = 0;
    loop {
      let blkRes = await (with cycles = RPC_CYCLES) solRpc.getBlock(
        SOL_SOURCES,
        ?{ responseSizeEstimate = null; responseConsensus = ?EQUALITY },
        {
          slot = slot - i;
          transactionDetails = ?#none;
          commitment = ?#finalized;
          maxSupportedTransactionVersion = ?0;
          rewards = ?false;
        },
      );
      switch (blkRes) {
        case (#Consistent(#Ok(?block))) { return block.blockhash };
        case (_) {}; // empty slot or transient error: step back one slot
      };
      i += 1;
      if (i > 10) { throw Error.reject("could not fetch a recent blockhash") };
    };
  };

  func buildTransferMessage(from : [Nat8], to : [Nat8], blockhash : [Nat8], lamports : Nat) : [Nat8] {
    let systemProgram : [Nat8] = Array.tabulate<Nat8>(32, func(_ : Nat) : Nat8 { 0 });
    let buf = Buffer.Buffer<Nat8>(200);
    // message header: 1 required signature, 0 readonly-signed, 1 readonly-unsigned
    buf.add(1); buf.add(0); buf.add(1);
    // account keys: [from (signer, writable), to (writable), system program (readonly)]
    appendBytes(buf, shortvec(3));
    appendBytes(buf, from);
    appendBytes(buf, to);
    appendBytes(buf, systemProgram);
    // recent blockhash
    appendBytes(buf, blockhash);
    // one instruction
    appendBytes(buf, shortvec(1));
    buf.add(2); // program id index -> system program
    appendBytes(buf, shortvec(2)); buf.add(0); buf.add(1); // account indices: from, to
    let data = Array.append(u32le(2), u64le(lamports)); // SystemProgram::Transfer
    appendBytes(buf, shortvec(data.size()));
    appendBytes(buf, data);
    Buffer.toArray(buf);
  };

  type SendResult = { #ok : { signature : Text; explorer : Text }; #err : Text };

  /// Transfer `lamports` of SOL from the canister's own wallet to `recipient`.
  public func send_sol(recipient : Text, lamports : Nat) : async SendResult {
    let toBytes = switch (base58Decode(recipient)) {
      case (?b) { b };
      case null { return #err("invalid recipient address") };
    };
    if (toBytes.size() != 32) { return #err("recipient is not a 32-byte address") };

    let blockhashText = await recentBlockhash();
    let blockhashBytes = switch (base58Decode(blockhashText)) {
      case (?b) { b };
      case null { return #err("could not decode blockhash") };
    };

    let fromBytes = await pubkeyBytes();
    let message = buildTransferMessage(fromBytes, toBytes, blockhashBytes, lamports);
    let signature = await signMessage(message);

    // transaction = compact-array(signatures) ++ message
    let tx = Buffer.Buffer<Nat8>(signature.size() + message.size() + 1);
    appendBytes(tx, shortvec(1));
    appendBytes(tx, signature);
    appendBytes(tx, message);
    let txBase64 = base64Encode(Buffer.toArray(tx));

    let sendRes = await (with cycles = RPC_CYCLES) solRpc.sendTransaction(
      SOL_SOURCES,
      ?{ responseSizeEstimate = null; responseConsensus = ?EQUALITY },
      {
        transaction = txBase64;
        encoding = ?#base64;
        skipPreflight = null;
        preflightCommitment = null;
        maxRetries = null;
        minContextSlot = null;
      },
    );
    switch (sendRes) {
      case (#Consistent(#Ok(sig))) {
        #ok({ signature = sig; explorer = "https://explorer.solana.com/tx/" # sig # "?cluster=devnet" });
      };
      case (#Consistent(#Err(e))) { #err(rpcErrText(e)) };
    };
  };

  public query func status() : async Text {
    "chain-fusion-solana-wallet: phase 5 (sign + send)";
  };
};
