"""
FastAPI backend for devops-ai-ui — wraps the bash framework with HTTP/WebSocket.
Each user action triggers a subprocess; stdout/stderr stream over WebSocket.

Auth supports two paths:
  * Claude Max subscription (OAuth): the backend orchestrates `claude` CLI
    over a PTY, pulls the OAuth URL out of its output, and forwards the
    user-provided verification code back. The UI sees only the URL and a
    text input — no xterm needed.
  * Anthropic API key: `sk-ant-...` saved to env + ~/.bashrc; verified via
    /v1/models against api.anthropic.com.
"""
import asyncio
import fcntl
import json
import os
import pty
import re
import select
import shlex
import signal
import struct
import subprocess
import termios
import urllib.error
import urllib.request
from pathlib import Path
from typing import Optional

import yaml
from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, HTMLResponse, PlainTextResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

ROOT = Path(os.environ.get("DEVOPS_AI_ROOT", "/workspace"))
FRAMEWORK = Path(os.environ.get("FRAMEWORK_DIR", "/workspace/framework"))
PROJECTS_DIR = ROOT / "projects"
CLI = FRAMEWORK / "devops-ai.sh"

app = FastAPI(title="devops-ai-ui", version="0.1.0")

FRONTEND_DIR = Path(__file__).parent.parent / "frontend"


# ─── helpers ─────────────────────────────────────────────────────────

def safe_repo(name: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9._-]+", name or ""):
        raise HTTPException(400, f"Invalid project name: {name!r}")
    return name


def project_dir(repo: str) -> Path:
    return PROJECTS_DIR / safe_repo(repo)


def read_state(repo: str) -> dict:
    f = project_dir(repo) / "state.yaml"
    if not f.exists():
        raise HTTPException(404, f"Project {repo!r} not initialized")
    return yaml.safe_load(f.read_text()) or {}


def list_projects() -> list[dict]:
    if not PROJECTS_DIR.exists():
        return []
    out = []
    for p in sorted(PROJECTS_DIR.iterdir()):
        if not p.is_dir():
            continue
        sf = p / "state.yaml"
        if not sf.exists():
            continue
        try:
            state = yaml.safe_load(sf.read_text()) or {}
            state["_dir"] = str(p)
            out.append(state)
        except Exception:
            continue
    return out


def aws_identity() -> Optional[dict]:
    try:
        r = subprocess.run(
            ["aws", "sts", "get-caller-identity", "--output", "json"],
            capture_output=True, text=True, timeout=10,
        )
        if r.returncode == 0:
            return json.loads(r.stdout)
    except Exception:
        pass
    return None


def azure_identity() -> Optional[dict]:
    """Returns the active Azure principal as `az account show` would, or None
    if `az` is missing / not authenticated. Mirror of `aws_identity()`."""
    try:
        r = subprocess.run(
            ["az", "account", "show", "--output", "json"],
            capture_output=True, text=True, timeout=10,
        )
        if r.returncode == 0:
            data = json.loads(r.stdout)
            # Normalize to the same flat shape as aws_identity()
            return {
                "Tenant":         data.get("tenantId"),
                "Subscription":   data.get("id"),
                "SubscriptionName": data.get("name"),
                "User":           (data.get("user") or {}).get("name"),
                "UserType":       (data.get("user") or {}).get("type"),
            }
    except Exception:
        pass
    return None


def aws_default_region() -> Optional[str]:
    """Resolve the operator's default AWS region. Order: AWS_REGION env,
    AWS_DEFAULT_REGION, ~/.aws/config [default] region. Returns None if
    nothing is set."""
    for k in ("AWS_REGION", "AWS_DEFAULT_REGION"):
        v = os.environ.get(k, "").strip()
        if v:
            return v
    cfg = Path.home() / ".aws" / "config"
    if cfg.exists():
        in_default = False
        for line in cfg.read_text(errors="replace").splitlines():
            s = line.strip()
            if s.startswith("[") and s.endswith("]"):
                in_default = (s == "[default]")
                continue
            if in_default and s.startswith("region"):
                _, _, val = s.partition("=")
                if val.strip():
                    return val.strip()
    return None


def azure_default_region() -> Optional[str]:
    """Resolve the operator's default Azure location. Set by the Save & az
    login step in the UI (writes AZURE_DEFAULTS_LOCATION to ~/.bashrc)."""
    v = os.environ.get("AZURE_DEFAULTS_LOCATION", "").strip()
    if v:
        return v
    # Read from ~/.bashrc as fallback (env may not have re-sourced).
    bashrc = Path.home() / ".bashrc"
    if bashrc.exists():
        for line in bashrc.read_text(errors="replace").splitlines():
            if line.startswith("export AZURE_DEFAULTS_LOCATION="):
                _, _, val = line.partition("=")
                return val.strip().strip('"').strip("'")
    return None


def api_key_works() -> tuple[bool, Optional[str]]:
    """
    Verify ANTHROPIC_API_KEY directly against Anthropic /v1/models. Cheap
    (no tokens charged) and authoritative. Returns (ok, error_msg).
    """
    key = os.environ.get("ANTHROPIC_API_KEY", "").strip()
    if not key:
        return False, "no API key set"
    try:
        req = urllib.request.Request(
            "https://api.anthropic.com/v1/models",
            headers={
                "x-api-key": key,
                "anthropic-version": "2023-06-01",
            },
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            return (resp.status == 200), (None if resp.status == 200 else f"HTTP {resp.status}")
    except urllib.error.HTTPError as e:
        body = ""
        try:
            body = e.read().decode("utf-8", errors="replace")[:300]
        except Exception:
            pass
        return False, f"HTTP {e.code}: {body or e.reason}"
    except Exception as e:
        return False, f"{type(e).__name__}: {e}"


def subscription_works() -> bool:
    """Verify the host-mounted ~/.claude/ OAuth credentials let `claude` run."""
    if not (Path.home() / ".claude").exists():
        return False
    try:
        # `claude --print` is interactive-CLI's headless mode; uses OAuth
        # creds from ~/.claude/. Tiny "ok" prompt, ignores ANTHROPIC_API_KEY
        # if claude prefers OAuth.
        env = {**os.environ}
        env.pop("ANTHROPIC_API_KEY", None)  # force subscription-only path
        r = subprocess.run(
            ["claude", "--print", "--model", "claude-opus-4-7", "ok"],
            capture_output=True, text=True, timeout=15, env=env,
        )
        return r.returncode == 0 and bool(r.stdout.strip())
    except Exception:
        return False


def current_auth() -> dict:
    """Snapshot of which paths work right now."""
    sub = subscription_works()
    api_ok, api_err = api_key_works()
    # Pick the active mode: prefer whichever the goose config says,
    # falling back to whatever works.
    cfg = Path.home() / ".config" / "goose" / "config.yaml"
    provider = ""
    if cfg.exists():
        for line in cfg.read_text().splitlines():
            if line.startswith("GOOSE_PROVIDER:"):
                provider = line.split(":", 1)[1].strip()
                break
    return {
        "subscription_works": sub,
        "api_key_works": api_ok,
        "api_key_error": api_err if not api_ok else None,
        "current_provider": provider,
    }


# Backwards-compatible name used in /api/health below.
def claude_authenticated() -> bool:
    return subscription_works() or api_key_works()[0]


# ─── HTTP endpoints ──────────────────────────────────────────────────

@app.get("/")
def index() -> HTMLResponse:
    return HTMLResponse((FRONTEND_DIR / "index.html").read_text())


@app.get("/api/health")
def health() -> dict:
    aws_id  = aws_identity()
    az_id   = azure_identity()
    aws_reg = aws_default_region()
    az_reg  = azure_default_region()
    return {
        "ok": True,
        "framework": str(FRAMEWORK),
        "projects_dir": str(PROJECTS_DIR),
        "aws": aws_id,
        "aws_authenticated": aws_id is not None,
        "aws_default_region": aws_reg,
        "azure": az_id,
        "azure_authenticated": az_id is not None,
        "azure_default_region": az_reg,
        "claude_authenticated": claude_authenticated(),
    }


@app.get("/api/projects")
def projects_list() -> list[dict]:
    return list_projects()


# Cloud registry — read from framework/templates/iac/clouds.yaml.
# Returns a list shaped for the UI dropdown:
#   [{ id, default_skeleton, status, available }]
# `available` is the boolean form of status=="available", convenient for the
# frontend to disable/enable options. We parse YAML manually with a tiny shim
# (no PyYAML dep in this image). Format is intentionally flat so a one-pass
# state-machine works.
@app.get("/api/clouds")
def clouds_list() -> list[dict]:
    registry = FRAMEWORK / "templates" / "iac" / "clouds.yaml"
    out: list[dict] = []
    if not registry.exists():
        return out
    try:
        text = registry.read_text(encoding="utf-8")
    except OSError:
        return out
    cur: Optional[dict] = None
    for raw in text.splitlines():
        line = raw.rstrip()
        if not line or line.lstrip().startswith("#"):
            continue
        if not line.startswith(" "):  # top-level key (cloud id)
            cid = line.rstrip(":").strip()
            if cid:
                cur = {"id": cid}
                out.append(cur)
        else:                         # indented k: v under current cloud
            if cur is None:
                continue
            stripped = line.strip()
            if ":" not in stripped:
                continue
            k, _, v = stripped.partition(":")
            cur[k.strip()] = v.strip()
    for c in out:
        c["available"] = (c.get("status") == "available")
    return out


# Source repos are mounted from the host into /workspace/sources via the
# docker-compose volume. This endpoint just lists what's there so the UI
# can show a dropdown — users don't need to figure out container paths.
@app.get("/api/sources")
def list_sources() -> list[dict]:
    sources_root = Path("/workspace/sources")
    if not sources_root.exists():
        return []
    out = []
    for p in sorted(sources_root.iterdir()):
        if not p.is_dir() or p.name.startswith("."):
            continue
        try:
            has_git = (p / ".git").exists()
            has_docker = any((p / n).exists() for n in
                             ("Dockerfile", "docker-compose.yml", "docker-compose.yaml"))
        except Exception:
            has_git = has_docker = False
        out.append({
            "name": p.name,
            "container_path": str(p),         # what to pass to init
            "host_hint": f"~/.../{p.parent.name}/{p.name}",  # for human display
            "has_git": has_git,
            "has_docker": has_docker,
        })
    return out


@app.get("/api/projects/{repo}")
def project_get(repo: str) -> dict:
    state = read_state(repo)
    pdir = project_dir(repo)
    docs = sorted(p.name for p in (pdir / "docs").glob("*.md")) if (pdir / "docs").exists() else []
    iac_files = []
    iac_root = pdir / "iac"
    if iac_root.exists():
        for f in iac_root.rglob("*"):
            if not f.is_file():
                continue
            rel = str(f.relative_to(iac_root))
            if "/.terragrunt-cache/" in "/" + rel or "/.terraform/" in "/" + rel:
                continue
            if f.suffix in (".hcl", ".tf", ".yaml", ".md"):
                iac_files.append(rel)
    deploy_dir = pdir / "deploy"
    deploy_files = (
        sorted(p.name for p in deploy_dir.iterdir() if p.is_file())
        if deploy_dir.exists() else []
    )
    return {
        "state": state,
        "docs": docs,
        "iac": sorted(iac_files)[:200],  # cap to avoid mega-payloads
        "deploy": deploy_files,
    }


@app.get("/api/projects/{repo}/file")
def project_file(repo: str, path: str) -> PlainTextResponse:
    """Serve any text file under projects/<repo>/. Path is relative."""
    base = project_dir(repo).resolve()
    target = (base / path).resolve()
    if not str(target).startswith(str(base)):
        raise HTTPException(400, "Path traversal denied")
    if not target.exists() or not target.is_file():
        raise HTTPException(404, f"File not found: {path}")
    try:
        return PlainTextResponse(target.read_text())
    except UnicodeDecodeError:
        return PlainTextResponse(f"<binary file {target.stat().st_size} bytes>")


# ─── command execution + log streaming ───────────────────────────────

class InitRequest(BaseModel):
    source_path: str
    name: str
    # Cloud is a first-class init-time decision. cmd_init writes it to
    # state.yaml so every downstream step (analyze/assess/recommend included)
    # is cloud-aware from the very first run. Defaults to "aws" for CLI calls
    # that omit it; the UI sets it explicitly via the New project modal.
    cloud: str = "aws"


class SelectRequest(BaseModel):
    # The choice the operator makes is *cloud*, not *architecture*.
    # Each cloud ships exactly one default skeleton, mapped via
    # framework/templates/iac/clouds.yaml. `cmd_select --cloud <id>` resolves
    # the skeleton automatically. AWS is currently the only cloud with
    # status=available; Azure and GCP are registered but coming-soon.
    cloud: str = "aws"
    region: str
    env: str
    account_id: Optional[str] = None
    include: Optional[str] = None  # csv


class AwsCredsRequest(BaseModel):
    access_key_id: str
    secret_access_key: str
    region: str = "us-east-1"
    session_token: Optional[str] = None
    # Optional: user-declared "expected" account ID. If set, the backend
    # cross-checks against `aws sts get-caller-identity` after saving the
    # creds and surfaces a warning if they don't match — protects against
    # accidentally pasting keys from a different AWS account.
    expected_account_id: Optional[str] = None


@app.post("/api/aws/credentials")
def set_aws_creds(req: AwsCredsRequest) -> dict:
    """Write to ~/.aws/credentials and ~/.aws/config inside the container."""
    home = Path.home()
    aws_dir = home / ".aws"
    aws_dir.mkdir(parents=True, exist_ok=True)
    (aws_dir / "credentials").write_text(
        f"[default]\n"
        f"aws_access_key_id = {req.access_key_id}\n"
        f"aws_secret_access_key = {req.secret_access_key}\n"
        + (f"aws_session_token = {req.session_token}\n" if req.session_token else "")
    )
    (aws_dir / "config").write_text(
        f"[default]\nregion = {req.region}\noutput = json\n"
    )
    os.chmod(aws_dir / "credentials", 0o600)

    identity = aws_identity()
    actual_account = (identity or {}).get("Account")
    expected = (req.expected_account_id or "").strip() or None
    match = None
    if expected and actual_account:
        match = (expected == actual_account)
    return {
        "ok": True,
        "identity": identity,
        "expected_account_id": expected,
        "actual_account_id": actual_account,
        "account_matches": match,   # True / False / None (no expected given)
    }


class AzureCredsRequest(BaseModel):
    # Service Principal credentials. The operator creates the SP via
    # `az ad sp create-for-rbac --role Owner --scopes /subscriptions/<sub>`
    # and pastes the four values below. We use SP because admin-user creds
    # often have MFA which doesn't work in headless containers, and because
    # SP keys can be rotated without touching the operator's own identity.
    tenant_id:       str
    subscription_id: str
    client_id:       str         # = appId from `az ad sp create-for-rbac`
    client_secret:   str         # = password from same call
    region:          str = "eastus"
    expected_subscription_id: Optional[str] = None  # cross-check, like AWS


@app.post("/api/azure/credentials")
def set_azure_creds(req: AzureCredsRequest) -> dict:
    """Persist Service Principal creds via env vars in ~/.bashrc and run
    `az login --service-principal` so subsequent `az` calls in the
    container use them. We don't write a static profile file because Azure
    CLI's profile is global to the user and we want isolation per project."""
    # 1) Login the SP into the current process and the persistent token cache.
    try:
        login = subprocess.run(
            [
                "az", "login", "--service-principal",
                "-u", req.client_id,
                "-p", req.client_secret,
                "--tenant", req.tenant_id,
                "--output", "json",
            ],
            capture_output=True, text=True, timeout=30,
        )
        if login.returncode != 0:
            return {
                "ok": False,
                "error": f"az login failed: {login.stderr.strip() or login.stdout.strip()}",
            }
    except Exception as e:
        return {"ok": False, "error": f"az login error: {type(e).__name__}: {e}"}

    # 2) Pin the active subscription.
    try:
        subprocess.run(
            ["az", "account", "set", "--subscription", req.subscription_id],
            capture_output=True, text=True, timeout=15, check=True,
        )
    except subprocess.CalledProcessError as e:
        return {"ok": False, "error": f"az account set failed: {e.stderr.strip()}"}

    # 3) Persist for non-interactive shells. ARM_* env vars are picked up by
    #    the azurerm Terraform provider; AZURE_* by `az` and most SDKs.
    _bashrc_set_env("ARM_TENANT_ID",        req.tenant_id)
    _bashrc_set_env("ARM_SUBSCRIPTION_ID",  req.subscription_id)
    _bashrc_set_env("ARM_CLIENT_ID",        req.client_id)
    _bashrc_set_env("ARM_CLIENT_SECRET",    req.client_secret)
    _bashrc_set_env("AZURE_DEFAULTS_LOCATION", req.region)

    identity = azure_identity()
    actual_sub = (identity or {}).get("Subscription")
    expected = (req.expected_subscription_id or "").strip() or None
    match = (expected == actual_sub) if (expected and actual_sub) else None
    return {
        "ok": True,
        "identity": identity,
        "expected_subscription_id": expected,
        "actual_subscription_id": actual_sub,
        "subscription_matches": match,
    }


# Active subprocesses keyed by run_id; allows cancellation later.
RUNS: dict[str, asyncio.subprocess.Process] = {}


def build_cli_args(action: str, repo: str, payload: dict) -> list[str]:
    """Translate (action, repo, payload) into ./devops-ai.sh CLI invocation."""
    cli = [str(CLI), action]
    if action == "init":
        # init <source-path> --name <repo> --cloud <aws|azure>
        cli = [
            str(CLI), "init",
            payload["source_path"],
            "--name",  payload["name"],
            "--cloud", payload.get("cloud", "aws"),
        ]
        return cli
    cli.append(repo)
    if action == "select":
        # cmd_select resolves cloud → skeleton through clouds.yaml.
        cli += ["--cloud",    payload.get("cloud", "aws")]
        cli += ["--region",   payload["region"]]
        cli += ["--env",      payload["env"]]
        if payload.get("account_id"):
            cli += ["--account-id", payload["account_id"]]
        if payload.get("include"):
            cli += ["--include", payload["include"]]
    return cli


VALID_ACTIONS = {
    "init", "assess", "analyze", "recommend", "select",
    "generate-iac", "review-iac",
    "aws-bootstrap", "az-bootstrap",
    "plan-infra", "apply-infra", "deploy-infra",
    "deploy-app", "rollback", "upgrade", "destroy", "audit",
    "status",
}


@app.websocket("/ws/run/{action}")
async def run_action(ws: WebSocket, action: str):
    """
    Stream a framework command's stdout+stderr to the client over WS.
    Client sends { repo, payload } on connect; server runs the cmd and
    streams lines as { type: "line", data: "..." } messages.
    Final message: { type: "exit", code: N }.
    """
    await ws.accept()
    if action not in VALID_ACTIONS:
        await ws.send_json({"type": "error", "msg": f"unknown action {action}"})
        await ws.close()
        return

    init = await ws.receive_json()
    repo = init.get("repo", "")
    payload = init.get("payload", {})

    # Validate repo name (skipped for init since project doesn't exist yet)
    if action != "init":
        try:
            safe_repo(repo)
        except HTTPException as e:
            await ws.send_json({"type": "error", "msg": e.detail})
            await ws.close()
            return

    try:
        argv = build_cli_args(action, repo, payload)
    except KeyError as e:
        await ws.send_json({"type": "error", "msg": f"missing param: {e}"})
        await ws.close()
        return

    await ws.send_json({"type": "started", "cmd": " ".join(shlex.quote(a) for a in argv)})

    # Some commands use bash `read` for human approval; we must feed the
    # expected token on stdin or they hang forever in non-interactive mode.
    # The UI does its own confirmation dialog before opening the WS, so by
    # the time we get here the user has already approved.
    stdin_data = b""
    extra_env: dict[str, str] = {}
    if action in ("apply-infra", "deploy-infra"):
        stdin_data = b"apply\n"
        # cmd_apply_infra refuses to run from non-TTY callers unless the UI
        # explicitly opts in. The opt-in says "I have shown the plan summary
        # to a human and received approval out-of-band". The UI does this
        # via the confirmation modal that opens before we hit this code.
        extra_env["DEVOPS_AI_UI_APPROVED"] = "1"
    elif action == "destroy":
        # cmd_destroy reads the repo name back as confirmation
        stdin_data = (repo + "\n").encode()

    proc = await asyncio.create_subprocess_exec(
        *argv,
        cwd=str(ROOT),
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
        stdin=asyncio.subprocess.PIPE,
        env={**os.environ, "TERM": "dumb", "FORCE_COLOR": "0", "NO_COLOR": "1", **extra_env},
    )

    if stdin_data:
        proc.stdin.write(stdin_data)
        await proc.stdin.drain()
    if proc.stdin:
        proc.stdin.close()

    run_id = str(id(proc))
    RUNS[run_id] = proc
    await ws.send_json({"type": "run_id", "id": run_id})

    client_gone = False
    try:
        while True:
            line = await proc.stdout.readline()
            if not line:
                break
            text = line.decode(errors="replace").rstrip("\n")
            # Strip ANSI escapes for cleaner UI
            text = re.sub(r"\x1b\[[0-9;]*m", "", text)
            try:
                await ws.send_json({"type": "line", "data": text})
            except (WebSocketDisconnect, RuntimeError):
                client_gone = True
                break
    except WebSocketDisconnect:
        client_gone = True
    finally:
        # If the WS is gone, the recipe should be killed — the user is no
        # longer watching and likely opened a new session via re-click.
        if client_gone:
            try: proc.terminate()
            except Exception: pass
        rc = await proc.wait()
        RUNS.pop(run_id, None)
        # Best-effort final messages — both wrapped: starlette raises if the
        # peer already sent a close frame, and we must not let the handler
        # bubble that up as a 500.
        try:
            await ws.send_json({"type": "exit", "code": rc})
        except Exception:
            pass
        try:
            await ws.close()
        except Exception:
            pass


# ─── Anthropic API key auth ─────────────────────────────────────────

class AnthropicKeyRequest(BaseModel):
    api_key: str  # sk-ant-api03-...


def _bashrc_set_env(name: str, value: Optional[str]) -> None:
    """Add or remove an `export NAME=value` line in ~/.bashrc so it
    persists across shell subprocesses Goose spawns."""
    bashrc = Path.home() / ".bashrc"
    text = bashrc.read_text() if bashrc.exists() else ""
    # Strip any existing line for this var (single-line export)
    text = re.sub(rf"^export {re.escape(name)}=.*$", "", text, flags=re.MULTILINE)
    text = text.rstrip("\n") + "\n"
    if value is not None:
        text += f"export {name}={shlex.quote(value)}\n"
    bashrc.write_text(text)


def _set_goose_provider(provider: str, model: str = "claude-opus-4-7") -> None:
    """Rewrite GOOSE_PROVIDER/GOOSE_MODEL in ~/.config/goose/config.yaml."""
    cfg = Path.home() / ".config" / "goose" / "config.yaml"
    cfg.parent.mkdir(parents=True, exist_ok=True)
    text = cfg.read_text() if cfg.exists() else ""
    lines = text.splitlines()
    keep = [ln for ln in lines if not ln.startswith(("GOOSE_PROVIDER:", "GOOSE_MODEL:"))]
    new = [f"GOOSE_PROVIDER: {provider}", f"GOOSE_MODEL: {model}"] + keep
    cfg.write_text("\n".join(new) + "\n")


@app.post("/api/anthropic/use-subscription")
def use_subscription() -> dict:
    """
    Switch goose to claude-acp provider (uses ~/.claude/ OAuth from host).
    Verifies that the subscription is actually authenticated; refuses
    otherwise so we don't leave the user with a dead config.
    """
    if not subscription_works():
        raise HTTPException(
            400,
            "Claude subscription not authenticated. On your HOST machine run "
            "`claude` (complete OAuth login with your Max plan), then click "
            "Re-check. Your host's ~/.claude/ is mounted into this container.",
        )
    # Subscription path doesn't need ANTHROPIC_API_KEY; remove it to avoid
    # accidentally falling onto the metered API.
    os.environ.pop("ANTHROPIC_API_KEY", None)
    _bashrc_set_env("ANTHROPIC_API_KEY", None)
    _set_goose_provider("claude-acp")
    return {
        "ok": True,
        "auth_mode": "subscription",
        "current_provider": "claude-acp",
    }


@app.get("/api/anthropic/status")
def auth_status() -> dict:
    """
    Combined status of both auth paths + which one is active.

    Side-effect: auto-heal the goose config if it's pointing at a path
    that won't work. Common after an image rebuild — the baked default
    is `anthropic`, but the user authenticated via OAuth (mounted
    ~/.claude/ survived the rebuild). We silently flip to `claude-acp`
    so the very next recipe run works.
    """
    state = current_auth()
    has_key = bool(os.environ.get("ANTHROPIC_API_KEY"))
    if (state.get("subscription_works")
            and state.get("current_provider") != "claude-acp"
            and not has_key):
        try:
            _set_goose_provider("claude-acp")
            state["current_provider"] = "claude-acp"
            state["auto_switched"] = True
        except Exception:
            pass
    elif (has_key
            and state.get("api_key_works")
            and state.get("current_provider") != "anthropic"):
        try:
            _set_goose_provider("anthropic")
            state["current_provider"] = "anthropic"
            state["auto_switched"] = True
        except Exception:
            pass
    return state


# ─── OAuth orchestrator: drive `claude /login` through PTY ──────────
#
# The strategy: spawn `claude` in a PTY with very wide cols (so it never
# wraps the OAuth URL across lines). Watch its output for known patterns
# (theme picker → URL → code prompt → success/failure) and translate to
# clean WS messages the UI can render as a wizard.
#
# The UI never sees the TUI; only structured state events: starting →
# url_ready → waiting_code → verifying → success/failed.

_LOGIN_URL_RE = re.compile(r"https://(?:claude\.com|claude\.ai)/[^\s]*oauth[^\s]*")
_THEME_RE    = re.compile(r"(Choose the text style|theme that looks best)", re.I)
_PROMPT_LINE = re.compile(r"What's on your mind|Welcome to Claude|>\s*$", re.I | re.M)
_CODE_RE     = re.compile(r"(Paste code here|verification code|Enter code|Login URL\s*►|paste.*code)", re.I)
# Anything that strongly implies "we're in" — covers many claude versions.
_SUCCESS_RE  = re.compile(
    r"(Login successful|Logged in|authenticated|signed[\s-]*in|signed[\s-]*up|"
    r"setup\s*complete|set\s*up\s*complete|you[''`]re\s*all\s*set|"
    r"connected|account\s*linked|api\s*key|token\s*saved|"
    r"welcome\s*[,!]|✓\s*Login|✅)",
    re.I,
)
_FAILED_RE   = re.compile(
    r"(Login\s*failed|invalid\s*code|authentication\s*failed|expired|"
    r"incorrect\s*code|did\s*not\s*match|please\s*try\s*again)",
    re.I,
)


def _pty_safe_read(fd: int, n: int = 4096) -> Optional[bytes]:
    try:
        r, _, _ = select.select([fd], [], [], 0.1)
        if not r:
            return b""
        return os.read(fd, n)
    except OSError:
        return None


def _strip_ansi(s: str) -> str:
    s = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", s)
    s = re.sub(r"\x1b\][^\x07]*\x07", "", s)
    s = re.sub(r"\x1b[()][AB012]", "", s)
    return s


@app.websocket("/ws/claude/login")
async def claude_login_orchestrator(ws: WebSocket):
    """
    Orchestrate `claude` CLI's OAuth flow over PTY and expose it as a
    clean wizard to the UI:
      → connecting
      → url_ready { url }
      → waiting_code
      → verifying
      → success | failed { reason }

    Client sends:  {type:"submit_code", code:"..."} | {type:"cancel"}
    """
    await ws.accept()

    async def emit(state: str, **extra):
        try:
            await ws.send_json({"type": "state", "state": state, **extra})
        except Exception:
            pass

    import sys
    pid, fd = pty.fork()
    if pid == 0:
        # Child — exec claude. Force OAuth path (no API key) and a wide
        # virtual terminal so the URL is never wrapped.
        env = {
            **os.environ,
            "TERM": "xterm-256color",
            "COLUMNS": "500",
            "LINES": "60",
        }
        env.pop("ANTHROPIC_API_KEY", None)
        try:
            os.execvpe("claude", ["claude"], env)
        except Exception:
            os._exit(127)

    # Parent
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 60, 500, 0, 0))
    except Exception:
        pass

    loop = asyncio.get_event_loop()
    state = "connecting"
    output = ""
    captured_url: Optional[str] = None
    sent_login = False
    sent_initial_enter = False
    cancelled = False
    code_submitted_at: Optional[float] = None
    last_output_at: float = loop.time()

    await emit("connecting")
    print(f"[oauth] PTY claude pid={pid} fd={fd}", file=sys.stderr, flush=True)

    async def reader():
        nonlocal output, state, captured_url, sent_login, sent_initial_enter, last_output_at
        login_deadline = loop.time() + 2.0   # send /login\r within 2s
        enter_deadline = loop.time() + 0.8   # nudge Enter within 0.8s
        while True:
            try:
                data = await loop.run_in_executor(None, _pty_safe_read, fd)
            except Exception:
                break
            if data is None:
                break
            if data:
                last_output_at = loop.time()
                chunk = data.decode("utf-8", errors="replace")
                output += chunk
                if len(output) > 200_000:
                    output = output[-200_000:]
                clean = _strip_ansi(output)

                # Stream raw chunks to the UI debug panel + docker logs.
                stripped = _strip_ansi(chunk)
                if stripped.strip():
                    print(f"[oauth] {stripped!r}",
                          file=sys.stderr, flush=True)
                    try:
                        await ws.send_json({"type": "raw",
                                            "data": stripped})
                    except Exception:
                        pass

                # 1. Theme picker — accept default with Enter.
                if state == "connecting" and _THEME_RE.search(clean):
                    os.write(fd, b"\r")
                    sent_initial_enter = True
                    print("[oauth] dismissed theme picker",
                          file=sys.stderr, flush=True)

                # 2. URL extraction (wide cols means single-line URL).
                if not captured_url:
                    m = _LOGIN_URL_RE.search(clean)
                    if m:
                        captured_url = m.group(0)
                        state = "url_ready"
                        print(f"[oauth] captured URL: {captured_url}",
                              file=sys.stderr, flush=True)
                        await emit("url_ready", url=captured_url)

                # 3. Code prompt detected.
                if state == "url_ready" and _CODE_RE.search(clean):
                    state = "waiting_code"
                    await emit("waiting_code", url=captured_url)

                # 4. Outcome detection via explicit text markers.
                if state in ("verifying", "waiting_code", "code_sent"):
                    if _SUCCESS_RE.search(clean):
                        state = "success"
                        print("[oauth] success marker matched", file=sys.stderr, flush=True)
                        await emit("success")
                        return
                    if _FAILED_RE.search(clean):
                        if code_submitted_at and loop.time() - code_submitted_at > 0.5:
                            state = "failed"
                            print("[oauth] failure marker matched", file=sys.stderr, flush=True)
                            await emit("failed", reason="claude reported login failure")
                            return

            now = loop.time()
            # Nudge any "press enter to continue" or accept-defaults prompt.
            if not sent_initial_enter and now > enter_deadline:
                try:
                    os.write(fd, b"\r")
                    print("[oauth] sent initial Enter", file=sys.stderr, flush=True)
                except Exception:
                    pass
                sent_initial_enter = True

            # If we still have no URL after the bootstrap window, type /login.
            if not sent_login and not captured_url and now > login_deadline:
                try:
                    os.write(fd, b"/login\r")
                    print("[oauth] sent /login", file=sys.stderr, flush=True)
                    sent_login = True
                except Exception:
                    pass

            if cancelled:
                return

    async def real_verify_after_submit():
        """
        After the user submits the code, watch the filesystem for auth
        artifacts written by claude CLI. Spawning a competing `claude
        --print` subprocess races with the still-running PTY claude over
        ~/.claude/, so we use file watching instead.

        Detection: any file with 'credential', 'token', or 'auth' in its
        name appearing under ~/.claude/ — claude writes its OAuth token
        to one of those at the end of the login flow. Also nudge the PTY
        with Enter periodically in case it's waiting on a "press any
        key to continue" prompt.
        """
        nonlocal state
        deadline = loop.time() + 60.0
        claude_dir = Path.home() / ".claude"
        seen_files = {p.name for p in claude_dir.iterdir()} if claude_dir.exists() else set()
        creds_keywords = ("credential", "token", "auth", ".oauth", "session-secret")
        nudge_count = 0
        while loop.time() < deadline:
            if state in ("success", "failed") or cancelled:
                return
            await asyncio.sleep(1.5)

            # Look for any *new* file with auth-y name in ~/.claude/
            try:
                current = list(claude_dir.iterdir()) if claude_dir.exists() else []
            except Exception:
                current = []
            for p in current:
                if p.name in seen_files:
                    continue
                seen_files.add(p.name)
                if any(kw in p.name.lower() for kw in creds_keywords):
                    state = "success"
                    print(f"[oauth] credentials file appeared: {p.name}",
                          file=sys.stderr, flush=True)
                    await emit("success")
                    return

            # Also check pre-existing files that grew (e.g. settings.json
            # rewritten with token, or .credentials.json that was always
            # there but empty).
            for p in current:
                try:
                    if p.is_file() and p.stat().st_size > 100 \
                       and any(kw in p.name.lower() for kw in creds_keywords):
                        state = "success"
                        print(f"[oauth] credentials file populated: {p.name}",
                              file=sys.stderr, flush=True)
                        await emit("success")
                        return
                except Exception:
                    pass

            # Send Enter every ~6 seconds in case claude is waiting on a
            # "press any key" or confirmation step that we can't see.
            nudge_count += 1
            if nudge_count % 4 == 0:
                try:
                    os.write(fd, b"\r")
                    print(f"[oauth] nudge Enter (attempt {nudge_count})",
                          file=sys.stderr, flush=True)
                except Exception:
                    pass

        if state not in ("success", "failed"):
            state = "failed"
            print("[oauth] verification timeout — no credentials file written in 60s",
                  file=sys.stderr, flush=True)
            await emit(
                "failed",
                reason="60s passed with no credentials written. Code may be invalid/expired, "
                       "or claude CLI is asking for something we can't see. "
                       "Check the debug log below — last lines of claude output.",
            )

    async def writer():
        nonlocal state, cancelled, code_submitted_at, last_output_at
        while True:
            try:
                msg = await ws.receive_json()
            except Exception:
                cancelled = True
                return
            t = msg.get("type")
            if t == "submit_code":
                code = (msg.get("code") or "").strip()
                if not code:
                    continue
                try:
                    os.write(fd, code.encode() + b"\r")
                    print(f"[oauth] submitted code (len={len(code)})", file=sys.stderr, flush=True)
                except Exception:
                    pass
                state = "code_sent"
                code_submitted_at = loop.time()
                last_output_at = loop.time()
                await emit("verifying")
                # Kick off the real verifier (independent of PTY output).
                asyncio.create_task(real_verify_after_submit())
            elif t == "cancel":
                cancelled = True
                return

    try:
        await asyncio.wait_for(asyncio.gather(reader(), writer()),
                               timeout=600)  # 10 minute hard cap
    except asyncio.TimeoutError:
        await emit("failed", reason="timeout (10min)")
    finally:
        try: os.kill(pid, signal.SIGTERM)
        except Exception: pass
        try: os.close(fd)
        except Exception: pass
        try: os.waitpid(pid, os.WNOHANG)
        except Exception: pass
        try: await ws.close()
        except Exception: pass


@app.post("/api/anthropic/key")
def set_anthropic_key(req: AnthropicKeyRequest) -> dict:
    """
    Save an Anthropic API key. The key is exported to:
      1. The current FastAPI process env (so any goose subprocess inherits)
      2. ~/.bashrc (so future shells/sessions also see it)
    Goose's `anthropic` provider then uses it directly against
    api.anthropic.com — no claude CLI subprocess involved.
    """
    key = req.api_key.strip()
    if not key.startswith("sk-ant-"):
        raise HTTPException(400, "Anthropic API keys start with 'sk-ant-'")
    os.environ["ANTHROPIC_API_KEY"] = key
    _bashrc_set_env("ANTHROPIC_API_KEY", key)
    _set_goose_provider("anthropic")
    # Verify it actually works against the Anthropic API.
    ok, err = api_key_works()
    return {
        "ok": ok,
        "claude_authenticated": ok,
        "error": err,
        "auth_mode": "api_key",
    }


@app.delete("/api/anthropic/key")
def clear_anthropic_key() -> dict:
    """Remove the API key from env + bashrc. Doesn't touch ~/.claude/."""
    os.environ.pop("ANTHROPIC_API_KEY", None)
    _bashrc_set_env("ANTHROPIC_API_KEY", None)
    return {"ok": True, "claude_authenticated": claude_authenticated()}


@app.get("/api/anthropic/auth-mode")
def get_auth_mode() -> dict:
    """Return which auth path is currently active.
    api_key  — ANTHROPIC_API_KEY env var is set
    oauth    — ~/.claude/ has credentials and claude CLI works
    none     — neither
    """
    has_key = bool(os.environ.get("ANTHROPIC_API_KEY"))
    claude_ok = claude_authenticated()
    if has_key and claude_ok:
        mode = "api_key"
    elif claude_ok:
        mode = "oauth"
    else:
        mode = "none"
    return {
        "auth_mode": mode,
        "has_api_key": has_key,
        "claude_authenticated": claude_ok,
    }


# ─── static (frontend) ───────────────────────────────────────────────

if FRONTEND_DIR.exists():
    app.mount("/static", StaticFiles(directory=str(FRONTEND_DIR)), name="static")


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8080)
