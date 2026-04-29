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

require_docker_running() {
  require_command docker "brew install docker"
  if ! docker info >/dev/null 2>&1; then
    echo "validators.sh: Docker daemon not running. Start Docker Desktop and retry." >&2
    return 1
  fi
  return 0
}

require_ollama_running() {
  if ! curl -fsS --max-time 2 http://localhost:11434/api/tags >/dev/null 2>&1; then
    echo "validators.sh: Ollama daemon not reachable at http://localhost:11434" >&2
    echo "  Start it with: open -a Ollama   (or: ollama serve)" >&2
    return 1
  fi
  return 0
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
  local repo="$1"
  local src="$DEVOPS_AI_ROOT/projects/$repo/source"
  if [[ ! -f "$src/Dockerfile" ]] && [[ -z "$(find "$src" -maxdepth 3 -name 'Dockerfile' -print -quit 2>/dev/null)" ]]; then
    echo "validators.sh: no Dockerfile found under projects/$repo/source/" >&2
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
  require_ollama_running
  require_goose
}

preflight_recommend() {
  local repo="$1"
  require_project "$repo"
  require_ollama_running
  require_goose
}

preflight_generate_iac() {
  local repo="$1"
  require_project "$repo"
  require_ollama_running
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
