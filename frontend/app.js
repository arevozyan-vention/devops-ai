// devops-ai-ui — single-page vanilla-JS frontend.
// Talks to the FastAPI backend via fetch + WebSocket.

const $  = (q, root = document) => root.querySelector(q);
const $$ = (q, root = document) => [...root.querySelectorAll(q)];

let currentRepo = null;       // selected project name
let activeWS    = null;       // active log WebSocket
// Live state for the currently-running recipe — used to render an animated
// "Running Ns · ToolName" indicator directly on the step row in renderSteps.
let runningAction = null;     // action string (e.g. "assess") or null
let runningStartedAt = 0;     // ms epoch
let runningLastTool = "";     // last tool/section name pulled from log
let runningTokens   = "";     // formatted token count (e.g. "2.3M") parsed
                              // from the shell's "    tokens: X.XM (session …)"
                              // line emitted at end of each goose recipe
let runningEtaSec    = 0;     // backend-supplied ETA for current run (sec).
                              // Used to compute progress % = min(95, elapsed/eta).
let runningEtaSource = "";    // "default" | "historical" — shown in subline so
                              // operator knows whether the bar is calibrated.
let runningEtaSamples = 0;    // count of past runs informing the ETA (when historical).

// ─── Workflow steps definition ─────────────────────────────────────
// Each step describes its prereq (a status flag from state.yaml that must be
// true), its label, and how to invoke it. `prompt` is an optional function
// that returns extra payload from the user via a modal.
// Each step: how it's marked "done"
//  • sets       — state.yaml status flags this step flips to true
//  • artifact   — path to a file (relative to project root) that exists
//                 if the step has run; used for steps without state flags
//                 (plan-infra, audit)
//  • side-only  — no artifact and no flag (e.g. aws-bootstrap which only
//                 creates an S3 bucket); fall back to in-session memory
const STEPS = [
  {
    id: "assess",         action: "assess",
    label: "Assess (read repo + recommend extensions)",
    prereq: null,
    sets: ["analyzed", "recommended"],
  },
  {
    id: "select",         action: "select",
    label: "Pick extensions + lock",
    prereq: "recommended", sets: ["selected"],
    prompt: promptSelect,
  },
  {
    id: "generate-iac",   action: "generate-iac",
    label: "Generate IaC",
    prereq: "selected",   sets: ["iac_generated"],
  },
  {
    id: "bootstrap",
    // Per-cloud action + label. Resolved at render time from the project's
    // cloud field (state.yaml :: cloud). aws → S3 bucket; azure → Storage
    // Account + Blob container.
    action: (cloud) => (cloud === "azure" ? "az-bootstrap" : "aws-bootstrap"),
    label:  (cloud) => (cloud === "azure"
      ? "Bootstrap Azure Storage tfstate"
      : "Bootstrap S3 tfstate bucket"),
    prereq: "iac_generated", sets: [],
    // No on-disk artifact and no state flag — just a remote-state container
    // on the user's cloud. We mark it done if the user successfully ran it
    // in this UI session (in-memory).
  },
  {
    id: "plan-infra",     action: "plan-infra",
    label: "Plan infra (terragrunt plan)",
    prereq: "iac_generated", sets: [],
    artifact: "deploy/plan_summary.md",
  },
  {
    id: "apply-infra",    action: "apply-infra",
    label:   (cloud) => `Apply infra (creates real ${(cloud || "aws").toUpperCase()} resources)`,
    prereq:  "iac_generated", sets: ["infra_deployed"],
    confirm: (cloud) => `This will create real ${(cloud || "aws").toUpperCase()} resources and incur cost. Proceed?`,
  },
  {
    id: "deploy-app",     action: "deploy-app",
    label: (cloud) => (cloud === "azure"
      ? "Deploy application (build + push to ACR + Container App update)"
      : "Deploy application (build + push to ECR + ECS update)"),
    prereq: "infra_deployed", sets: ["app_deployed"],
  },
  {
    id: "audit",          action: "audit",
    label: "Audit (drift / posture)",
    prereq: "iac_generated", sets: [],
    artifact: "docs/02_audit.md",
  },
];

// In-session memory for steps that have no state flag and no on-disk
// artifact (currently just aws-bootstrap). Survives navigation within
// the SPA but resets on page reload — that's fine, the bucket is
// idempotent so the user can just re-run.
const sessionCompletedActions = new Set();

// Last successful run duration per (repo, action), persisted to
// localStorage so it survives reload. Display next to Re-run button.
const LAST_RUN_KEY = "devops-ai-ui:lastRun";
function loadLastRunMap() {
  try { return JSON.parse(localStorage.getItem(LAST_RUN_KEY) || "{}"); }
  catch (e) { return {}; }
}
function saveLastRun(repo, action, seconds, tokens) {
  const map = loadLastRunMap();
  // tokens is optional — older entries that pre-date the token plumbing
  // still render correctly because the render path treats undefined as
  // "don't show". Always overwrite the field so a re-run after a fresh
  // shell-side fix updates the value (rather than keeping a stale one).
  map[`${repo}:${action}`] = { seconds, tokens: tokens || null, at: Date.now() };
  try { localStorage.setItem(LAST_RUN_KEY, JSON.stringify(map)); }
  catch (e) { /* quota? ignore */ }
}
function getLastRun(repo, action) {
  const map = loadLastRunMap();
  return map[`${repo}:${action}`] || null;
}
function fmtSec(s) {
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s/60)}m${String(s%60).padStart(2,'0')}s`;
  return `${Math.floor(s/3600)}h${String(Math.floor((s%3600)/60)).padStart(2,'0')}m`;
}
// Format the live "X% · ~Ym (default|avg of N)" suffix appended to the
// running-step subline. Returns "" when ETA isn't known yet (fetch in
// flight or unsupported action) so the basic "elapsed Ns" still renders
// without a confusing 0%.
function runningProgressSuffix(elapsedSec) {
  if (!runningEtaSec || runningEtaSec <= 0) return "";
  const pct = Math.min(95, Math.floor(elapsedSec * 100 / runningEtaSec));
  const tag = runningEtaSource === "historical"
    ? `avg of ${runningEtaSamples}`
    : "default";
  return ` · ${pct}% of ~${fmtSec(runningEtaSec)} (${tag})`;
}


// ─── Tab navigation ────────────────────────────────────────────────
function showTab(name) {
  $$(".tab-btn").forEach(b => b.classList.toggle("active-tab", b.dataset.tab === name));
  $$("[data-pane]").forEach(p => p.classList.toggle("hidden", p.dataset.pane !== name));
}
$$(".tab-btn").forEach(b => b.addEventListener("click", () => showTab(b.dataset.tab)));


// ─── Auth status badges ────────────────────────────────────────────
async function refreshAuth() {
  try {
    const r = await fetch("/api/health").then(r => r.json());
    const aws = $("#aws-badge");
    if (r.aws_authenticated) {
      aws.textContent = `AWS: ${r.aws.Account} / ${r.aws.Arn.split("/").pop()}`;
      aws.className = "px-3 py-1 rounded-full bg-green-100 text-green-800";
    } else {
      aws.textContent = "AWS: not configured";
      aws.className = "px-3 py-1 rounded-full bg-red-100 text-red-800";
    }
    const az = $("#azure-badge");
    if (az) {
      if (r.azure_authenticated) {
        const sub = (r.azure.SubscriptionName || r.azure.Subscription || "").toString();
        az.textContent = `Azure: ${sub.slice(0, 24)} / ${r.azure.UserType || ""}`;
        az.className   = "px-3 py-1 rounded-full bg-green-100 text-green-800";
      } else {
        az.textContent = "Azure: not configured";
        az.className   = "px-3 py-1 rounded-full bg-slate-100 text-slate-600";
      }
    }
    const cl = $("#claude-badge");
    if (r.claude_authenticated) {
      cl.textContent = "Claude: ready (Opus 4.7)";
      cl.className = "px-3 py-1 rounded-full bg-green-100 text-green-800";
    } else {
      cl.textContent = "Claude: not authenticated";
      cl.className = "px-3 py-1 rounded-full bg-red-100 text-red-800";
    }
    const detail = $("#claude-detail");
    if (detail) {
      detail.textContent = r.claude_authenticated
        ? "✓ Anthropic auth ready — Goose can call Claude."
        : "✗ No working auth. Activate one of the paths below.";
    }
    // Per-path status pills
    refreshAuthStatus();
  } catch (e) { console.error(e); }
}
refreshAuth();
$("#claude-recheck").addEventListener("click", refreshAuth);


// ─── Per-path status pills (subscription vs API key) ───────────────
async function refreshAuthStatus() {
  try {
    const s = await fetch("/api/anthropic/status").then(r => r.json());

    const sub = $("#sub-status");
    if (sub) {
      sub.textContent = s.subscription_works ? "✓ ready" : "not detected";
      sub.className = "text-xs px-2 py-0.5 rounded-full " +
        (s.subscription_works ? "bg-green-100 text-green-800" : "bg-slate-200 text-slate-600");
    }
    const key = $("#key-status");
    if (key) {
      key.textContent = s.api_key_works ? "✓ valid" : (s.api_key_error ? "invalid" : "not set");
      key.className = "text-xs px-2 py-0.5 rounded-full " +
        (s.api_key_works ? "bg-green-100 text-green-800" : "bg-slate-200 text-slate-600");
    }
    // Indicate which path is currently active in goose config
    const provider = s.current_provider;
    const active = provider === "claude-acp" ? "subscription"
                 : provider === "anthropic" ? "api-key"
                 : null;
    for (const id of ["sub-result", "anthropic-key-result"]) {
      const el = $("#" + id);
      if (!el) continue;
      // Don't clobber a result message we just set ourselves; only add an
      // "active" hint when there isn't a recent action result.
      if (!el.dataset.user) {
        if ((id === "sub-result" && active === "subscription") ||
            (id === "anthropic-key-result" && active === "api-key")) {
          el.innerHTML = '<span class="text-blue-700">▸ Currently active in Goose.</span>';
        } else if (active) {
          el.innerHTML = "";
        }
      }
    }
  } catch (e) { /* ignore */ }
}


// ─── OAuth wizard (Path A) ─────────────────────────────────────────
//
// The backend orchestrates the `claude` CLI through a PTY: spawns it,
// captures the OAuth URL, asks us for the verification code, then watches
// for success. We just show a clean 4-step wizard.
let oauthWS = null;

function showOauthStep(name) {
  $$("[data-oauth-step]").forEach(el => {
    el.classList.toggle("hidden", el.dataset.oauthStep !== name);
  });
}

function openOauthModal() {
  $("#oauth-modal").classList.remove("hidden");
  showOauthStep("connecting");
  $("#oauth-code-input").value = "";
  $("#oauth-debug").textContent = "";
  if (oauthWS) { try { oauthWS.close(); } catch (e) {} }
  const proto = location.protocol === "https:" ? "wss:" : "ws:";
  oauthWS = new WebSocket(`${proto}//${location.host}/ws/claude/login`);
  oauthWS.onmessage = (ev) => {
    const msg = JSON.parse(ev.data);
    if (msg.type === "state") {
      handleOauthState(msg);
    } else if (msg.type === "raw") {
      const dbg = $("#oauth-debug");
      dbg.textContent += msg.data;
      // keep last ~10KB
      if (dbg.textContent.length > 10000) {
        dbg.textContent = dbg.textContent.slice(-10000);
      }
      dbg.scrollTop = dbg.scrollHeight;
    }
  };
  oauthWS.onerror = () => {
    showOauthStep("failed");
    $("#oauth-fail-reason").textContent = "WebSocket connection failed.";
  };
  oauthWS.onclose = () => { oauthWS = null; refreshAuth(); };
}

function closeOauthModal() {
  if (oauthWS) {
    try { oauthWS.send(JSON.stringify({ type: "cancel" })); } catch (e) {}
    try { oauthWS.close(); } catch (e) {}
    oauthWS = null;
  }
  $("#oauth-modal").classList.add("hidden");
  refreshAuth();
}

function handleOauthState(msg) {
  switch (msg.state) {
    case "connecting":
      showOauthStep("connecting");
      break;
    case "url_ready":
      showOauthStep("url_ready");
      $("#oauth-url").href = msg.url;
      $("#oauth-url-text").textContent = msg.url;
      $$('[data-oauth-substep="waiting"]').forEach(e => e.classList.add("hidden"));
      break;
    case "waiting_code":
      // Already showing url_ready; show the helper hint that claude is now
      // ready for code input.
      showOauthStep("url_ready");
      $$('[data-oauth-substep="waiting"]').forEach(e => e.classList.remove("hidden"));
      break;
    case "verifying":
      showOauthStep("verifying");
      break;
    case "success":
      showOauthStep("success");
      // Auto-switch goose provider to subscription path.
      fetch("/api/anthropic/use-subscription", { method: "POST" }).catch(()=>{});
      break;
    case "failed":
      showOauthStep("failed");
      $("#oauth-fail-reason").textContent = msg.reason || "(unknown)";
      break;
  }
}

$("#oauth-start").addEventListener("click", openOauthModal);
$("#oauth-close").addEventListener("click", closeOauthModal);
$("#oauth-close-failed").addEventListener("click", closeOauthModal);
$("#oauth-finish").addEventListener("click", closeOauthModal);
$("#oauth-retry").addEventListener("click", openOauthModal);

$("#oauth-code-form").addEventListener("submit", (e) => {
  e.preventDefault();
  const code = $("#oauth-code-input").value.trim();
  if (!code || !oauthWS || oauthWS.readyState !== WebSocket.OPEN) return;
  oauthWS.send(JSON.stringify({ type: "submit_code", code }));
  showOauthStep("verifying");
});




// ─── Anthropic API key form ────────────────────────────────────────
$("#anthropic-key-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const data = Object.fromEntries(new FormData(e.target).entries());
  const result = $("#anthropic-key-result");
  result.dataset.user = "1";
  result.textContent = "Saving & verifying...";
  try {
    const r = await fetch("/api/anthropic/key", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(data),
    }).then(r => r.json());
    if (r.ok) {
      result.innerHTML = '<span class="text-green-700">✓ API key saved and verified against api.anthropic.com.</span>';
      e.target.reset();
    } else {
      const err = (r.error || "").toString();
      let hint = "Bad key, no credits, rate-limited, or network blocked.";
      if (err.includes("401")) hint = "401 Unauthorized — the key is invalid or revoked.";
      else if (err.includes("402")) hint = "402 — billing issue / no credits on the account.";
      else if (err.includes("429")) hint = "429 — rate-limited; try again in a moment.";
      else if (err.includes("403")) hint = "403 Forbidden — key may lack access to this model/region.";
      result.innerHTML = `<span class="text-red-700">✗ Saved, but verification failed. ${hint}</span>` +
                        (err ? `<div class="mt-1 text-slate-500 break-all">${err}</div>` : "");
    }
    refreshAuth();
  } catch (err) {
    result.innerHTML = `<span class="text-red-700">error: ${err.message}</span>`;
  }
});

$("#anthropic-key-clear").addEventListener("click", async () => {
  if (!confirm("Remove the saved Anthropic API key from this container?")) return;
  await fetch("/api/anthropic/key", { method: "DELETE" }).then(r => r.json());
  $("#anthropic-key-result").textContent = "";
  refreshAuth();
});


// ─── LLM provider toggle + Local LLM form ──────────────────────────
// Two providers can be configured at any time; only one is active in goose.
// /api/llm/status reports which kind is active and what's configured.

function _llmResult(msg, kind) {
  // kind: "ok" | "err" | "info"
  const el = $("#local-llm-result");
  if (!el) return;
  el.className = "mt-3 text-xs " + (
    kind === "ok"  ? "text-emerald-700" :
    kind === "err" ? "text-red-700"    :
                     "text-slate-600"
  );
  el.textContent = msg;
}

async function refreshLlmStatus() {
  // Drive the top toggle bar and the Local LLM form's saved state.
  let status, local;
  try {
    status = await fetch("/api/llm/status").then(r => r.json());
  } catch (e) { return; }
  try {
    local = await fetch("/api/llm/local/status").then(r => r.json());
  } catch (e) { local = { configured: false, is_active: false, config: null }; }

  const bar = $("#llm-provider-status");
  if (bar) {
    if (status.active_kind === "anthropic") {
      bar.innerHTML = `<span class="text-emerald-700">● Anthropic active</span>
        <span class="text-slate-400">(${status.active_provider})</span>`;
    } else if (status.active_kind === "local") {
      bar.innerHTML = `<span class="text-emerald-700">● Local LLM active</span>
        <span class="text-slate-400">(${status.active_provider})</span>`;
    } else {
      bar.innerHTML = `<span class="text-amber-600">○ No provider configured</span>`;
    }
  }

  // Pre-populate the form with last-saved config so the operator can tweak
  // and re-save without re-typing the endpoint.
  const cfg = local.config;
  if (cfg) {
    const form = $("#local-llm-form");
    if (form) {
      form.elements["provider_type"].value = cfg.provider_type;
      form.elements["endpoint_url"].value  = cfg.endpoint_url;
      form.elements["verify_tls"].checked  = cfg.verify_tls;
      // Show the saved model name in the dropdown without re-detecting.
      const sel = $("#local-llm-model");
      if (sel && cfg.model_name) {
        sel.innerHTML = `<option value="${cfg.model_name}">${cfg.model_name} (saved)</option>`;
        sel.disabled = false;
      }
    }
  }
}

// "Detect models" — probe the endpoint, populate the model dropdown.
$("#local-llm-detect")?.addEventListener("click", async () => {
  const form = $("#local-llm-form");
  const data = Object.fromEntries(new FormData(form).entries());
  data.verify_tls = form.elements["verify_tls"].checked;
  // model_name not needed for test — drop it
  delete data.model_name;
  if (!data.endpoint_url) { _llmResult("Endpoint URL is required", "err"); return; }

  _llmResult("Probing endpoint…", "info");
  try {
    const r = await fetch("/api/llm/local/test", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(data),
    }).then(r => r.json());

    if (!r.ok) {
      _llmResult(`✗ ${r.error || "connection failed"}`, "err");
      return;
    }
    const sel = $("#local-llm-model");
    sel.disabled = false;
    if (!r.models.length) {
      sel.innerHTML = `<option value="">— no models found on the server —</option>`;
      _llmResult("Connected, but the server reports zero models. Pull/serve a model first.", "err");
      return;
    }
    sel.innerHTML = r.models
      .map(m => `<option value="${m}">${m}</option>`)
      .join("");
    _llmResult(`✓ Connected — ${r.models.length} model(s) available`, "ok");
  } catch (e) {
    _llmResult(`✗ ${e.message || "network error"}`, "err");
  }
});

// Helper used by both "Save" and "Save & Activate" — gathers, posts, returns result.
async function _saveLocalLlm() {
  const form = $("#local-llm-form");
  const data = Object.fromEntries(new FormData(form).entries());
  data.verify_tls = form.elements["verify_tls"].checked;
  if (!data.model_name) {
    _llmResult("Pick a model first (click 'Detect models' to populate the list)", "err");
    return null;
  }
  if (!data.api_key) delete data.api_key;
  try {
    const r = await fetch("/api/llm/local/save", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(data),
    });
    if (!r.ok) {
      const err = await r.json().catch(() => ({ detail: "save failed" }));
      _llmResult(`✗ ${err.detail || "save failed"}`, "err");
      return null;
    }
    return await r.json();
  } catch (e) {
    _llmResult(`✗ ${e.message || "network error"}`, "err");
    return null;
  }
}

// "Save" — persist without switching provider.
$("#local-llm-form")?.addEventListener("submit", async (e) => {
  e.preventDefault();
  const r = await _saveLocalLlm();
  if (r?.ok) {
    _llmResult("✓ Saved. Click 'Use Local LLM' above to activate.", "ok");
    refreshLlmStatus();
  }
});

// "Save & Activate" — save + flip goose to this provider in one click.
$("#local-llm-activate-after-save")?.addEventListener("click", async () => {
  const saveRes = await _saveLocalLlm();
  if (!saveRes?.ok) return;
  try {
    const r = await fetch("/api/llm/local/activate", { method: "POST" })
      .then(r => r.json());
    if (r.ok) {
      _llmResult(`✓ Saved and activated. goose provider: ${r.active_provider} · model: ${r.model}`, "ok");
    } else {
      _llmResult(`✗ ${r.detail || "activate failed"}`, "err");
    }
  } catch (e) {
    _llmResult(`✗ ${e.message || "network error"}`, "err");
  }
  refreshLlmStatus();
});

// Top-bar "Use Anthropic" / "Use Local LLM" — switch active provider.
$("#llm-activate-anthropic")?.addEventListener("click", async () => {
  try {
    const r = await fetch("/api/llm/anthropic/activate", { method: "POST" });
    if (!r.ok) {
      const err = await r.json().catch(() => ({ detail: "activate failed" }));
      alert(err.detail || "Could not activate Anthropic");
    }
  } catch (e) { alert(e.message); }
  refreshLlmStatus();
  refreshAuth();
});

$("#llm-activate-local")?.addEventListener("click", async () => {
  try {
    const r = await fetch("/api/llm/local/activate", { method: "POST" });
    if (!r.ok) {
      const err = await r.json().catch(() => ({ detail: "activate failed" }));
      alert(err.detail || "Could not activate Local LLM (configure and Save first)");
    }
  } catch (e) { alert(e.message); }
  refreshLlmStatus();
  refreshAuth();
});

// Refresh provider status on page load + every time user opens Setup tab.
refreshLlmStatus();


// ─── AWS credentials form ──────────────────────────────────────────
$("#aws-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const form = e.target;
  const data = Object.fromEntries(new FormData(form).entries());
  if (!data.session_token) delete data.session_token;
  if (!data.expected_account_id) delete data.expected_account_id;
  const result = $("#aws-result");
  result.textContent = "Saving...";
  try {
    const r = await fetch("/api/aws/credentials", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(data),
    }).then(r => r.json());
    if (!r.identity) {
      result.innerHTML = '<span class="text-red-700">✗ saved but sts-get-caller-identity failed — bad creds?</span>';
      return;
    }
    let html = `<div class="text-green-700 font-semibold">✓ saved</div>` +
               `<div class="text-slate-700 text-xs mt-1 break-all">Account: <code>${r.identity.Account}</code><br>ARN: <code>${r.identity.Arn}</code></div>`;
    if (r.account_matches === false) {
      html += `<div class="mt-2 text-red-700 text-xs">⚠ Account mismatch! You expected <code>${r.expected_account_id}</code> but the credentials belong to <code>${r.actual_account_id}</code>. Double-check before deploying.</div>`;
    } else if (r.account_matches === true) {
      html += `<div class="mt-2 text-green-700 text-xs">✓ Account matches the expected ID.</div>`;
    }
    result.innerHTML = html;
    refreshAuth();
  } catch (e) {
    result.innerHTML = `<span class="text-red-700">error: ${e.message}</span>`;
  }
});


// ─── Azure credentials form ────────────────────────────────────────
// The form submits a Service Principal: tenant_id, subscription_id,
// client_id (= appId), client_secret. The backend runs `az login
// --service-principal` and stores the SP env vars in ~/.bashrc so non-
// interactive shells (terragrunt, az inside recipes) pick them up.
const azForm = document.getElementById("azure-form");
if (azForm) {
  azForm.addEventListener("submit", async (e) => {
    e.preventDefault();
    const form = e.target;
    const data = Object.fromEntries(new FormData(form).entries());
    if (!data.expected_subscription_id) delete data.expected_subscription_id;
    if (!data.region) data.region = "eastus";
    const result = document.getElementById("azure-result");
    result.textContent = "Saving + running az login...";
    try {
      const r = await fetch("/api/azure/credentials", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(data),
      }).then(r => r.json());
      if (!r.ok) {
        result.innerHTML = `<span class="text-red-700">✗ ${r.error || "az login failed"}</span>`;
        return;
      }
      const id = r.identity || {};
      let html = `<div class="text-green-700 font-semibold">✓ saved + az login OK</div>` +
                 `<div class="text-slate-700 text-xs mt-1 break-all">` +
                 `Subscription: <code>${id.SubscriptionName || ""}</code> (<code>${id.Subscription || ""}</code>)<br>` +
                 `Tenant: <code>${id.Tenant || ""}</code><br>` +
                 `Principal: <code>${id.User || ""}</code> (${id.UserType || ""})</div>`;
      if (r.subscription_matches === false) {
        html += `<div class="mt-2 text-red-700 text-xs">⚠ Subscription mismatch! Expected <code>${r.expected_subscription_id}</code>, got <code>${r.actual_subscription_id}</code>.</div>`;
      } else if (r.subscription_matches === true) {
        html += `<div class="mt-2 text-green-700 text-xs">✓ Subscription matches the expected ID.</div>`;
      }
      result.innerHTML = html;
      refreshAuth();
    } catch (e) {
      result.innerHTML = `<span class="text-red-700">error: ${e.message}</span>`;
    }
  });
}


// ─── Projects list ─────────────────────────────────────────────────
async function loadProjects() {
  const list = $("#projects-list");
  list.innerHTML = '<div class="text-slate-500">Loading...</div>';
  const projects = await fetch("/api/projects").then(r => r.json());
  if (!projects.length) {
    list.innerHTML = '<div class="text-slate-500 col-span-full">No projects yet. Click "+ New project" to start.</div>';
    return;
  }
  list.innerHTML = "";
  for (const p of projects) {
    const card = document.createElement("div");
    card.className = "project-card";
    const status = p.status || {};
    const flags = ["analyzed","recommended","selected","iac_generated","infra_deployed","app_deployed"]
      .map(f => `<span class="status-pill ${status[f] ? 'done' : ''}">${f.replace("_","-")}${status[f]?"":""}</span>`)
      .join("");
    const cloudBadge = p.cloud
      ? `<span class="text-[10px] px-1.5 py-0.5 rounded bg-slate-100 text-slate-700 font-semibold mr-1">${p.cloud.toUpperCase()}</span>`
      : "";
    card.innerHTML = `
      <div class="font-semibold mb-1">${cloudBadge}${p.repo}</div>
      <div class="text-xs text-slate-500 mb-2 font-mono">${p.region || "—"} / ${p.env || "—"} ${p.infra_option ? "/ " + p.infra_option : ""}</div>
      <div class="flex flex-wrap gap-1">${flags}</div>
    `;
    card.addEventListener("click", () => openProject(p.repo));
    list.appendChild(card);
  }
}
loadProjects();


// ─── New-project modal ─────────────────────────────────────────────
$("#new-project-btn").addEventListener("click", () => openInitModal());
$("#init-cancel").addEventListener("click",  () => $("#init-modal").classList.add("hidden"));

async function openInitModal() {
  $("#init-modal").classList.remove("hidden");
  // Reset the form
  const form = $("#init-form");
  form.reset();
  const sel = $("#init-source-select");
  sel.innerHTML = '<option value="">— loading… —</option>';

  // Load available sources from the container
  try {
    const sources = await fetch("/api/sources").then(r => r.json());
    if (!sources.length) {
      sel.innerHTML = '<option value="" disabled>(no sources detected — drop a repo into devops-ai-ui/sources/ on host)</option>';
      return;
    }
    sel.innerHTML = '<option value="">— pick one —</option>';
    for (const s of sources) {
      const opt = document.createElement("option");
      opt.value = s.container_path;
      opt.dataset.name = s.name;
      const flags = [
        s.has_git ? "git" : "",
        s.has_docker ? "docker" : "",
      ].filter(Boolean).join(" + ");
      opt.textContent = `${s.name}${flags ? "  (" + flags + ")" : ""}`;
      sel.appendChild(opt);
    }
  } catch (e) {
    sel.innerHTML = `<option value="" disabled>error: ${e.message}</option>`;
  }

  // Load cloud registry into the cloud dropdown. Mirrors the Select-step
  // populateCloudOptions; coming-soon entries render disabled. AWS is
  // pre-selected because it's currently the only stable cloud.
  const cloudSel = document.getElementById("init-cloud-select");
  if (cloudSel) {
    cloudSel.innerHTML = '<option value="" disabled>— loading… —</option>';
    let clouds = [];
    try {
      clouds = await fetch("/api/clouds").then(r => r.json());
    } catch (e) {
      clouds = [{ id: "aws", default_skeleton: "ecs-fargate-rds", status: "available", available: true }];
    }
    if (!clouds.length) {
      clouds = [{ id: "aws", default_skeleton: "ecs-fargate-rds", status: "available", available: true }];
    }
    cloudSel.innerHTML = "";
    for (const c of clouds) {
      const opt = document.createElement("option");
      opt.value = c.id;
      const label = c.available
        ? `${c.id.toUpperCase()} (${c.default_skeleton})`
        : `${c.id.toUpperCase()} — coming soon`;
      opt.textContent = label;
      if (!c.available) opt.disabled = true;
      if (c.id === "aws" && c.available) opt.selected = true;
      cloudSel.appendChild(opt);
    }
  }
}

// When user picks a source dir, auto-fill the project name field with
// the dir name (sanitised). User can still override.
$("#init-source-select").addEventListener("change", (e) => {
  const opt = e.target.selectedOptions[0];
  if (!opt || !opt.dataset.name) return;
  const nameInput = $("#init-form input[name='name']");
  if (!nameInput.value) {
    nameInput.value = opt.dataset.name.replace(/[^A-Za-z0-9._-]/g, "-");
  }
});

$("#init-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const data = Object.fromEntries(new FormData(e.target).entries());
  if (!data.source_path) {
    alert("Pick a source repository first.");
    return;
  }
  if (!data.cloud) {
    alert("Pick a target cloud.");
    return;
  }
  $("#init-modal").classList.add("hidden");
  // Open project pane and stream init logs
  currentRepo = data.name;
  showProjectTab();
  $("#project-header").innerHTML = `<div class="text-sm">Initializing <code>${data.name}</code> (cloud=${data.cloud}) from <code>${data.source_path}</code>…</div>`;
  $("#steps-list").innerHTML = "";
  $("#artifacts-list").innerHTML = "";
  await runActionWS("init", data, () => {
    loadProjects();
    openProject(data.name);
  });
});


// ─── Project detail ───────────────────────────────────────────────
$("#back-to-projects").addEventListener("click", () => {
  currentRepo = null;
  $("#project-tab-btn").classList.add("hidden");
  loadProjects();
  showTab("projects");
});

function showProjectTab() {
  $("#project-tab-btn").classList.remove("hidden");
  showTab("project");
}

async function openProject(repo) {
  currentRepo = repo;
  showProjectTab();
  await refreshProject();
}

async function refreshProject() {
  if (!currentRepo) return;
  const data = await fetch(`/api/projects/${currentRepo}`).then(r => r.json());
  renderProjectHeader(data);
  renderSteps(data);
  renderArtifacts(data);
  renderDangerZone(data);
}

function renderProjectHeader(data) {
  const s = data.state || {};
  $("#project-header").innerHTML = `
    <div class="flex justify-between items-start">
      <div>
        <div class="text-xl font-semibold">${s.repo}</div>
        <div class="text-sm text-slate-500 font-mono">
          ${(s.cloud || "aws").toUpperCase()} / ${s.region || "—"} / ${s.env || "—"} / acc ${s.account_id || "—"}
          ${s.extensions ? `<br>extensions: ${s.extensions}` : ""}
        </div>
      </div>
      <div class="text-xs text-slate-500 font-mono">source: ${s.source_path}</div>
    </div>
  `;
}

function stepIsDone(step, data, cloud) {
  cloud = cloud || (data.state || {}).cloud || "aws";
  const status = (data.state || {}).status || {};
  // 1. State-flag based (assess, select, generate-iac, apply-infra, deploy-app)
  if (step.sets.length > 0 && step.sets.every(f => status[f])) return true;
  // 2. Artifact-based (plan-infra, audit)
  if (step.artifact) {
    const [dir, ...rest] = step.artifact.split("/");
    const fname = rest.join("/");
    const list = (data[dir] || []);
    if (list.includes(fname)) return true;
  }
  // 3. In-session memory (aws-bootstrap / az-bootstrap — no artifact, no flag)
  if (sessionCompletedActions.has(stepAction(step, cloud))) return true;
  return false;
}

// Resolve a possibly-callable step field (label, action, confirm) against
// the project's cloud. Lets a single STEPS entry render different copy and
// dispatch different bash commands per cloud — no array forking needed.
function resolveStepField(field, cloud) {
  return typeof field === "function" ? field(cloud) : field;
}
function stepAction(step, cloud) {
  return resolveStepField(step.action, cloud);
}

function renderSteps(data) {
  const status = (data.state || {}).status || {};
  const cloud  = (data.state || {}).cloud || "aws";
  const list = $("#steps-list");
  list.innerHTML = "";
  const anyRunning = !!runningAction;
  for (const step of STEPS) {
    const action     = stepAction(step, cloud);
    const label      = resolveStepField(step.label, cloud);
    const isRunning  = (action === runningAction);
    const isDone     = stepIsDone(step, data, cloud);
    const isUnlocked = !step.prereq || status[step.prereq];
    let badge = "locked";
    if (isRunning)      badge = "running";
    else if (isDone)    badge = "done";
    else if (isUnlocked) badge = "available";

    // Button: "Running Ns · Tool" while live, else Run / Re-run
    let buttonText = isDone ? "Re-run" : "Run";
    let extraSubline = "";
    if (isRunning) {
      const sec = Math.floor((Date.now() - runningStartedAt) / 1000);
      const pctSuffix = runningProgressSuffix(sec);
      buttonText = `Running ${sec}s${pctSuffix}${runningLastTool ? " · " + runningLastTool : ""}`;
      extraSubline = `<div class="text-xs text-amber-600 font-mono mt-0.5">▸ ${runningLastTool || "starting…"}</div>`;
    } else {
      // Show duration of last successful run (per project+action), if any.
      const last = currentRepo ? getLastRun(currentRepo, action) : null;
      if (last) {
        const tokenSuffix = last.tokens ? ` · ${last.tokens} tokens` : "";
        extraSubline = `<div class="text-xs text-slate-400 font-mono mt-0.5">last run: ${fmtSec(last.seconds)}${tokenSuffix}</div>`;
      }
    }
    // Disabled if locked, or if some OTHER recipe is currently running
    const disabled = badge === "locked" || (anyRunning && !isRunning) || isRunning;

    const row = document.createElement("div");
    row.className = "step-row" + (badge === "locked" ? " locked" : "");
    row.innerHTML = `
      <span class="badge ${badge}"></span>
      <div>
        <div class="font-medium">${label}</div>
        <div class="text-xs text-slate-500 font-mono">${action}</div>
        ${extraSubline}
      </div>
      <button data-action="${action}" ${disabled ? "disabled" : ""}>
        ${buttonText}
      </button>
    `;
    row.querySelector("button").addEventListener("click", () => triggerStep(step, cloud));
    list.appendChild(row);
  }
}

// Live-update the running step's row text without a full DOM rebuild —
// avoids blowing away artifacts/danger zone state every second.
function tickRunningStepRow() {
  if (!runningAction) return;
  $$("#steps-list .step-row").forEach(row => {
    const btn = row.querySelector("button");
    if (!btn || btn.dataset.action !== runningAction) return;
    const sec = Math.floor((Date.now() - runningStartedAt) / 1000);
    const pctSuffix = runningProgressSuffix(sec);
    btn.textContent = `Running ${sec}s${pctSuffix}${runningLastTool ? " · " + runningLastTool : ""}`;
    const sub = row.querySelector(".text-amber-600");
    if (sub) sub.textContent = `▸ ${runningLastTool || "starting…"}`;
  });
}

function renderArtifacts(data) {
  // Sort each group: 0X_ prefixes naturally collate to workflow order
  // (00_overview → 01_review → 02_audit; deploy_attempts has no prefix).
  // and 03_runbook were removed — assess writes a single combined overview
  // and select no longer renders a runbook.
  //
  // The IaC tree (`data.iac`) is intentionally NOT rendered here. It often
  // has 50+ files across modules/ + environments/ — the operator never
  // needs to read them directly; what matters is the human-readable
  // plan_summary.md that infra-plan produces. We still load it server-side
  // (kept for `openFile()` deep-links if needed) but hide it from the panel.
  const docs   = (data.docs   || []).slice().sort();
  const deploy = (data.deploy || []).slice().sort();

  const list = $("#artifacts-list");
  if (!docs.length && !deploy.length) {
    list.innerHTML = '<div class="text-slate-500">No artifacts yet.</div>';
    return;
  }
  list.innerHTML = "";

  const renderGroup = (kind, files, opts = {}) => {
    if (!files.length) return;
    const collapsible = !!opts.collapsible;

    if (collapsible) {
      // <details>/<summary> — native HTML disclosure, no extra state.
      // Default closed for IaC (often 50+ files; otherwise floods the panel
      // and gets confused with docs/deploy in the same column).
      const det = document.createElement("details");
      det.open = false;
      const sum = document.createElement("summary");
      sum.className = "font-semibold mt-2 text-xs text-slate-400 uppercase cursor-pointer select-none hover:text-slate-600";
      sum.textContent = `${kind}  (${files.length})`;
      det.appendChild(sum);
      const inner = document.createElement("div");
      inner.className = "ml-2 mt-1";
      for (const f of files) {
        const a = document.createElement("a");
        a.href = "#";
        a.className = "block text-blue-600 hover:underline truncate text-sm";
        a.title = f;
        a.textContent = f;
        a.addEventListener("click", (e) => { e.preventDefault(); openFile(`${kind}/${f}`); });
        inner.appendChild(a);
      }
      det.appendChild(inner);
      list.appendChild(det);
    } else {
      const h = document.createElement("div");
      h.className = "font-semibold mt-2 text-xs text-slate-400 uppercase";
      h.textContent = `${kind}  (${files.length})`;
      list.appendChild(h);
      for (const f of files) {
        const a = document.createElement("a");
        a.href = "#";
        a.className = "block text-blue-600 hover:underline truncate";
        a.title = f;
        a.textContent = f;
        a.addEventListener("click", (e) => { e.preventDefault(); openFile(`${kind}/${f}`); });
        list.appendChild(a);
      }
    }
  };

  // docs / deploy: flat (small lists, ordered by 0X_ prefix per workflow step).
  // iac/ is intentionally hidden — it's machine output, not for human reading.
  renderGroup("docs",   docs);
  renderGroup("deploy", deploy);
}


// ─── Danger zone (destroy infrastructure) ─────────────────────────
function renderDangerZone(data) {
  const zone = $("#danger-zone");
  const reason = $("#destroy-disabled-reason");
  const btn = $("#destroy-btn");
  const s = (data.state || {});
  const status = s.status || {};
  // Show as soon as IaC exists — a partial/failed apply may have created
  // real resources even though infra_deployed never flipped to true. Hiding
  // the button in that state forces operators into manual cleanup.
  if (!status.iac_generated) {
    zone.classList.add("hidden");
    return;
  }
  zone.classList.remove("hidden");
  // The framework's cmd_destroy refuses non-dev envs as a safety guardrail.
  if (s.env !== "dev") {
    btn.disabled = true;
    btn.classList.add("opacity-40", "cursor-not-allowed");
    reason.textContent = `Destroy is gated to env=dev only (current: ${s.env}). For stage/prod, use 'terragrunt destroy' manually with extra review.`;
    reason.classList.remove("hidden");
  } else {
    btn.disabled = false;
    btn.classList.remove("opacity-40", "cursor-not-allowed");
    reason.classList.add("hidden");
  }
}

$("#destroy-btn").addEventListener("click", () => {
  if (!currentRepo) return;
  $("#destroy-project-name").textContent = currentRepo;
  $("#destroy-confirm-input").value = "";
  $("#destroy-confirm").disabled = true;
  $("#destroy-modal").classList.remove("hidden");
  // focus input for fast typing
  setTimeout(() => $("#destroy-confirm-input").focus(), 50);
});

$("#destroy-confirm-input").addEventListener("input", (e) => {
  // Enable Destroy only when typed name matches exactly
  $("#destroy-confirm").disabled = (e.target.value !== currentRepo);
});

$("#destroy-cancel").addEventListener("click", () => {
  $("#destroy-modal").classList.add("hidden");
});

$("#destroy-confirm").addEventListener("click", async () => {
  $("#destroy-modal").classList.add("hidden");
  // Stream the destroy via the same WS plumbing as any other action.
  await runActionWS("destroy", {}, () => refreshProject());
});


async function openFile(relPath) {
  $("#file-modal-title").textContent = relPath;
  const r = await fetch(`/api/projects/${currentRepo}/file?path=${encodeURIComponent(relPath)}`);
  const text = await r.text();
  const body = $("#file-modal-body");
  if (relPath.toLowerCase().endsWith(".md") && window.marked) {
    body.className = "flex-1 overflow-auto bg-white p-6 markdown-body";
    body.innerHTML = marked.parse(text);
  } else {
    body.className = "flex-1 overflow-auto bg-slate-50 p-3 text-xs font-mono whitespace-pre-wrap";
    body.textContent = text;
  }
  $("#file-modal").classList.remove("hidden");
}
$("#file-modal-close").addEventListener("click", () => $("#file-modal").classList.add("hidden"));


// ─── Step trigger logic ───────────────────────────────────────────
async function triggerStep(step, cloud) {
  cloud = cloud || "aws";
  const action      = stepAction(step, cloud);
  const confirmText = resolveStepField(step.confirm, cloud);
  if (confirmText && !confirm(confirmText)) return;

  let payload = {};
  if (step.prompt) {
    const result = await step.prompt();
    if (!result) return;
    payload = result;
  }

  // Stream WS
  await runActionWS(action, payload, () => refreshProject());
}

async function runActionWS(action, payload, onDone) {
  // Guard against double-click: if a recipe is already running, refuse a
  // second click rather than killing the running one. Recipes can take
  // 30+ seconds to produce first output (Goose initialisation), and a
  // re-click would terminate the work the user is waiting for.
  if (activeWS && activeWS.readyState !== WebSocket.CLOSED) {
    flashLog("⚠ A recipe is already running. Wait for it to finish, or refresh the page to abort.", "warn");
    return;
  }

  // ── set up running-state markers used by renderSteps + tick
  runningAction     = action;
  runningStartedAt  = Date.now();
  runningLastTool   = "";
  runningTokens     = "";
  runningEtaSec     = 0;
  runningEtaSource  = "";
  runningEtaSamples = 0;

  // Fetch ETA in the background so the progress bar can render as soon as
  // it arrives. Don't block UI on this — if the endpoint is slow or 404s
  // (unknown action), tick falls back to "elapsed Ns" without %.
  fetch(`/api/eta/${encodeURIComponent(action)}`)
    .then(r => r.ok ? r.json() : null)
    .then(eta => {
      if (!eta || runningAction !== action) return; // run already finished
      runningEtaSec     = eta.eta_seconds || 0;
      runningEtaSource  = eta.source || "";
      runningEtaSamples = eta.samples || 0;
    })
    .catch(() => { /* silently fall back to no-% display */ });

  // Re-render steps so the just-clicked row goes to "running" badge + the
  // others get disabled. Falls back gracefully if there's no current data.
  if (currentRepo) refreshProject();

  const log = $("#log-pane");
  log.innerHTML = `<div class="text-yellow-300">▸ starting ${action}... (Goose may take 10–30s before first output)</div>`;
  const runningHint = document.createElement("div");
  runningHint.id = "log-running-hint";
  runningHint.className = "log-line text-yellow-200 italic";
  runningHint.textContent = `▸ running ${action} (0s elapsed)…`;
  log.appendChild(runningHint);

  // 1-second tick: updates the inline log hint AND the step-row button text
  const tick = setInterval(() => {
    const sec = Math.floor((Date.now() - runningStartedAt) / 1000);
    const pctSuffix = runningProgressSuffix(sec);
    const hint = $("#log-running-hint");
    if (hint) hint.textContent = `▸ running ${action} (${sec}s elapsed${pctSuffix})${runningLastTool ? " · " + runningLastTool : ""}…`;
    tickRunningStepRow();
  }, 1000);

  const proto = location.protocol === "https:" ? "wss:" : "ws:";
  const ws = new WebSocket(`${proto}//${location.host}/ws/run/${action}`);
  activeWS = ws;
  ws.onopen = () => ws.send(JSON.stringify({ repo: currentRepo, payload }));
  ws.onmessage = (ev) => {
    const msg = JSON.parse(ev.data);
    const line = document.createElement("div");
    line.className = "log-line";
    if (msg.type === "started")  { line.textContent = `$ ${msg.cmd}`; line.className += " ok"; }
    else if (msg.type === "line") {
      line.textContent = msg.data;
      // Detect Goose tool calls printed as "  ▸ Tool name" — surface the
      // last one as a live indicator on the step row + log hint.
      const toolMatch = msg.data.match(/▸\s+([A-Za-z][\w\s\-]+?)\s*$/);
      if (toolMatch) {
        runningLastTool = toolMatch[1].trim();
        tickRunningStepRow();
      }
      // Capture token count from the shell's _print_token_usage line:
      //   "    tokens: 2.3M (session 20260507_2)"
      // This line is emitted by `run_recipe` after every goose recipe
      // (success or failure). Save the latest match so multi-recipe
      // commands (e.g. plan-infra → apply-infra chained) end up with the
      // most recent recipe's tokens — matches what the user sees in the
      // log tail.
      const tokMatch = msg.data.match(/tokens:\s+([\d.]+[KM]?)\s+\(session/);
      if (tokMatch) {
        runningTokens = tokMatch[1];
      }
    }
    else if (msg.type === "exit") {
      line.textContent = `▸ exit code: ${msg.code} (took ${Math.floor((Date.now() - runningStartedAt) / 1000)}s)`;
      line.className += msg.code === 0 ? " ok" : " err";
      runningHint.remove();
      clearInterval(tick);
      // Remember successful runs in-session so steps without state flags
      // or artifacts (e.g. aws-bootstrap) can still show as "done".
      const elapsedSec = Math.floor((Date.now() - runningStartedAt) / 1000);
      if (msg.code === 0) {
        sessionCompletedActions.add(action);
        if (currentRepo) saveLastRun(currentRepo, action, elapsedSec, runningTokens);
      }
      // Clear running state BEFORE refreshProject so steps render fresh.
      runningAction = null;
      runningLastTool = "";
      runningTokens = "";
      runningEtaSec = 0;
      runningEtaSource = "";
      runningEtaSamples = 0;
      if (typeof onDone === "function") onDone();
    }
    else if (msg.type === "error") { line.textContent = `error: ${msg.msg}`; line.className += " err"; }
    else if (msg.type === "run_id") { return; }
    log.appendChild(line);
    log.scrollTop = log.scrollHeight;
  };
  ws.onclose = () => {
    activeWS = null;
    clearInterval(tick);
    // If close happened without an exit message (network drop, server kill),
    // make sure running-state still gets cleared so the UI doesn't stay
    // visually stuck.
    if (runningAction === action) {
      runningAction = null;
      runningLastTool = "";
      if (currentRepo) refreshProject();
    }
  };
  ws.onerror = (e) => {
    const line = document.createElement("div");
    line.className = "log-line err";
    line.textContent = `WebSocket error: ${e.message || "(connection failed)"}`;
    log.appendChild(line);
  };
}

// Step Run-buttons are managed inside renderSteps based on runningAction;
// this helper just toggles the Destroy button which lives outside that loop.
function setStepButtonsDisabled(disabled) {
  const destroy = $("#destroy-btn");
  if (destroy) destroy.disabled = disabled;
}

function flashLog(msg, kind = "warn") {
  const log = $("#log-pane");
  const line = document.createElement("div");
  line.className = "log-line " + (kind === "warn" ? "text-amber-300" : "err");
  line.textContent = msg;
  log.appendChild(line);
  log.scrollTop = log.scrollHeight;
}


// ─── Step prompt: select ───────────────────────────────────────────
//
// `select` writes cloud / region / env / account_id / extensions to
// state.yaml. By the time the user reaches this step:
//   - cloud      was chosen at "+ New project" (init)
//   - region     was entered when saving AWS or Azure creds in Setup
//   - account_id is auto-discoverable from the active credentials
//   - env        is "dev" — the only option the skeletons ship
// So this modal asks ONLY for the genuine per-project choice: opt-in
// extensions. Everything else is shown as a read-only summary, with an
// optional "Advanced — override" expander for the rare overrides.
async function promptSelect() {
  // Project's cloud (set at init).
  let projectCloud = "aws";
  try {
    const data = await fetch(`/api/projects/${currentRepo}`).then(r => r.json());
    projectCloud = ((data || {}).state || {}).cloud || "aws";
  } catch (e) { /* fallthrough */ }

  // Defaults from Setup tab — region from credentials, account/subscription
  // from active identity. Keeps the modal a 1-click confirm in the common case.
  let region = "";
  let accountLabel = "";
  let accountValue = "";
  let accountField = "account_id";
  try {
    const h = await fetch("/api/health").then(r => r.json());
    if (projectCloud === "azure") {
      region        = h?.azure_default_region || "eastus";
      accountValue  = h?.azure?.Subscription || "";
      accountLabel  = h?.azure?.SubscriptionName
                       ? `${h.azure.SubscriptionName} (${accountValue})`
                       : accountValue;
      // cmd_select still uses --account-id; for Azure we pass the
      // subscription id through that same channel for the selection-
      // record / sanity-check path. Storing it lets the project header
      // show subscription on the card.
    } else {
      region        = h?.aws_default_region || "us-east-1";
      accountValue  = h?.aws?.Account || "";
      accountLabel  = accountValue;
    }
  } catch (e) { /* leave defaults */ }

  // Cloud-specific extension catalog (informational).
  const extensions = projectCloud === "azure"
    ? ["redis", "queue", "frontend", "keycloak", "custom-domain-https"]
    : ["redis", "queue", "frontend", "keycloak", "alb-https"];

  return new Promise((resolve) => {
    const m = $("#step-modal");
    $("#step-modal-title").textContent = "Pick extensions and lock the choice";
    $("#step-modal-body").innerHTML = `
      <form id="select-form" class="space-y-3">

        <!-- Read-only summary of what's already known -->
        <div class="rounded border bg-slate-50 p-3 text-xs font-mono leading-relaxed">
          <div><span class="text-slate-500">cloud   :</span> ${projectCloud.toUpperCase()}</div>
          <div><span class="text-slate-500">region  :</span> ${region || "<not set — open Setup tab first>"}</div>
          <div><span class="text-slate-500">env     :</span> dev</div>
          <div><span class="text-slate-500">${projectCloud === "azure" ? "subscription" : "account     "}:</span> ${accountLabel || "<not detected>"}</div>
        </div>

        <!-- Hidden inputs feed cmd_select; values come from above + override section -->
        <input type="hidden" name="cloud"      value="${projectCloud}">
        <input type="hidden" name="region"     id="select-region"     value="${region}">
        <input type="hidden" name="env"        value="dev">
        <input type="hidden" name="account_id" id="select-account-id" value="${accountValue}">

        <!-- The actual choice: extensions -->
        <label class="block text-xs font-medium text-slate-700">
          Opt-in extensions
          <span class="text-slate-400 font-normal">(csv, optional)</span>
        </label>
        <input name="include" placeholder="e.g. redis,queue"
               class="w-full border rounded px-3 py-2 text-sm font-mono">
        <p class="text-xs text-slate-400">
          Available for ${projectCloud.toUpperCase()}: ${extensions.join(", ")}.
          Read <code>docs/00_overview.md</code> (the "Deployment fit" section) —
          assess already recommended which ones this app needs.
        </p>

        <!-- Advanced expander — rarely needed -->
        <details class="text-xs">
          <summary class="cursor-pointer text-slate-500 select-none">Advanced — override region or ${projectCloud === "azure" ? "subscription" : "account"} ID</summary>
          <div class="mt-2 space-y-2">
            <input id="select-region-override" placeholder="override region"
                   value="${region}"
                   class="w-full border rounded px-3 py-2 text-sm font-mono">
            <input id="select-account-override"
                   placeholder="override ${projectCloud === "azure" ? "subscription id" : "account id"}"
                   value="${accountValue}"
                   class="w-full border rounded px-3 py-2 text-sm font-mono">
            <p class="text-slate-400">Leave blank to keep the values shown above (from Setup tab).</p>
          </div>
        </details>

        <div class="flex gap-2 pt-2">
          <button type="submit" class="bg-blue-600 text-white px-4 py-2 rounded text-sm flex-1">Lock</button>
          <button type="button" id="select-cancel" class="bg-slate-200 px-4 py-2 rounded text-sm">Cancel</button>
        </div>
      </form>
    `;
    m.classList.remove("hidden");

    // Sync overrides into the hidden fields on submit.
    $("#select-form").addEventListener("submit", (e) => {
      e.preventDefault();
      const ovRegion  = (document.getElementById("select-region-override") || {}).value;
      const ovAccount = (document.getElementById("select-account-override") || {}).value;
      if (ovRegion  && ovRegion.trim())  document.getElementById("select-region").value     = ovRegion.trim();
      if (ovAccount && ovAccount.trim()) document.getElementById("select-account-id").value = ovAccount.trim();

      const data = Object.fromEntries(new FormData(e.target).entries());
      if (!data.account_id) delete data.account_id;
      if (!data.include)    delete data.include;
      m.classList.add("hidden");
      resolve(data);
    });
    $("#select-cancel").addEventListener("click", () => {
      m.classList.add("hidden");
      resolve(null);
    });
  });
}


// ─── Periodic state refresh while a step is running ───────────────
setInterval(() => { if (currentRepo && activeWS) refreshProject(); }, 5000);
