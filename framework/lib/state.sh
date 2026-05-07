#!/usr/bin/env bash
# lib/state.sh — read/write per-project state.yaml.
# Source this file from devops-ai.sh; do not execute directly.
#
# Layout (framework code is isolated under framework/; projects live as a sibling):
#   $DEVOPS_AI_ROOT/                       (workspace root)
#     ├── framework/                       ($FRAMEWORK_DIR — this code)
#     │   ├── bootstrap.sh
#     │   ├── devops-ai.sh
#     │   ├── lib/                         (this file lives here)
#     │   ├── prompts/
#     │   ├── recipes/
#     │   ├── templates/iac/
#     │   └── docs-templates/
#     └── projects/<repo>/                 (per-project data)
#         ├── source/                      (symlink to the user's repo)
#         ├── docs/                        (generated MD)
#         ├── iac/                         (rendered Terragrunt + Terraform)
#         ├── deploy/history.jsonl         (append-only deploy log)
#         └── state.yaml                   (workflow state — managed here)
#
# Status keys (booleans):
#   analyzed, recommended, selected, iac_generated, infra_deployed, app_deployed
#
# All functions accept <repo> as the first argument (project directory name
# under projects/, not an absolute path).

set -euo pipefail

# Resolve paths if caller hasn't set them.
: "${FRAMEWORK_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
: "${DEVOPS_AI_ROOT:=$(cd "$FRAMEWORK_DIR/.." && pwd)}"

# ---- internal helpers --------------------------------------------------------

_state_project_dir() {
  local repo="$1"
  printf '%s/projects/%s' "$DEVOPS_AI_ROOT" "$repo"
}

_state_file() {
  local repo="$1"
  printf '%s/state.yaml' "$(_state_project_dir "$repo")"
}

_state_require_yq() {
  command -v yq >/dev/null 2>&1 \
    || { echo "state.sh: 'yq' is required (run ./bootstrap.sh)" >&2; return 1; }
}

_state_require_repo() {
  local repo="$1"
  [[ -n "$repo" ]] || { echo "state.sh: repo name is required" >&2; return 1; }
  [[ "$repo" =~ ^[A-Za-z0-9._-]+$ ]] \
    || { echo "state.sh: invalid repo name '$repo'" >&2; return 1; }
}

_state_require_exists() {
  local repo="$1"
  local f
  f="$(_state_file "$repo")"
  [[ -f "$f" ]] || { echo "state.sh: state.yaml not found for '$repo' ($f)" >&2; return 1; }
}

_state_now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# ---- public API --------------------------------------------------------------

# state_init <repo> <source_path>
# Creates projects/<repo>/{docs,iac,deploy}, writes initial state.yaml.
# Idempotent: refuses to overwrite an existing state.yaml.
state_init() {
  local repo="$1" source_path="$2"
  _state_require_yq
  _state_require_repo "$repo"
  [[ -n "${source_path:-}" ]] || { echo "state.sh: source_path is required" >&2; return 1; }
  [[ -d "$source_path" ]] || { echo "state.sh: source_path '$source_path' is not a directory" >&2; return 1; }

  local proj
  proj="$(_state_project_dir "$repo")"
  local f="$proj/state.yaml"

  if [[ -f "$f" ]]; then
    echo "state.sh: project '$repo' already initialized ($f)" >&2
    return 1
  fi

  mkdir -p "$proj/docs" "$proj/iac" "$proj/deploy"

  # Link source into the project dir if not already linked/present.
  if [[ ! -e "$proj/source" ]]; then
    local abs
    abs="$(cd "$source_path" && pwd)"
    ln -s "$abs" "$proj/source"
  fi

  # deploy history file (append-only JSONL).
  : > "$proj/deploy/history.jsonl"

  cat > "$f" <<EOF
repo: $repo
source_path: $(cd "$source_path" && pwd)
created_at: $(_state_now_iso)
region: ""
env: ""
infra_option: ""
status:
  analyzed: false
  recommended: false
  selected: false
  iac_generated: false
  infra_deployed: false
  app_deployed: false
deploys: []
EOF
  echo "$f"
}

# state_get <repo> <yq-path>
# Reads a value from state.yaml. Path is a yq expression without the leading dot
# (e.g. "region" or "status.analyzed" or "deploys[-1].git_sha").
state_get() {
  local repo="$1" key="$2"
  _state_require_yq
  _state_require_repo "$repo"
  _state_require_exists "$repo"
  yq eval ".${key}" "$(_state_file "$repo")"
}

# state_set <repo> <yq-path> <value>
# Writes a string value. For booleans use state_set_bool; for raw expressions
# use state_set_raw.
state_set() {
  local repo="$1" key="$2" value="$3"
  _state_require_yq
  _state_require_repo "$repo"
  _state_require_exists "$repo"
  VAL="$value" yq eval ".${key} = strenv(VAL)" -i "$(_state_file "$repo")"
}

# state_set_bool <repo> <yq-path> <true|false>
state_set_bool() {
  local repo="$1" key="$2" value="$3"
  _state_require_yq
  _state_require_repo "$repo"
  _state_require_exists "$repo"
  case "$value" in
    true|false) ;;
    *) echo "state.sh: state_set_bool expects 'true' or 'false', got '$value'" >&2; return 1 ;;
  esac
  yq eval ".${key} = ${value}" -i "$(_state_file "$repo")"
}

# state_set_raw <repo> <yq-path> <raw-yq-rhs>
# Use when value is a number, list, or already-quoted scalar.
state_set_raw() {
  local repo="$1" key="$2" raw="$3"
  _state_require_yq
  _state_require_repo "$repo"
  _state_require_exists "$repo"
  yq eval ".${key} = ${raw}" -i "$(_state_file "$repo")"
}

# state_check <repo> <status-key> [<status-key> ...]
# Returns 0 if all named status flags are true, 1 otherwise. Prints which one
# failed to stderr.
state_check() {
  local repo="$1"; shift
  _state_require_yq
  _state_require_repo "$repo"
  _state_require_exists "$repo"
  local f val key
  f="$(_state_file "$repo")"
  for key in "$@"; do
    val="$(yq eval ".status.${key}" "$f")"
    if [[ "$val" != "true" ]]; then
      echo "state.sh: prerequisite not met — status.${key} = ${val}" >&2
      return 1
    fi
  done
  return 0
}

# state_add_deploy <repo> <json-object>
# Appends to deploys[] in state.yaml AND to deploy/history.jsonl.
# JSON object should include at minimum: ts, git_sha, image, result.
state_add_deploy() {
  local repo="$1" json="$2"
  _state_require_yq
  _state_require_repo "$repo"
  _state_require_exists "$repo"
  command -v jq >/dev/null 2>&1 \
    || { echo "state.sh: 'jq' is required (run ./bootstrap.sh)" >&2; return 1; }

  # Validate JSON.
  echo "$json" | jq -e . >/dev/null \
    || { echo "state.sh: state_add_deploy got invalid JSON" >&2; return 1; }

  # Append to YAML deploys list.
  JSON="$json" yq eval '.deploys += [env(JSON)]' -i "$(_state_file "$repo")"

  # Append to JSONL log.
  echo "$json" >> "$(_state_project_dir "$repo")/deploy/history.jsonl"
}

# state_last_success <repo>
# Prints the JSON of the most recent deploy with result == "success", or empty.
state_last_success() {
  local repo="$1"
  _state_require_repo "$repo"
  local hist
  hist="$(_state_project_dir "$repo")/deploy/history.jsonl"
  [[ -f "$hist" ]] || { echo ""; return 0; }
  tac "$hist" 2>/dev/null | awk 'NR<=200' | while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if echo "$line" | jq -e 'select(.result=="success")' >/dev/null 2>&1; then
      echo "$line"
      return 0
    fi
  done
}

# state_list
# Lists every initialized project (one repo name per line).
state_list() {
  local d
  for d in "$DEVOPS_AI_ROOT/projects"/*/; do
    [[ -f "$d/state.yaml" ]] || continue
    basename "$d"
  done
}

# state_summary <repo>
# Human-readable status print.
state_summary() {
  local repo="$1"
  _state_require_yq
  _state_require_repo "$repo"
  _state_require_exists "$repo"
  yq eval '
    "repo: " + .repo,
    "env: " + (.env // ""),
    "region: " + (.region // ""),
    "infra_option: " + (.infra_option // ""),
    "status:",
    (.status | to_entries | .[] | "  " + .key + ": " + (.value | tostring))
  ' "$(_state_file "$repo")"
}
