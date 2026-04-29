#!/usr/bin/env bash
# bootstrap.sh — one-time installer for the DevOps AI Framework.
# Idempotent: safe to run multiple times.

set -euo pipefail

readonly REQUIRED_MODEL="qwen3.6:35b-a3b"
readonly FRAMEWORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DEVOPS_AI_ROOT="$(cd "$FRAMEWORK_DIR/.." && pwd)"

c_red()   { printf '\033[31m%s\033[0m\n' "$*"; }
c_green() { printf '\033[32m%s\033[0m\n' "$*"; }
c_yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
c_blue()  { printf '\033[34m%s\033[0m\n' "$*"; }

step() { c_blue "==> $*"; }
ok()   { c_green "  ✓ $*"; }
warn() { c_yellow "  ! $*"; }
die()  { c_red "  ✗ $*"; exit 1; }

require_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || die "This bootstrap currently supports macOS only."
}

ensure_brew() {
  step "Checking Homebrew"
  if command -v brew >/dev/null 2>&1; then
    ok "brew found ($(brew --version | head -n1))"
  else
    warn "brew not found. Install from https://brew.sh and re-run."
    die "brew is required"
  fi
}

ensure_brew_pkg() {
  local pkg="$1" bin="${2:-$1}"
  if command -v "$bin" >/dev/null 2>&1; then
    ok "$bin found ($("$bin" --version 2>&1 | head -n1))"
  else
    step "Installing $pkg"
    brew install "$pkg"
    ok "$pkg installed"
  fi
}

ensure_brew_cask() {
  local cask="$1" bin="$2"
  if command -v "$bin" >/dev/null 2>&1; then
    ok "$bin found"
  else
    step "Installing cask $cask"
    brew install --cask "$cask"
    ok "$cask installed"
  fi
}

ensure_terragrunt() {
  if command -v terragrunt >/dev/null 2>&1; then
    ok "terragrunt found ($(terragrunt --version 2>&1 | head -n1))"
  else
    step "Installing terragrunt"
    brew install terragrunt
    ok "terragrunt installed"
  fi
}

ensure_goose() {
  if command -v goose >/dev/null 2>&1; then
    ok "goose found ($(goose --version 2>&1 | head -n1))"
    return
  fi
  step "Installing Goose CLI"
  curl -fsSL https://github.com/block/goose/releases/download/stable/download_cli.sh | bash
  if ! command -v goose >/dev/null 2>&1; then
    warn "goose installed but not on PATH yet. Add ~/.local/bin to PATH and re-run."
    die "goose not on PATH"
  fi
  ok "goose installed"
}

ensure_ollama_running() {
  if curl -fsS --max-time 2 http://localhost:11434/api/tags >/dev/null 2>&1; then
    ok "ollama daemon reachable at http://localhost:11434"
    return
  fi
  warn "ollama daemon not running"
  if [[ -d "/Applications/Ollama.app" ]]; then
    step "Starting Ollama.app"
    open -a Ollama
    for _ in {1..10}; do
      sleep 1
      curl -fsS --max-time 2 http://localhost:11434/api/tags >/dev/null 2>&1 && break
    done
  fi
  curl -fsS --max-time 2 http://localhost:11434/api/tags >/dev/null 2>&1 \
    || die "ollama still not reachable. Start it manually: 'open -a Ollama' or 'ollama serve'"
  ok "ollama daemon reachable"
}

ensure_model() {
  step "Checking model $REQUIRED_MODEL"
  if ollama list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$REQUIRED_MODEL"; then
    ok "model already present"
  else
    step "Pulling $REQUIRED_MODEL (this may take a while; ~23 GB)"
    ollama pull "$REQUIRED_MODEL"
    ok "model pulled"
  fi
}

ensure_goose_config() {
  local cfg="$HOME/.config/goose/config.yaml"
  step "Configuring Goose for local Ollama"
  mkdir -p "$(dirname "$cfg")"
  if [[ -f "$cfg" ]] && grep -q "GOOSE_PROVIDER" "$cfg" 2>/dev/null; then
    ok "Goose config already present at $cfg (left untouched)"
    return
  fi
  cat > "$cfg" <<EOF
GOOSE_PROVIDER: ollama
GOOSE_MODEL: $REQUIRED_MODEL
OLLAMA_HOST: http://localhost:11434
extensions:
  developer:
    enabled: true
    type: builtin
    name: developer
EOF
  ok "Goose config written to $cfg"
}

make_scripts_executable() {
  step "Making framework scripts executable"
  chmod +x "$FRAMEWORK_DIR/devops-ai.sh" 2>/dev/null || true
  chmod +x "$FRAMEWORK_DIR/bootstrap.sh"
  find "$FRAMEWORK_DIR/lib" -name '*.sh' -exec chmod +x {} \; 2>/dev/null || true
  mkdir -p "$DEVOPS_AI_ROOT/projects"
  ok "executable bits set"
}

main() {
  echo
  c_blue "=== DevOps AI Framework — bootstrap ==="
  echo "  Workspace: $DEVOPS_AI_ROOT"
  echo "  Framework: $FRAMEWORK_DIR"
  echo

  require_macos
  ensure_brew

  ensure_brew_pkg jq
  ensure_brew_pkg yq
  ensure_brew_pkg awscli aws
  ensure_brew_pkg terraform
  ensure_terragrunt
  ensure_brew_pkg docker
  ensure_brew_pkg ollama

  ensure_goose
  ensure_ollama_running
  ensure_model
  ensure_goose_config
  make_scripts_executable

  echo
  c_green "=== Bootstrap complete ==="
  echo "  Next: $FRAMEWORK_DIR/devops-ai.sh init <path-to-your-repo>"
  echo
}

main "$@"
