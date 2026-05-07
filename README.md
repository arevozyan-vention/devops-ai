# devops-ai-ui

Web UI wrapper around the DevOps AI framework. One Docker container with
the framework, all CLI tools (Goose, Claude CLI, Terraform, Terragrunt,
AWS CLI, Docker), a FastAPI backend, and a vanilla-JS frontend.

User-friendly alternative to running the bash framework from a terminal.

## Prerequisites on the host machine

1. **Docker** + **docker-compose**
2. **Anthropic auth** — pick whichever billing you already pay for:

   | Path | Billing | How |
   |---|---|---|
   | **A · Claude Max subscription** ($100/mo flat) | covered | run `claude` on host once |
   | **B · Anthropic API key** (per-token, *separate*) | not covered | paste `sk-ant-...` in UI |

   These are TWO DIFFERENT accounts in Anthropic-land. Max gives you
   Claude.ai web + Claude Code CLI for flat $100/mo. An API key from
   console.anthropic.com is metered, pay-per-token, **separate**.
   Neither includes the other.

   ### Path A — use your Max subscription

   On your **host machine** (one time), outside the container:
   ```bash
   npm install -g @anthropic-ai/claude-code
   claude   # complete OAuth login with your Max plan
   ```
   That populates `~/.claude/` on your host. The container mounts that
   directory, so the in-container `claude` CLI inherits the auth.
   Then in the UI's Setup tab → click **"Use subscription"** under
   Path A — Goose switches to the `claude-acp` provider.

   ### Path B — use an Anthropic API key

   Get a key from
   [console.anthropic.com/settings/keys](https://console.anthropic.com/settings/keys),
   make sure the account has credits, paste it in the UI Setup tab →
   API key card → Save & verify. Goose switches to `anthropic` provider
   and talks to api.anthropic.com directly.

3. **AWS credentials** — either pre-populate `~/.aws/credentials` on your
   host, or configure via the Setup tab inside the UI.

## Build & run

```bash
cd devops-ai-ui
docker compose up -d --build
open http://localhost:8080
```

## What it gives you

- **Setup tab** — verify Claude auth, **log in to Claude Max from inside
  the UI** (PTY-bridged terminal handles the OAuth flow), logout, set/save
  AWS credentials.
- **Projects tab** — list initialized projects with status pills, "+ New
  project" button.
- **Project detail tab** — workflow steps (Assess → Select → Generate IaC
  → Review IaC → Bootstrap → Plan → Explain → Apply → Deploy app → Audit)
  with badges showing progress, "Run" buttons that stream live logs over
  WebSocket, and an Artifacts panel that opens generated docs / IaC files.

## Volume layout

| Mount | Purpose |
|---|---|
| `~/.claude` → `/root/.claude` | Claude OAuth (Max subscription) |
| `~/.aws` → `/root/.aws` | AWS credentials |
| `./projects` → `/workspace/projects` | Persistent project state (state.yaml, generated iac/, deploy outputs) |
| `./sources` → `/workspace/sources` (ro) | Your application repos to deploy |
| `/var/run/docker.sock` → same | So `deploy-app` can `docker build/push` |

To register a project, drop (or clone) your repo into `devops-ai-ui/sources/`
on the host:

```bash
cd devops-ai-ui/sources
git clone https://github.com/you/myapp
```

It will appear in the UI's "+ New project" dropdown automatically — pick
it, give the project a name, and Initialize.

## What lives where on disk

Inside the container:

```
/workspace/
├── framework/        # baked into the image (the bash framework)
├── backend/          # FastAPI app (baked in)
├── frontend/         # static UI (baked in)
├── sources/   (ro)   # ← your host's devops-ai-ui/sources/
│   ├── hiriskpro/
│   ├── myapp/
│   └── ...
└── projects/  (rw)   # ← your host's devops-ai-ui/projects/
    ├── hiriskpro/
    │   ├── source/   # symlink → /workspace/sources/hiriskpro
    │   ├── docs/
    │   ├── iac/
    │   ├── deploy/
    │   └── state.yaml
    └── ...
```

## How recipe execution works

Each "Run" button opens a WebSocket to `/ws/run/<action>`, the backend
spawns `framework/devops-ai.sh <action> <repo>`, and stdout/stderr stream
back as JSON line messages. `apply-infra` / `deploy-infra` get an automatic
`apply\n` on stdin (the UI confirmation dialog already gated the action).

## Limitations / caveats

- **Apple Silicon hosts**: the Docker image builds for the host arch, but
  the framework's `deploy-app` step builds your app image for `linux/amd64`
  (since ECS Fargate is amd64). buildx with QEMU handles this; first builds
  are slower.
- **Claude auth in UI**: works for the device-code-style OAuth flow that
  Claude Code CLI uses (paste-the-code-back). If your `claude` install
  uses a localhost-callback PKCE flow that wants to redirect the browser
  to `http://127.0.0.1:<port>/...` *inside the container*, the callback
  can't reach it from your host browser. Workaround: log in on the host
  with `claude` once; the mounted `~/.claude/` gets the token.
- **Source paths**: must be reachable inside the container. Either mount
  them via `docker-compose.yml` or copy them into `./projects/<name>/source/`.

## Troubleshooting

- `Claude: not authenticated` in the header → run `claude` on your host,
  complete OAuth, then `docker compose restart`.
- `AWS: not configured` → either pre-populate `~/.aws/credentials` on the
  host, or fill the form on the Setup tab.
- Live log stops mid-recipe → check `docker logs devops-ai-ui` for the
  underlying error.
- Permission denied on `/var/run/docker.sock` → on Linux, add the docker
  group's gid to the container or run with `--group-add docker`.
