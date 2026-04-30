#!/usr/bin/env bash
# bootstrap.sh — one-time installer for the DevOps AI Framework.
# Idempotent: safe to run multiple times.

set -euo pipefail

readonly REQUIRED_MODEL="claude-opus-4-7"
readonly GOOSE_PROVIDER_NAME="claude-acp"
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

ensure_node() {
  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    ok "node found ($(node --version)), npm found ($(npm --version))"
    return
  fi
  step "Installing node (provides npm for claude CLI + ACP adapter)"
  brew install node
  ok "node installed"
}

ensure_claude_cli() {
  if command -v claude >/dev/null 2>&1; then
    ok "claude CLI found ($(claude --version 2>&1 | head -n1))"
    return
  fi
  step "Installing @anthropic-ai/claude-code"
  npm install -g @anthropic-ai/claude-code
  command -v claude >/dev/null 2>&1 \
    || die "claude not on PATH after install. Check 'npm prefix -g'/PATH."
  ok "claude CLI installed"
}

ensure_claude_acp() {
  if command -v claude-agent-acp >/dev/null 2>&1; then
    ok "claude-agent-acp adapter found"
    return
  fi
  step "Installing @agentclientprotocol/claude-agent-acp"
  npm install -g @agentclientprotocol/claude-agent-acp
  command -v claude-agent-acp >/dev/null 2>&1 \
    || die "claude-agent-acp not on PATH after install."
  ok "ACP adapter installed"
}

ensure_claude_authenticated() {
  step "Verifying claude CLI is authenticated to a Claude subscription"
  if claude --print --model "$REQUIRED_MODEL" "reply OK" >/dev/null 2>&1; then
    ok "claude CLI authenticated and $REQUIRED_MODEL reachable"
    return
  fi
  warn "claude CLI not authenticated (or model unreachable)"
  echo "  Run interactively:  claude   (then complete OAuth login under your Max plan)"
  die "claude CLI authentication required"
}

ensure_goose_config() {
  local cfg="$HOME/.config/goose/config.yaml"
  step "Configuring Goose for $GOOSE_PROVIDER_NAME ($REQUIRED_MODEL)"
  mkdir -p "$(dirname "$cfg")"
  # If a previous (qwen/ollama) config exists, preserve it as .qwen.bak so we
  # can A/B compare. Idempotent: only overwrite if provider isn't already claude-acp.
  if [[ -f "$cfg" ]]; then
    if grep -q "^GOOSE_PROVIDER: $GOOSE_PROVIDER_NAME" "$cfg" 2>/dev/null; then
      ok "Goose already configured for $GOOSE_PROVIDER_NAME (left untouched)"
      return
    fi
    cp "$cfg" "$cfg.qwen.bak"
    ok "Backed up previous Goose config to $cfg.qwen.bak"
  fi
  cat > "$cfg" <<EOF
GOOSE_PROVIDER: $GOOSE_PROVIDER_NAME
GOOSE_MODEL: $REQUIRED_MODEL
GOOSE_MODE: smart_approve
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

  ensure_node
  ensure_claude_cli
  ensure_claude_acp
  ensure_claude_authenticated

  ensure_goose
  ensure_goose_config
  make_scripts_executable

  echo
  c_green "=== Bootstrap complete ==="
  echo "  Next: $FRAMEWORK_DIR/devops-ai.sh init <path-to-your-repo>"
  echo
}

main "$@"
