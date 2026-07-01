import { HttpAgent, Actor } from "https://esm.sh/@dfinity/agent@3";

// Local replica vs. IC mainnet. Fill in the mainnet backend id after deploying to ic.
// A fresh `dfx deploy` may hand the backend a different local id, so the backend
// id can also be overridden per-visit with ?backend=<canister-id> in the URL.
const IS_LOCAL = /localhost|127\.0\.0\.1/.test(location.hostname);
const CONFIG = {
  local: { host: "http://127.0.0.1:4943", backendId: "lqy7q-dh777-77777-aaaaq-cai" },
  ic: { host: "https://icp-api.io", backendId: "" },
};
const env = IS_LOCAL ? CONFIG.local : CONFIG.ic;
const host = env.host;
const backendId = new URLSearchParams(location.search).get("backend") || env.backendId;

const idlFactory = ({ IDL }) => {
  const Balance = IDL.Record({ address: IDL.Text, lamports: IDL.Nat, sol: IDL.Text });
  const SendResult = IDL.Variant({
    ok: IDL.Record({ signature: IDL.Text, explorer: IDL.Text }),
    err: IDL.Text,
  });
  return IDL.Service({
    get_solana_address: IDL.Func([], [IDL.Text], []),
    get_balance: IDL.Func([], [Balance], []),
    send_sol: IDL.Func([IDL.Text, IDL.Nat], [SendResult], []),
    status: IDL.Func([], [IDL.Text], ["query"]),
  });
};

const $ = (id) => document.getElementById(id);
const els = {
  address: $("address"), copyBtn: $("copyBtn"), addrExplorer: $("addrExplorer"),
  balSol: $("balSol"), balLamports: $("balLamports"), refreshBtn: $("refreshBtn"),
  sendForm: $("sendForm"), recipient: $("recipient"), amount: $("amount"),
  sendBtn: $("sendBtn"), result: $("result"),
};

const state = { address: "" };
let backend;

const shortSig = (s) => (s.length > 20 ? `${s.slice(0, 8)}…${s.slice(-8)}` : s);

function showResult(kind, html) {
  els.result.hidden = false;
  els.result.className = kind === "pending" ? "result" : `result ${kind}`;
  els.result.innerHTML = kind === "pending" ? `<span class="pending">${html}</span>` : html;
}

async function loadAddress() {
  try {
    const addr = await backend.get_solana_address();
    state.address = addr;
    els.address.textContent = addr;
    els.copyBtn.disabled = false;
    els.addrExplorer.href = `https://explorer.solana.com/address/${addr}?cluster=devnet`;
    els.addrExplorer.hidden = false;
  } catch (e) {
    els.address.textContent = "failed to load address";
    console.error(e);
  }
}

async function loadBalance() {
  els.refreshBtn.disabled = true;
  els.refreshBtn.textContent = "…";
  try {
    const b = await backend.get_balance();
    els.balSol.textContent = b.sol;
    els.balLamports.textContent = `${b.lamports.toString()} lamports`;
  } catch (e) {
    els.balLamports.textContent = "failed to load balance";
    console.error(e);
  } finally {
    els.refreshBtn.disabled = false;
    els.refreshBtn.textContent = "refresh";
  }
}

els.copyBtn.addEventListener("click", async () => {
  try {
    await navigator.clipboard.writeText(state.address);
    els.copyBtn.textContent = "copied";
    setTimeout(() => (els.copyBtn.textContent = "copy"), 1200);
  } catch { /* clipboard may be blocked; ignore */ }
});

els.refreshBtn.addEventListener("click", loadBalance);

els.sendForm.addEventListener("submit", async (e) => {
  e.preventDefault();
  const recipient = els.recipient.value.trim();
  const sol = Number.parseFloat(els.amount.value);
  if (!recipient || !(sol > 0)) {
    showResult("err", "Enter a recipient address and a positive amount.");
    return;
  }
  const lamports = BigInt(Math.round(sol * 1e9));
  els.sendBtn.disabled = true;
  els.sendBtn.textContent = "signing…";
  showResult("pending", "Building, threshold-signing, and broadcasting…");
  try {
    const res = await backend.send_sol(recipient, lamports);
    if ("ok" in res) {
      showResult("ok", `sent &middot; <a href="${res.ok.explorer}" target="_blank" rel="noopener">${shortSig(res.ok.signature)}</a>`);
      loadBalance();
    } else {
      showResult("err", res.err);
    }
  } catch (err) {
    showResult("err", err?.message || String(err));
  } finally {
    els.sendBtn.disabled = false;
    els.sendBtn.textContent = "Sign & send";
  }
});

async function init() {
  if (!backendId) {
    els.address.textContent = "backend canister id not configured";
    return;
  }
  try {
    const agent = await HttpAgent.create({ host });
    if (IS_LOCAL) await agent.fetchRootKey();
    backend = Actor.createActor(idlFactory, { agent, canisterId: backendId });
    els.sendBtn.disabled = false;
    await loadAddress();
    await loadBalance();
  } catch (e) {
    els.address.textContent = "failed to connect to the canister";
    console.error(e);
  }
}

init();
