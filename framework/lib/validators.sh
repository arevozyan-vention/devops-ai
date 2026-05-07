#!/usr/bin/env bash
# lib/validators.sh — preflight checks used by devops-ai.sh before risky steps.
# Source this file from devops-ai.sh; do not execute directly.
#
# Each validator returns 0 on success and 1 (with a stderr message) on failure.
# devops-ai.sh combines them into "preflight" routines per CLI command.

set -euo pipefail

: "${FRAMEWORK_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
: "${DEVOPS_AI_ROOT:=$(cd "$FRAMEWORK_DIR/.." && pwd)}"

# ---- generic helpers ---------------------------------------------------------

require_command() {
  local cmd="$1" hint="${2:-run ./bootstrap.sh}"
  command -v "$cmd" >/dev/null 2>&1 \
    || { echo "validators.sh: '$cmd' not found in PATH ($hint)" >&2; return 1; }
}

require_file() {
  local f="$1"
  [[ -f "$f" ]] || { echo "validators.sh: file '$f' not found" >&2; return 1; }
}

require_dir() {
  local d="$1"
  [[ -d "$d" ]] || { echo "validators.sh: directory '$d' not found" >&2; return 1; }
}

# ---- environment-level checks ------------------------------------------------

require_aws_creds() {
  require_command aws "brew install awscli"
  if ! aws sts get-caller-identity >/dev/null 2>&1; then
    echo "validators.sh: AWS credentials not configured. Run: ./devops-ai.sh aws-login" >&2
    return 1
  fi
  return 0
}

require_aws_region() {
  local region="$1"
  [[ "$region" =~ ^[a-z]{2}-[a-z]+-[0-9]+$ ]] \
    || { echo "validators.sh: '$region' is not a valid AWS region" >&2; return 1; }
}

require_azure_creds() {
  require_command az "brew install azure-cli"
  if ! az account show >/dev/null 2>&1; then
    echo "validators.sh: Azure not authenticated. Run: ./devops-ai.sh az-login (or set creds in the UI Setup tab)" >&2
    return 1
  fi
  return 0
}

# Azure region IDs are alphanumeric, no separator, e.g. eastus, westeurope,
# centralindia, brazilsouth. Numeric suffixes appear (eastus2, westus3).
require_azure_region() {
  local region="$1"
  [[ "$region" =~ ^[a-z]+[a-z0-9]*$ ]] \
    || { echo "validators.sh: '$region' is not a valid Azure region" >&2; return 1; }
}

require_docker_running() {
  require_command docker "brew install docker"
  if ! docker info >/dev/null 2>&1; then
    echo "validators.sh: Docker daemon not running. Start Docker Desktop and retry." >&2
    return 1
  fi
  return 0
}

require_claude_authenticated() {
  require_command goose "see https://github.com/block/goose" || return 1

  # Path A — API key set: verify cheaply via /v1/models endpoint.
  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    if curl -fsS --max-time 5 \
         -H "x-api-key: $ANTHROPIC_API_KEY" \
         -H "anthropic-version: 2023-06-01" \
         https://api.anthropic.com/v1/models >/dev/null 2>&1; then
      return 0
    fi
    echo "validators.sh: ANTHROPIC_API_KEY set but Anthropic /v1/models rejected it" >&2
    echo "  Bad key, no credits, or rate-limited?" >&2
    return 1
  fi

  # Path B — OAuth: claude CLI must answer.
  if command -v claude >/dev/null 2>&1 \
     && claude --print --model "${REQUIRED_MODEL:-claude-opus-4-7}" "ok" >/dev/null 2>&1; then
    return 0
  fi

  echo "validators.sh: no working Anthropic auth detected." >&2
  echo "  Either set ANTHROPIC_API_KEY (sk-ant-...) OR run 'claude' for OAuth login." >&2
  return 1
}

require_goose() {
  require_command goose "see https://github.com/block/goose"
}

require_terraform_stack() {
  require_command terraform "brew install terraform"
  require_command terragrunt "brew install terragrunt"
}

# ---- project-level checks ----------------------------------------------------

require_project() {
  local repo="$1"
  [[ -n "${repo:-}" ]] || { echo "validators.sh: project name is required" >&2; return 1; }
  [[ "$repo" =~ ^[A-Za-z0-9._-]+$ ]] \
    || { echo "validators.sh: invalid project name '$repo'" >&2; return 1; }
  require_dir "$DEVOPS_AI_ROOT/projects/$repo" \
    || { echo "  Run: ./devops-ai.sh init <path>" >&2; return 1; }
  require_file "$DEVOPS_AI_ROOT/projects/$repo/state.yaml"
}

require_dockerfile() {
  # Soft sanity check: at least one plausible Dockerfile somewhere under
  # the source tree. The deploy-app recipe (Phase 1.4) does the real
  # discovery with role-aware patterns (`*-server`, `packages/<pkg>/`,
  # etc.) — we don't want to gate ahead of that with brittle heuristics.
  #
  # Two things this fixes vs. the previous version:
  #   1) The previous check hardcoded `<root>/projects/<repo>/source/` but
  #      `init <path>` records the actual source location in state.yaml
  #      (often outside that hardcoded path — e.g. /workspace/sources/<repo>
  #      when the operator bind-mounts a sibling source tree). Read the
  #      real path from state instead.
  #   2) The previous check accepted ANY Dockerfile up to depth 3, which
  #      matched editor-config files like `.cursor/Dockerfile` while
  #      missing the real ones at `packages/*-server/Dockerfile`. Search
  #      deeper and skip dotfile directories.
  local repo="$1"

  local src=""
  if [[ -f "$DEVOPS_AI_ROOT/projects/$repo/state.yaml" ]] && command -v yq >/dev/null 2>&1; then
    src="$(yq -r '.source_path // ""' "$DEVOPS_AI_ROOT/projects/$repo/state.yaml" 2>/dev/null)"
  fi
  [[ -z "$src" ]] && src="$DEVOPS_AI_ROOT/projects/$repo/source"

  if [[ ! -d "$src" ]]; then
    echo "validators.sh: source path '$src' (from state.yaml) does not exist" >&2
    return 1
  fi

  # Search up to 5 levels, skip hidden dirs (.git, .cursor, .vscode, etc.).
  local found
  found="$(find "$src" -maxdepth 5 -type d -name '.*' -prune -o -type f -name 'Dockerfile' -print 2>/dev/null | head -1)"
  if [[ -z "$found" ]]; then
    echo "validators.sh: no Dockerfile found anywhere under $src" >&2
    echo "  deploy-app needs at least one Dockerfile to build." >&2
    return 1
  fi
  return 0
}

require_iac_rendered() {
  local repo="$1"
  local iac="$DEVOPS_AI_ROOT/projects/$repo/iac"
  require_dir "$iac" || return 1
  if [[ -z "$(find "$iac" -name 'terragrunt.hcl' -print -quit 2>/dev/null)" ]]; then
    echo "validators.sh: no terragrunt.hcl found in $iac. Run: ./devops-ai.sh generate-iac $repo" >&2
    return 1
  fi
  return 0
}

# ---- composite preflights (per CLI command) ----------------------------------

preflight_analyze() {
  local repo="$1"
  require_project "$repo"
  require_claude_authenticated
  require_goose
}

preflight_recommend() {
  local repo="$1"
  require_project "$repo"
  require_claude_authenticated
  require_goose
}

preflight_generate_iac() {
  local repo="$1"
  require_project "$repo"
  require_claude_authenticated
  require_goose
  require_terraform_stack
}

preflight_deploy_infra() {
  local repo="$1"
  require_project "$repo"
  require_aws_creds
  require_terraform_stack
  require_iac_rendered "$repo"
}

preflight_deploy_app() {
  local repo="$1"
  require_project "$repo"
  require_aws_creds
  require_docker_running
  require_dockerfile "$repo"
}

preflight_rollback() {
  local repo="$1"
  require_project "$repo"
  require_aws_creds
}

# New Opus 4.7-tuned recipes:
# - audit walks IaC + queries live AWS via aws-api MCP, no mutations
preflight_audit() {
  local repo="$1"
  require_project "$repo"
  require_claude_authenticated
  require_goose
  require_aws_creds
}
