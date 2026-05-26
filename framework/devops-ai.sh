#!/usr/bin/env bash
# devops-ai.sh — main CLI dispatcher.
# All commands are thin orchestration: load state → preflight → render prompt
# → invoke Goose recipe → update state.

set -euo pipefail

readonly FRAMEWORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DEVOPS_AI_ROOT="$(cd "$FRAMEWORK_DIR/.." && pwd)"
export FRAMEWORK_DIR DEVOPS_AI_ROOT

# shellcheck disable=SC1091
source "$FRAMEWORK_DIR/lib/state.sh"
# shellcheck disable=SC1091
source "$FRAMEWORK_DIR/lib/render.sh"
# shellcheck disable=SC1091
source "$FRAMEWORK_DIR/lib/validators.sh"
# shellcheck disable=SC1091
source "$FRAMEWORK_DIR/lib/outputs.sh"

c_red()    { printf '\033[31m%s\033[0m\n' "$*"; }
c_green()  { printf '\033[32m%s\033[0m\n' "$*"; }
c_yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
c_blue()   { printf '\033[34m%s\033[0m\n' "$*"; }
c_dim()    { printf '\033[90m%s\033[0m\n' "$*"; }

step()  { c_blue "==> $*"; }
ok()    { c_green "  ✓ $*"; }
warn()  { c_yellow "  ! $*"; }
die()   { c_red "  ✗ $*" >&2; exit 1; }

# ---- step intro/outro framing ----------------------------------------------
# Each cmd_X is wrapped between step_intro (says what's about to happen +
# rough ETA) and step_outro (says what was produced + the literal next
# command + access URLs if applicable). Output is plain text so the UI
# WebSocket stream renders it readably.

# step_intro <action> <eta> <what>
step_intro() {
  local action="$1" eta="$2" what="$3"
  echo
  c_blue "─────────────────────────────────────────────────────────────"
  c_blue "  STEP: $action"
  c_blue "  WHAT: $what"
  c_blue "  ETA:  $eta"
  c_blue "─────────────────────────────────────────────────────────────"
  echo
  STEP_START_TS=$SECONDS
}

# Format SECONDS-delta as human duration ("47s", "3m12s", "1h05m").
_human_dur() {
  local s="$1"
  if   (( s < 60   )); then printf '%ds' "$s"
  elif (( s < 3600 )); then printf '%dm%02ds' "$((s/60))" "$((s%60))"
  else                      printf '%dh%02dm' "$((s/3600))" "$(((s%3600)/60))"
  fi
}

# step_outro <action> [body lines...]
# Each remaining argument becomes one indented body line. Body is meant
# for "what was produced", "next command", access URLs, etc.
step_outro() {
  local action="$1"; shift
  local elapsed=$(( SECONDS - ${STEP_START_TS:-$SECONDS} ))
  local dur; dur="$(_human_dur "$elapsed")"
  echo
  c_green "─────────────────────────────────────────────────────────────"
  c_green "  DONE: $action   (took $dur)"
  echo
  local line
  for line in "$@"; do
    printf '  %s\n' "$line"
  done
  c_green "─────────────────────────────────────────────────────────────"
  echo
}

# ---- helpers ----------------------------------------------------------------

project_dir()   { printf '%s/projects/%s' "$DEVOPS_AI_ROOT" "$1"; }
project_docs()  { printf '%s/docs' "$(project_dir "$1")"; }
project_iac()   { printf '%s/iac' "$(project_dir "$1")"; }
project_dep()   { printf '%s/deploy' "$(project_dir "$1")"; }

ensure_param() {
  local name="$1" value="${2:-}"
  [[ -n "$value" ]] || die "missing required argument: $name"
}

# Resolve the cloud + skeleton_id for a given project. Reads `cloud` from
# state.yaml (set by `cmd_select`); defaults to `aws` for projects that
# haven't run select yet (e.g. mid-assess). Skeleton id is looked up via
# the clouds registry. Used by recipes that take `cloud=` / `skeleton_id=`
# params to render cloud-specific guidance in their prompt.
_resolve_cloud_skeleton() {
  local repo="$1"
  local cloud; cloud="$(state_get "$repo" cloud 2>/dev/null || echo "")"
  [[ -n "$cloud" ]] || cloud="aws"

  local registry="$FRAMEWORK_DIR/templates/iac/clouds.yaml"
  local skeleton=""
  if [[ -f "$registry" ]] && command -v yq >/dev/null 2>&1; then
    skeleton="$(yq eval ".\"$cloud\".default_skeleton // \"\"" "$registry" 2>/dev/null)"
  fi
  [[ -n "$skeleton" ]] || skeleton="ecs-fargate-rds"
  printf "%s\t%s" "$cloud" "$skeleton"
}

# Cloud-aware recipe dispatch. Recipes whose body is heavily cloud-specific
# (deploy-app, upgrade, rollback, audit) ship a per-cloud variant under
# recipes/<base>-<cloud>.yaml. AWS keeps the base name (`deploy-app.yaml`)
# both for backwards compat with the existing artefact and because AWS is
# the default cloud. Azure and future clouds use the `-<cloud>` suffix.
#
# Usage:
#   recipe="$(_recipe_for_cloud deploy-app "$cloud")"
#   run_recipe "$recipe" ...
_recipe_for_cloud() {
  local base="$1" cloud="${2:-aws}"
  case "$cloud" in
    aws|"")
      echo "$base"
      ;;
    *)
      local candidate="${base}-${cloud}"
      if [[ -f "$FRAMEWORK_DIR/recipes/${candidate}.yaml" ]]; then
        echo "$candidate"
      else
        # Fall back to the AWS base recipe and let the operator know.
        # The base recipe's prompt is AWS-flavored, so this is a best-effort
        # path that may produce sub-optimal results — but better than failing
        # outright when the cloud-specific variant hasn't been authored yet.
        c_dim "    no recipe '${candidate}.yaml' found — falling back to base '${base}.yaml'" >&2
        echo "$base"
      fi
      ;;
  esac
}

# Per-recipe model override. Returns the goose model name (passed through
# claude-acp adapter to claude CLI) for the given recipe.
#
# Policy: Opus 4.7 everywhere. Earlier tiering (Haiku for analyze, Sonnet
# for operational steps) traded quality for cost/speed, but in real runs
# Sonnet kept getting stuck on long-running terragrunt apply (auto-background
# → Monitor poll loop) and missed non-obvious source contracts (e.g.
# PG_SSL_ALLOW_SELF_SIGNED). Opus follows the no-Monitor / explicit-
# success-marker rules consistently and finds source mismatches Sonnet
# misses. Override globally with RECIPE_MODEL_OVERRIDE=<model> for
# experimentation.

# Read the active goose provider. Env wins over config because goose itself
# resolves env first — if backend/uvicorn was started with GOOSE_PROVIDER=ollama
# (e.g. after /api/llm/local/activate set it in the process env), goose sees
# ollama regardless of what the file says. Reading env first keeps shell-side
# decisions (whether to pass --model override) consistent with what goose
# actually does. Empty string only if neither source is set.
_active_goose_provider() {
  if [[ -n "${GOOSE_PROVIDER:-}" ]]; then
    echo "$GOOSE_PROVIDER"
    return
  fi
  local cfg="$HOME/.config/goose/config.yaml"
  [[ -f "$cfg" ]] || { echo ""; return; }
  grep -m1 '^GOOSE_PROVIDER:' "$cfg" 2>/dev/null \
    | awk -F: '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}'
}

_recipe_model() {
  # When the operator activated a Local LLM (ollama / openai-compat) via
  # the Setup tab, we MUST NOT pass --model claude-opus-4-7 to goose —
  # the local backend has no such model and the recipe will fail with
  # "model not found". Returning empty here drops the --model flag so
  # goose uses GOOSE_MODEL from its config (the local model the operator
  # picked). Per-recipe Opus mapping only applies on Anthropic.
  local provider; provider="$(_active_goose_provider)"
  case "$provider" in
    claude-acp|anthropic|"") ;;     # fall through to per-recipe mapping
    *)                       echo ""; return ;;  # local provider: no override
  esac

  case "$1" in
    analyze|recommend|assess|generate-iac|infra-plan|\
    infra-apply|deploy-app|upgrade|rollback|audit)
                                     echo "claude-opus-4-7"   ;;
    *)                               echo ""                  ;;
  esac
}

# Per-recipe MCP-extension plan. The framework automatically enables/disables
# `aws-api` (talks to AWS) and `terraform` (HashiCorp registry lookups) in
# the user's ~/.config/goose/config.yaml before each recipe.
#
# Recipes ending in `-azure` get aws-api OFF — Azure operations happen via
# the `az` CLI through the developer MCP, not via aws-api. (When/if an
# Azure-specific MCP server is added, plug it in here as
# `azure-api:true` for those recipes.)
#
# Format: space-separated "name:true" / "name:false" pairs.
_recipe_mcp_plan() {
  case "$1" in
    # ---- AWS recipes (default) ------------------------------------------
    analyze|recommend|assess)        echo "aws-api:true  terraform:true"  ;;
    audit)                           echo "aws-api:true  terraform:true"  ;;
    generate-iac)                    echo "aws-api:false terraform:true"  ;;
    infra-plan|infra-apply)          echo "aws-api:true  terraform:true"  ;;
    deploy-app|upgrade|rollback)     echo "aws-api:true  terraform:false" ;;

    # ---- Azure recipes --------------------------------------------------
    # aws-api OFF — irrelevant for Azure. terraform MCP stays ON for
    # registry / provider lookups (terragrunt + azurerm provider docs).
    # Operational recipes drop terraform too — they only need `az` via dev MCP.
    audit-azure)                     echo "aws-api:false terraform:true"  ;;
    infra-plan-azure|infra-apply-azure) echo "aws-api:false terraform:true" ;;
    deploy-app-azure|upgrade-azure|rollback-azure) echo "aws-api:false terraform:false" ;;
    recommend-azure|assess-azure)    echo "aws-api:false terraform:true"  ;;

    *)                               echo ""                              ;;
  esac
}

# Cross-check `db_engine_version` in <repo>/iac/inputs.yaml against the
# cloud's currently-offered versions in the configured region. Cloud
# providers retire minor / major versions over time, so a value that was
# valid when generate-iac ran can be rejected at apply time. If we find
# the configured version is no longer offered, we rewrite inputs.yaml to
# the latest stable nearby version and warn the operator.
#
# Best-effort: silent on missing inputs.yaml, missing CLI, network / auth
# error. Never blocks deploy — terragrunt apply will catch any real
# incompatibility definitively.
#
# Currently hardcodes engine=postgres because that is the only DB engine
# both bundled skeletons use. Extend if you add mysql/etc skeletons.
_normalize_db_engine_version() {
  local repo="$1"
  local cloud; cloud="$(state_get "$repo" cloud 2>/dev/null || echo "aws")"
  case "$cloud" in
    azure) _normalize_db_engine_version_azure "$repo" ;;
    aws|*) _normalize_db_engine_version_aws   "$repo" ;;
  esac
}

# AWS RDS Postgres validation. Hardened so a region without AWS auth
# (e.g. an Azure region typed in by mistake on a misconfigured AWS
# project) doesn't kill the script under `set -e -o pipefail`.
_normalize_db_engine_version_aws() {
  local repo="$1"
  local inputs_yaml; inputs_yaml="$(project_iac "$repo")/inputs.yaml"
  [[ -f "$inputs_yaml" ]] || return 0

  command -v yq  >/dev/null 2>&1 || return 0
  command -v aws >/dev/null 2>&1 || return 0

  local current; current="$(yq eval '.db_engine_version // ""' "$inputs_yaml" 2>/dev/null)"
  [[ -n "$current" && "$current" != "null" ]] || return 0

  local region; region="$(state_get "$repo" region 2>/dev/null || true)"
  [[ -n "$region" ]] || return 0

  local major="${current%%.*}"
  local engine="postgres"

  step "Validating ${engine} engine_version=${current} against AWS RDS in ${region}"

  # `aws ... | tr | sort | uniq` under pipefail dies if aws errors. Wrap
  # with set +e so we can recover gracefully and report continue-with-warn
  # instead of taking the whole pipeline down.
  local available rc
  set +e
  available="$(aws rds describe-db-engine-versions \
        --engine "$engine" \
        --region "$region" \
        --query "DBEngineVersions[?starts_with(EngineVersion, '${major}.')].EngineVersion" \
        --output text 2>/dev/null \
        | tr '\t' '\n' | sort -V | uniq)"
  rc=$?
  set -e

  if (( rc != 0 )) || [[ -z "$available" ]]; then
    warn "could not query AWS RDS engine versions (network / IAM / wrong region?). Continuing with '$current' — terragrunt apply will catch any incompatibility."
    return 0
  fi

  if grep -qFx "$current" <<< "$available"; then
    ok "${engine} ${current} is currently supported by AWS RDS in ${region}"
    return 0
  fi

  local replacement; replacement="$(tail -1 <<< "$available")"
  warn "${engine} ${current} is no longer offered by AWS RDS in ${region}"
  warn "  available ${major}.x: $(tr '\n' ' ' <<< "$available")"
  warn "  rewriting $inputs_yaml: db_engine_version '${current}' → '${replacement}'"
  yq eval -i ".db_engine_version = \"${replacement}\"" "$inputs_yaml"
  ok "inputs.yaml updated; deploy will use ${engine} ${replacement}"
}

# Azure Postgres Flexible Server validation.
#
# Azure differs from AWS in two ways:
#  1. The CLI takes MAJOR ONLY ("16"). A full version like "16.13" causes
#     an apply-time validation error. So we always normalize to the major.
#  2. Versions are listed via `az postgres flexible-server list-skus
#     --location <region>` → `.[].supportedServerVersions[].name`.
#     The list is region-scoped (some regions retire majors faster than
#     others — e.g. Postgres 11 is gone everywhere).
#
# Strategy:
#  - Normalize current → major.
#  - Query the supported majors for the region.
#  - If current major is supported → ok.
#  - If not → pick the highest stable major from the supported list that
#    is ≤ the requested major (don't auto-upgrade across majors); fall
#    back to the highest available if no such version exists.
_normalize_db_engine_version_azure() {
  local repo="$1"
  local inputs_yaml; inputs_yaml="$(project_iac "$repo")/inputs.yaml"
  [[ -f "$inputs_yaml" ]] || return 0

  command -v yq >/dev/null 2>&1 || return 0
  command -v az >/dev/null 2>&1 || { warn "az CLI not on PATH — skipping Azure Postgres version validation"; return 0; }

  local current; current="$(yq eval '.db_engine_version // ""' "$inputs_yaml" 2>/dev/null)"
  [[ -n "$current" && "$current" != "null" ]] || return 0

  local region; region="$(state_get "$repo" region 2>/dev/null || true)"
  [[ -n "$region" ]] || return 0

  # Always strip to major. Azure Flexible refuses minors.
  local major="${current%%.*}"
  if [[ "$current" != "$major" ]]; then
    warn "Azure Postgres Flexible accepts MAJOR ONLY — normalizing '$current' → '$major'"
    yq eval -i ".db_engine_version = \"${major}\"" "$inputs_yaml"
  fi

  step "Validating postgres engine_version=${major} against Azure Flexible Server in ${region}"

  local supported rc
  set +e
  supported="$(az postgres flexible-server list-skus \
        --location "$region" --output json 2>/dev/null \
        | jq -r '[.[].supportedServerVersions[]?.name] | unique | .[]' 2>/dev/null \
        | sort -n | uniq)"
  rc=$?
  set -e

  if (( rc != 0 )) || [[ -z "$supported" ]]; then
    warn "could not query Azure Postgres versions (auth? region? az login?). Continuing with major='$major' — terragrunt apply will catch any incompatibility."
    return 0
  fi

  if grep -qFx "$major" <<< "$supported"; then
    ok "postgres major ${major} is supported by Azure Flexible Server in ${region}"
    return 0
  fi

  # Pick the highest supported major <= current. If none, take the highest
  # available overall (likely a downgrade, but better than refusing to deploy).
  local replacement
  replacement="$(awk -v target="$major" '{ if ($0+0 <= target+0) print }' <<< "$supported" | tail -1)"
  [[ -n "$replacement" ]] || replacement="$(tail -1 <<< "$supported")"

  warn "postgres major ${major} is not offered by Azure Flexible Server in ${region}"
  warn "  available majors: $(tr '\n' ' ' <<< "$supported")"
  warn "  rewriting $inputs_yaml: db_engine_version '${major}' → '${replacement}'"
  yq eval -i ".db_engine_version = \"${replacement}\"" "$inputs_yaml"
  ok "inputs.yaml updated; deploy will use postgres ${replacement}"
}

# Apply the plan in-place to ~/.config/goose/config.yaml.
# Skips extensions the user hasn't installed; no auto-creation.
_configure_mcps() {
  local config="$HOME/.config/goose/config.yaml"
  [[ -f "$config" ]] || { warn "goose config not found at $config — skipping MCP setup"; return 0; }
  local pair name target current
  for pair in "$@"; do
    name="${pair%:*}"
    target="${pair#*:}"
    current="$(yq eval ".extensions.\"${name}\".enabled // \"_missing_\"" "$config" 2>/dev/null)"
    [[ "$current" == "_missing_" ]] && continue   # extension not in user's config
    if [[ "$current" != "$target" ]]; then
      yq eval -i ".extensions.\"${name}\".enabled = ${target}" "$config"
      c_dim "    mcp ${name}: ${current} → ${target}"
    fi
  done
}

# Run a Goose recipe with key=value parameters and verify it actually finished.
# Args: <recipe-name> <success-regex> [k=v ...]
#
# Why the success-regex: local Ollama can hit transient `Stream decode error`s
# mid-session. Goose returns exit 0 because the session technically ended, but
# the model never reached the work it was asked to do. We require each recipe
# to print a distinctive completion marker (e.g. `WROTE /path/...` or
# `IAC READY /...`) and grep the captured output for it. If the marker is
# missing, we retry up to RECIPE_MAX_ATTEMPTS (default 3) total times.
#
# GOOSE_MODE=auto: `goose run --recipe` is non-interactive; `smart_approve`
# (the user's default for chat sessions) hangs without a terminal to answer
# approval prompts. So model-side "stop and ask" prompts are decorative — the
# model has no stdin connected. For real human gating (e.g. plan→approve→apply
# in deploy-infra), the gate lives in shell: a recipe writes a summary file,
# the bash command pauses with `read -r` against the operator's terminal, and
# only then the next recipe is invoked. The shell is the gate, not the model.
# Set on every run_recipe invocation. Empty string after a successful run
# (logfile already deleted), or a path to the retained logfile after a failed
# run. Callers that want to inspect the failure log (e.g. cmd_apply_infra
# scanning for state-lock errors) read this immediately after run_recipe
# returns non-zero — DO NOT rely on it after any other shell command runs.
LAST_RECIPE_LOG=""

run_recipe() {
  local recipe="$1" success_re="$2"; shift 2
  local recipe_path="$FRAMEWORK_DIR/recipes/${recipe}.yaml"
  [[ -f "$recipe_path" ]] || die "recipe not found: $recipe_path"

  command -v goose >/dev/null 2>&1 || die "goose not on PATH. Run framework/bootstrap.sh."

  # Apply per-recipe MCP plan before launching goose.
  local mcp_plan
  mcp_plan="$(_recipe_mcp_plan "$recipe")"
  if [[ -n "$mcp_plan" ]]; then
    # shellcheck disable=SC2086  # word-splitting is intentional here
    _configure_mcps $mcp_plan
  fi

  local args=()
  for kv in "$@"; do args+=(--params "$kv"); done

  # Per-recipe model tiering — Haiku for analyze, Sonnet for operational
  # steps, Opus for deep-reasoning self-heal (deploy-app/upgrade). Empty
  # string falls through to GOOSE_MODEL in ~/.config/goose/config.yaml.
  # Override the entire mapping with RECIPE_MODEL_OVERRIDE=<model> when
  # debugging or pinning to a single model for a session.
  local model_override="${RECIPE_MODEL_OVERRIDE:-$(_recipe_model "$recipe")}"
  local model_args=()
  if [[ -n "$model_override" ]]; then
    model_args=(--model "$model_override")
    c_dim "    model: $model_override"
  fi

  # Default attempts=1 since we run on Claude (Opus 4.7 / Sonnet 4.6 / Haiku
  # 4.5 depending on recipe) which gets it right the first time; retries
  # only mask real environment problems (Gatekeeper, missing AWS resources,
  # wrong creds). Override with RECIPE_MAX_ATTEMPTS=N for debugging.
  local max_attempts="${RECIPE_MAX_ATTEMPTS:-1}"
  local attempt=1 logfile rc
  logfile="$(mktemp -t devops-ai-recipe.XXXXXX)"

  while (( attempt <= max_attempts )); do
    step "Running Goose recipe: $recipe  (attempt $attempt/$max_attempts)"
    : > "$logfile"
    set +e
    # TG_PARALLELISM=1 — terragrunt's plugin_cache_dir is not safe under
    # parallel `init`s. Multiple units symlinking the same provider binary
    # at once causes 'Failed to read plugin's stdout'. Serialize to 1.
    GOOSE_MODE=auto TG_PARALLELISM=1 \
      goose run "${model_args[@]}" --recipe "$recipe_path" "${args[@]}" 2>&1 \
        | tee -a "$logfile"
    rc="${PIPESTATUS[0]}"
    set -e

    if grep -qE "$success_re" "$logfile"; then
      ok "recipe '$recipe' completed (success marker matched)"
      _print_token_usage "$logfile"
      rm -f "$logfile"
      LAST_RECIPE_LOG=""
      return 0
    fi

    warn "recipe '$recipe' attempt $attempt finished without success marker (rc=$rc, expected /${success_re}/)"
    if grep -qE "Stream decode error|error decoding response body" "$logfile"; then
      warn "  reason: Ollama stream error — retrying"
    fi
    attempt=$((attempt + 1))
  done

  c_red "  ✗ recipe '$recipe' failed after $max_attempts attempts" >&2
  echo "  last 20 lines of the final attempt:" >&2
  tail -20 "$logfile" >&2
  echo "  full log retained at: $logfile" >&2
  _print_token_usage "$logfile"
  LAST_RECIPE_LOG="$logfile"
  return 1
}

# ---- subcommands ------------------------------------------------------------

cmd_help() {
  cat <<EOF
DevOps AI Framework — CLI

Usage: devops-ai.sh <command> [args...]

Workflow commands:
  init <repo-path> [--name N] [--cloud aws|azure]
                               Register a project. Creates projects/<name>/.
                               --cloud picks the target cloud (default: aws).
                               Drives every downstream recipe + MCP toggle.
  analyze <repo>               Read source → docs/00_overview.md (English).
  assess <repo>                Read source, write ONE concise docs/00_overview.md
                               (project + deployment fit + extensions).
                               'analyze' and 'recommend' verbs forward here for
                               backwards compatibility.
  select <repo> <opts>         Lock the cloud, region, env, and any opt-in extensions.
                               Required: --region, --env
                               Optional: --cloud <aws|azure|gcp> (default: aws —
                                         each cloud resolves to its single
                                         registered skeleton from
                                         templates/iac/clouds.yaml),
                                         --skeleton (override registry default),
                                         --account-id, --include <csv>
                               --include accepts a comma list of opt-in extensions
                                         (keycloak, alb-https, redis, queue, frontend).
  generate-iac <repo>          Render skeleton + AI completes TODO markers.
  aws-login                    Helper around 'aws configure sso'.
  aws-bootstrap [<repo>]       Create the S3 tfstate bucket. Without args:
                               creates 'devops-ai-tfstate-<account>'. With
                               <repo>: reads bucket name from its inputs.yaml.
  az-login                     Run 'az login' interactively. (UI Setup tab is
                               the non-interactive path — Service Principal.)
  az-bootstrap [<repo>]        Create the Azure Storage Account + container
                               for tfstate. Mirror of aws-bootstrap.
  plan-infra <repo>            terragrunt run --all plan only. Writes a
                               human-reviewable plan_summary.md. No AWS mutation.
  apply-infra <repo>           Reads existing plan_summary.md, asks for explicit
                               approval, runs terragrunt apply.
  deploy-infra <repo>          plan + approve + apply in one shot (combines
                               plan-infra and apply-infra).
  deploy-app <repo> [git_ref]  docker build + ECR push + runtime update.
  upgrade <repo> <git_ref>     Roll out a specific git ref with stricter checks.
  rollback <repo>              Revert to the previous successful image.
  destroy <repo>               terragrunt run --all destroy (dev only).

Inspection:
  status [<repo>]              Show project state (or list all projects).
  list                         List initialized projects.
  catalog                      List available IaC skeletons + their READMEs.
  audit <repo>                 Drift / posture check vs deployed AWS state
                               → docs/02_audit.md. Run periodically.

Each step gates on prior state. The command flow is roughly:
  init → assess → select → generate-iac
       → plan-infra → apply-infra → deploy-app
                                  → upgrade / rollback / audit
EOF
}

cmd_menu() {
  cat <<EOF
=== DevOps AI Framework ===
  Workspace: $DEVOPS_AI_ROOT

What do you want to do?
  1) init <repo-path>     — register a new project (+ pick cloud)
  2) assess <repo>        — read repo + recommend extensions → 00_overview.md
  3) select <repo> ...    — lock region + env (+ extensions)
  4) generate-iac <repo>  — render Terragrunt + finish TODOs via AI
  6) aws-login            — set up AWS credentials
  7) plan-infra <repo>    — terragrunt plan only → plan_summary.md
  8) apply-infra <repo>   — approve existing plan + apply
  9) deploy-infra <repo>  — plan + approve + apply (combo)
 10) deploy-app <repo>    — build image + push + update runtime
 11) upgrade <repo> <ref> — roll out a specific git ref
 12) rollback <repo>      — revert to previous successful image
 13) status [<repo>]      — print state
 14) destroy <repo>       — tear env down (dev only)

Run with no command for this menu, or '--help' for the full reference.
EOF
}

cmd_init() {
  local source_path="" name="" cloud=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)    name="$2"; shift 2 ;;
      --name=*)  name="${1#*=}"; shift ;;
      --cloud)   cloud="$2"; shift 2 ;;
      --cloud=*) cloud="${1#*=}"; shift ;;
      -*) die "unknown option: $1" ;;
      *)
        [[ -z "$source_path" ]] || die "init takes one repo path; got extra: $1"
        source_path="$1"; shift ;;
    esac
  done
  ensure_param "<repo-path>" "$source_path"
  source_path="$(cd "$source_path" 2>/dev/null && pwd)" \
    || die "source path is not a directory"

  if [[ -z "$name" ]]; then
    name="$(basename "$source_path")"
    case "$name" in
      source|src|main|app|repo)
        die "the source path basename is '$name' which is too generic. Pass --name <project-name>."
        ;;
    esac
  fi
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] \
    || die "project name '$name' must match [A-Za-z0-9._-]+"

  # Cloud is a first-class init-time decision. It drives every downstream
  # recipe (deploy-app vs deploy-app-azure, AWS-api MCP toggle, identity
  # check in infra-apply, etc.). Default `aws` for backwards-compat with
  # CLI invocations that omit --cloud.
  : "${cloud:=aws}"
  local registry="$FRAMEWORK_DIR/templates/iac/clouds.yaml"
  if [[ -f "$registry" ]] && command -v yq >/dev/null 2>&1; then
    local cloud_status
    cloud_status="$(yq eval ".\"$cloud\".status // \"\"" "$registry")"
    [[ -n "$cloud_status" ]] \
      || die "unknown cloud '$cloud'. Known: $(yq eval 'keys | join(\", \")' "$registry")"
    [[ "$cloud_status" == "available" ]] \
      || die "cloud '$cloud' is not yet available (status: $cloud_status). Pick aws or another cloud with status=available."
  fi

  step_intro "init" \
    "instant" \
    "Register a new project '$name' under projects/$name/ for cloud=$cloud, and remember its source path."
  step "Initializing project '$name' from $source_path  (cloud=$cloud)"
  state_init "$name" "$source_path"
  state_set "$name" cloud "$cloud"
  ok "project registered at $(project_dir "$name")  (cloud=$cloud)"
  step_outro "init" \
    "Output:  projects/$name/  (state.yaml, docs/, iac/, deploy/)" \
    "Cloud:   $cloud  (override later with: ./devops-ai.sh select $name --cloud <other> ...)" \
    "Next:    ./devops-ai.sh analyze $name"
}

cmd_analyze() {
  # `analyze` was the older "just describe the project" path; it has been
  # folded into `assess` which writes the same single concise overview AND
  # includes the deployment-fit / extensions block. Keep this verb working
  # so existing scripts / docs don't break.
  warn "'analyze' has been folded into 'assess'. Forwarding to: ./devops-ai.sh assess $1"
  cmd_assess "$@"
  return $?
}

cmd_recommend() {
  # NOTE: `recommend` is folded into `assess` — the latter writes a single
  # combined `00_overview.md` that includes both the project description
  # and the deployment-fit / extensions section. This stub remains so the
  # CLI still recognises the verb (and prints a hint), but it forwards to
  # assess rather than producing a separate `02_infra_options.md`.
  warn "'recommend' has been folded into 'assess'. Forwarding to: ./devops-ai.sh assess $1"
  cmd_assess "$@"
  return $?
}

# Dead-code keeper: previously cmd_recommend ran a separate recipe.
# Kept commented for git-history reference; remove on next major bump.
_legacy_cmd_recommend_disabled() {
  local repo="${1:-}"; shift || true
  ensure_param "<repo>" "$repo"
  local cloud_override=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cloud)   cloud_override="$2"; shift 2 ;;
      --cloud=*) cloud_override="${1#*=}"; shift ;;
      *) shift ;;
    esac
  done
  if [[ -n "$cloud_override" ]]; then
    state_set "$repo" cloud "$cloud_override"
  fi
  preflight_recommend "$repo"
  state_check "$repo" analyzed
  local overview_path="$(project_docs "$repo")/00_overview.md"
  local out_path="$(project_docs "$repo")/02_infra_options.md"
  local templates_dir="$FRAMEWORK_DIR/templates/iac"
  local cloud skeleton
  IFS=$'\t' read -r cloud skeleton <<< "$(_resolve_cloud_skeleton "$repo")"
  step_intro "recommend" \
    "30-90 seconds" \
    "AI assesses how this stack fits the ${cloud^^} skeleton ($skeleton) and recommends which opt-in extensions to enable."
  run_recipe recommend "WROTE ${out_path}" \
    "repo_name=$repo" \
    "overview_path=$overview_path" \
    "templates_dir=$templates_dir" \
    "cloud=$cloud" \
    "skeleton_id=$skeleton" \
    "output_path=$out_path"

  [[ -s "$out_path" ]] || die "recommend: success marker matched but $out_path is empty"
  state_set_bool "$repo" status.recommended true
  ok "options written → $out_path"
  step_outro "recommend" \
    "Output:  $out_path" \
    "         (open in UI — note recommended extensions and any caveats)" \
    "Next:    ./devops-ai.sh select $repo --region <r> --env dev [--include <csv>]"
}

cmd_select() {
  local repo="${1:-}"; shift || true
  ensure_param "<repo>" "$repo"

  step_intro "select" \
    "instant" \
    "Lock in the cloud, region, and opt-in extensions; render the operator runbook."

  local cloud="" skeleton="" region="" env="" account_id="" include_csv=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cloud)        cloud="$2"; shift 2 ;;
      --cloud=*)      cloud="${1#*=}"; shift ;;
      --skeleton)     skeleton="$2"; shift 2 ;;
      --skeleton=*)   skeleton="${1#*=}"; shift ;;
      --region)       region="$2"; shift 2 ;;
      --region=*)     region="${1#*=}"; shift ;;
      --env)          env="$2"; shift 2 ;;
      --env=*)        env="${1#*=}"; shift ;;
      --account-id)   account_id="$2"; shift 2 ;;
      --account-id=*) account_id="${1#*=}"; shift ;;
      --include)      include_csv="$2"; shift 2 ;;
      --include=*)    include_csv="${1#*=}"; shift ;;
      *) die "unknown option: $1" ;;
    esac
  done

  # Cloud → skeleton resolution via templates/iac/clouds.yaml.
  # The choice the operator makes is *cloud*, not *architecture* — each cloud
  # ships exactly one default skeleton. If a cloud later grows alternatives,
  # add them in clouds.yaml and reintroduce a per-cloud chooser only there.
  local registry="$FRAMEWORK_DIR/templates/iac/clouds.yaml"
  [[ -f "$registry" ]] || die "cloud registry not found at $registry"
  command -v yq >/dev/null 2>&1 || die "yq required for cloud resolution"

  : "${cloud:=aws}"
  local cloud_status
  cloud_status="$(yq eval ".\"$cloud\".status // \"\"" "$registry")"
  [[ -n "$cloud_status" ]] || die "unknown cloud '$cloud'. Known: $(yq eval 'keys | join(\", \")' "$registry")"
  [[ "$cloud_status" == "available" ]] \
    || die "cloud '$cloud' is not yet available (status: $cloud_status). Currently supported: aws."

  if [[ -z "$skeleton" ]]; then
    skeleton="$(yq eval ".\"$cloud\".default_skeleton // \"\"" "$registry")"
    [[ -n "$skeleton" ]] || die "no default skeleton registered for cloud '$cloud' in $registry"
  fi
  [[ -d "$FRAMEWORK_DIR/templates/iac/$skeleton" ]] \
    || die "skeleton '$skeleton' not found in $FRAMEWORK_DIR/templates/iac/ (cloud=$cloud)"

  ensure_param "--region" "$region"
  ensure_param "--env" "$env"
  # Region validators depend on the cloud. For now only AWS is `available`,
  # so we only run AWS region validation. Add azure/gcp validators when those
  # clouds flip to status=available.
  case "$cloud" in
    aws)   require_aws_region   "$region" ;;
    azure) require_azure_region "$region" ;;
    *)     c_dim "    region validation skipped for cloud=$cloud (not yet implemented)" ;;
  esac
  # Skeletons currently ship only the `dev` environment (stage/prod folders
  # were dropped). Add them back to templates/iac/<skeleton>/environments/
  # if you decide to support multi-env again.
  case "$env" in dev) ;; *) die "--env must be 'dev' (got '$env'). Skeletons only ship dev/." ;; esac

  # Validate --include values against the skeleton's known optional units.
  # Each skeleton can advertise its own catalogue of opt-in extensions; for now
  # we hardcode the ecs-fargate-rds set. Adding new ones means: add a leaf with
  # `skip = !try(local.inputs_yaml.include_X == "true", false)` and accept the
  # name here.
  local known_extensions=(keycloak alb-https redis queue frontend)
  local extensions_arr=()
  if [[ -n "$include_csv" ]]; then
    IFS=',' read -r -a extensions_arr <<< "$include_csv"
    local ext
    for ext in "${extensions_arr[@]}"; do
      ext="$(echo "$ext" | tr -d '[:space:]')"
      local valid=0 known
      for known in "${known_extensions[@]}"; do
        [[ "$known" == "$ext" ]] && valid=1
      done
      [[ "$valid" == "1" ]] || die "unknown extension '$ext'. Known for $skeleton: ${known_extensions[*]}"
    done
  fi

  state_check "$repo" recommended
  state_set "$repo" cloud "$cloud"
  state_set "$repo" infra_option "$skeleton"
  state_set "$repo" region "$region"
  state_set "$repo" env "$env"
  [[ -n "$account_id" ]] && state_set "$repo" account_id "$account_id"
  # Persist the comma-cleaned extensions list as a single string in state.yaml.
  # Reading happens in cmd_generate_iac, which translates to include_<ext> flags.
  if (( ${#extensions_arr[@]} > 0 )); then
    state_set "$repo" extensions "$(IFS=,; echo "${extensions_arr[*]}" | tr -d '[:space:]')"
  fi
  state_set_bool "$repo" status.selected true

  ok "selection saved: cloud=$cloud skeleton=$skeleton region=$region env=$env"
  if (( ${#extensions_arr[@]} > 0 )); then
    ok "extensions:        ${extensions_arr[*]}"
  fi
  step_outro "select" \
    "Cloud:      $cloud  (skeleton: $skeleton)" \
    "Region/env: $region / $env" \
    "Extensions: ${extensions_arr[*]:-(none)}" \
    "Next:       ./devops-ai.sh generate-iac $repo"
}

cmd_generate_iac() {
  local repo="${1:-}"; ensure_param "<repo>" "$repo"
  preflight_generate_iac "$repo"
  state_check "$repo" selected

  step_intro "generate-iac" \
    "10-30 seconds (mostly mechanical)" \
    "Render the chosen skeleton into the project's iac/ tree (Terragrunt units + modules + inputs.yaml)."

  local skeleton region env source_path cloud
  skeleton="$(state_get "$repo" infra_option)"
  region="$(state_get "$repo" region)"
  env="$(state_get "$repo" env)"
  source_path="$(state_get "$repo" source_path)"
  cloud="$(state_get "$repo" cloud 2>/dev/null || echo "aws")"

  local skeleton_dir="$FRAMEWORK_DIR/templates/iac/$skeleton"
  local iac_dir; iac_dir="$(project_iac "$repo")"
  local vars_yaml="$iac_dir/inputs.yaml"

  # Cache check — skip the entire recipe (and the rendering wipe-and-rebuild
  # that precedes it) if every input that affects the IaC output is unchanged
  # since the last successful run. Saves ~3-5M tokens on a re-run with the
  # same source / state / skeleton. Cache is invalidated automatically when
  # any of overview / state / recipe / skeleton tree changes. Force a re-run
  # by deleting the cache file.
  local cache_dir; cache_dir="$(project_dir "$repo")/.devops-ai-cache"
  local cache_file="$cache_dir/generate-iac.key"
  local current_key cached_key=""
  current_key="$(_generate_iac_cache_key "$repo" "$skeleton")"
  [[ -f "$cache_file" ]] && cached_key="$(cat "$cache_file" 2>/dev/null || echo "")"

  if [[ -n "$cached_key" && "$current_key" == "$cached_key" \
        && -d "$iac_dir/environments" ]]; then
    ok "generate-iac skipped — inputs unchanged since last successful run"
    c_dim "    cache key: $current_key"
    c_dim "    force re-run: rm $cache_file"
    state_set_bool "$repo" status.iac_generated true
    step_outro "generate-iac" \
      "Output:  $iac_dir  (preserved from previous run)" \
      "Next:    ./devops-ai.sh plan-infra $repo"
    return 0
  fi

  step "Rendering skeleton '$skeleton' (cloud=$cloud) → $iac_dir"
  rm -rf "$iac_dir"
  mkdir -p "$iac_dir"

  # Build the variable file the renderer expects. The skeleton's inputs.yaml.tmpl
  # declares which keys it needs; the operator can override values by editing
  # this file BEFORE calling generate-iac (we never overwrite if it already exists
  # with non-default content beyond the bootstrap pass).
  # All values are explicitly double-quoted. Without quotes, yq treats things
  # like "075422629683" as a number and silently drops the leading zero, and
  # "1.30" becomes 1.3. Quoting every scalar avoids that class of bug.
  local acct
  acct="$(state_get "$repo" account_id 2>/dev/null || true)"

  # Translate state.yaml's `extensions: keycloak,alb-https` into the
  # include_<ext> = "true|false" booleans the skeleton's inputs.yaml.tmpl
  # expects. Anything not in the comma-list defaults to "false".
  local extensions_csv inc_keycloak="false" inc_alb_https="false" inc_redis="false" \
        inc_queue="false" inc_frontend="false" inc_custom_domain_https="false"
  extensions_csv="$(state_get "$repo" extensions 2>/dev/null || true)"
  if [[ -n "$extensions_csv" && "$extensions_csv" != "null" ]]; then
    case ",${extensions_csv}," in *,keycloak,*)            inc_keycloak="true" ;; esac
    case ",${extensions_csv}," in *,alb-https,*)           inc_alb_https="true" ;; esac
    case ",${extensions_csv}," in *,redis,*)               inc_redis="true" ;; esac
    case ",${extensions_csv}," in *,queue,*)               inc_queue="true" ;; esac
    case ",${extensions_csv}," in *,frontend,*)            inc_frontend="true" ;; esac
    case ",${extensions_csv}," in *,custom-domain-https,*) inc_custom_domain_https="true" ;; esac
  fi

  local tmp_vars
  tmp_vars="$(mktemp)"

  # Default Postgres engine version differs by cloud:
  # - AWS RDS expects full minor (16.13). Older minors get retired roughly
  #   quarterly; the validator below auto-rewrites if AWS says ours is gone.
  # - Azure Postgres Flexible Server accepts MAJOR ONLY (16). Specifying a
  #   minor causes an apply-time error.
  local default_pg_version="16.13"
  [[ "$cloud" == "azure" ]] && default_pg_version="16"

  # Default log retention also differs by cloud:
  # - AWS CloudWatch accepts any value from 1 day onwards.
  # - Azure Log Analytics requires retention in [30, 730] days. Anything <30
  #   fails plan-time validation:
  #     "expected retention_in_days to be in the range (30 - 730), got 14"
  local default_log_retention="14"
  [[ "$cloud" == "azure" ]] && default_log_retention="30"

  # Common keys for every cloud's inputs.yaml.tmpl.
  cat > "$tmp_vars" <<EOF
project_name: "$repo"
region: "$region"
container_name: "app"
container_port: "8080"
health_check_path: "/health"
frontend_container_name: "web"
frontend_container_port: "80"
frontend_health_check_path: "/"
db_engine_version: "$default_pg_version"
db_name: "appdb"
domain_name: ""
log_retention_days: "$default_log_retention"
include_keycloak: "$inc_keycloak"
include_redis: "$inc_redis"
include_queue: "$inc_queue"
include_frontend: "$inc_frontend"
EOF

  # Cloud-specific keys. Each skeleton's inputs.yaml.tmpl only references
  # the ones it actually uses (rendering ignores extras), so it's safe to
  # generate the union for one cloud and not for the other — but we still
  # write only the relevant set to keep the rendered file clean and
  # debuggable.
  if [[ "$cloud" == "azure" ]]; then
    # Resolve Azure tenant + state-backend names from current az session.
    # If az isn't authenticated yet, leave blanks; operator will edit
    # inputs.yaml or re-run after Setup.
    local tenant_id="" state_storage_account="" state_container="tfstate"
    if command -v az >/dev/null 2>&1 && az account show >/dev/null 2>&1; then
      tenant_id="$(az account show --query tenantId -o tsv 2>/dev/null || true)"
    fi
    local sub_short="${acct:0:8}"
    sub_short="$(echo "$sub_short" | tr -d -)"   # strip dashes
    state_storage_account="devopsaitfst${sub_short:-default}"

    cat >> "$tmp_vars" <<EOF
db_admin_username: "pgadmin"
subscription_id: "$acct"
tenant_id: "$tenant_id"
state_storage_account: "$state_storage_account"
state_container: "$state_container"
include_custom_domain_https: "$inc_custom_domain_https"
EOF
  else
    # AWS — append a 12-digit random suffix to the tfstate bucket name. S3
    # bucket names are global; without randomness, deleting the bucket and
    # re-running bootstrap can race other accounts and (worst case) leak the
    # account-id-derived name. /dev/urandom over $RANDOM keeps entropy honest.
    #
    # NB: do NOT use `tr -dc '0-9' < /dev/urandom | head -c 12`. /dev/urandom
    # is infinite, so `head` closes stdin after 12 bytes, `tr`'s next write
    # gets SIGPIPE → exit 141. Under `set -o pipefail` the whole script dies.
    # We read a bounded pool from /dev/urandom up-front (2048 bytes ≈ 80 digits
    # after filtering on average; even 5σ below the mean we still get >50,
    # well over the 12 we need), then slice.
    local state_bucket_suffix rand_pool
    rand_pool="$(head -c 2048 /dev/urandom | LC_ALL=C tr -dc '0-9')"
    state_bucket_suffix="${rand_pool:0:12}"
    cat >> "$tmp_vars" <<EOF
account_id: "$acct"
db_master_username: "appuser"
include_alb_https: "$inc_alb_https"
cluster_version: "1.30"
app_namespace: "default"
app_service_account: "${repo}-sa"
app_port: "8080"
artifact_bucket: "${repo}-artifacts"
function_handler: "app.handler"
dynamo_partition_key: "pk"
dynamo_sort_key: ""
state_bucket: "${repo}-tfstate-${state_bucket_suffix}"
EOF
  fi

  render_dir "$skeleton_dir" "$iac_dir" "$tmp_vars"
  rm -f "$tmp_vars"

  if ! render_check_unresolved "$iac_dir"; then
    warn "some placeholders unresolved — may indicate skeleton vars / inputs mismatch"
  fi

  ok "skeleton rendered (no AI-step yet)"

  # Validate stale-default values (e.g. AWS-retired RDS minor versions) right
  # after render, so the project starts life with currently-supported values.
  _normalize_db_engine_version "$repo"

  # Pre-compute the exact list of TODO markers the AI must resolve. Without
  # this hint the model wastes most of its context budget exploring 50+
  # skeleton files just to find ~4 markers — and a 35B local model often
  # never reaches the editing phase. We hand the model a complete grep
  # result up front so it can skip exploration entirely.
  local todo_list_path="$iac_dir/.devops-ai-todos.txt"
  if grep -rn 'TODO(devops-ai)' "$iac_dir" > "$todo_list_path" 2>/dev/null; then
    local todo_count
    todo_count="$(wc -l < "$todo_list_path" | tr -d ' ')"
    ok "found $todo_count TODO marker(s) → $todo_list_path"
  else
    : > "$todo_list_path"
    ok "no TODO markers in skeleton — AI step has nothing to do"
  fi

  # Now hand off to AI to fill in the # TODO(devops-ai): markers.
  local overview_path="$(project_docs "$repo")/00_overview.md"
  run_recipe generate-iac "IAC READY ${iac_dir}" \
    "repo_name=$repo" \
    "source_path=$source_path" \
    "overview_path=$overview_path" \
    "skeleton_id=$skeleton" \
    "iac_dir=$iac_dir" \
    "vars_yaml=$vars_yaml" \
    "state_yaml=$(project_dir "$repo")/state.yaml" \
    "todo_list_path=$todo_list_path" \
    "region=$region" \
    "env=$env"

  # Soft check: count TODO markers that remain. Some legitimately stay (e.g.
  # ACM cert ARN when no domain is set), but a high count likely means the AI
  # only explored without editing.
  # NB: grep returns rc=1 on no-match. With `set -o pipefail`, that bubbles
  # up to the pipeline and (with `set -e`) kills the script BEFORE we mark
  # iac_generated=true. `|| true` neutralises grep's no-match exit code;
  # empty stdout still gives wc -l = 0.
  local todo_count
  todo_count="$( { grep -rn 'TODO(devops-ai)' "$iac_dir" 2>/dev/null || true; } | wc -l | tr -d ' ')"
  if [[ "${todo_count:-0}" -gt 0 ]]; then
    warn "$todo_count TODO(devops-ai) marker(s) remain in $iac_dir — review before deploy-infra"
    grep -rn 'TODO(devops-ai)' "$iac_dir" 2>/dev/null | sed 's|^|    |' >&2 || true
  fi

  state_set_bool "$repo" status.iac_generated true

  # Persist cache key — next run with identical inputs will skip the recipe
  # and reuse the existing iac/ tree. The hash includes overview.md,
  # state.yaml, recipe yaml, and the full skeleton tree (see
  # `_generate_iac_cache_key`), so any meaningful change invalidates cache
  # automatically. We only write AFTER the recipe success marker so a
  # failed/partial run won't poison future cache lookups.
  mkdir -p "$cache_dir"
  echo "$current_key" > "$cache_file"

  ok "IaC ready in $iac_dir"
  step_outro "generate-iac" \
    "Output:  $iac_dir  (Terragrunt units in environments/dev/, modules/ tree)" \
    "         (open the IAC group in UI artifacts to inspect)" \
    "Next:    ./devops-ai.sh plan-infra $repo"
}

cmd_aws_login() {
  command -v aws >/dev/null 2>&1 || die "aws CLI not installed (run framework/bootstrap.sh)"
  step "Configuring AWS SSO profile"
  aws configure sso
  ok "if successful, set AWS_PROFILE in your shell or pass --profile to subsequent commands"
}

# aws-bootstrap [<repo>]
# Creates the S3 bucket Terragrunt uses for remote state. Idempotent: if the
# bucket already exists, only ensures versioning + encryption + public-access
# block are on. If <repo> is given, the bucket name is read from that
# project's iac/inputs.yaml (state_bucket key). Otherwise defaults to
# `devops-ai-tfstate-<account>`.
cmd_aws_bootstrap() {
  local repo="${1:-}"
  require_aws_creds

  local account region bucket
  account="$(aws sts get-caller-identity --query Account --output text)"

  if [[ -n "$repo" ]]; then
    require_project "$repo"
    local vars_yaml="$(project_iac "$repo")/inputs.yaml"
    [[ -f "$vars_yaml" ]] || die "iac/inputs.yaml missing — run generate-iac first"
    bucket="$(yq eval '.state_bucket' "$vars_yaml")"
    region="$(yq eval '.region' "$vars_yaml")"
    [[ -n "$bucket" && "$bucket" != "null" ]] || die "state_bucket is empty in $vars_yaml"
    [[ -n "$region" && "$region" != "null" ]] || die "region is empty in $vars_yaml"
  else
    bucket="devops-ai-tfstate-${account}"
    region="${AWS_REGION:-us-east-1}"
  fi

  step "Bootstrapping tfstate bucket: $bucket  (account=$account region=$region)"

  if aws s3api head-bucket --bucket "$bucket" --region "$region" 2>/dev/null; then
    ok "bucket already exists"
  else
    step "creating bucket"
    if [[ "$region" == "us-east-1" ]]; then
      aws s3api create-bucket --bucket "$bucket" --region "$region" >/dev/null
    else
      aws s3api create-bucket --bucket "$bucket" --region "$region" \
        --create-bucket-configuration "LocationConstraint=$region" >/dev/null
    fi
    ok "bucket created"
  fi

  step "ensuring versioning + encryption + public-access-block"
  aws s3api put-bucket-versioning --bucket "$bucket" --region "$region" \
    --versioning-configuration Status=Enabled >/dev/null
  aws s3api put-bucket-encryption --bucket "$bucket" --region "$region" \
    --server-side-encryption-configuration \
      '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' >/dev/null
  aws s3api put-public-access-block --bucket "$bucket" --region "$region" \
    --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" >/dev/null

  ok "tfstate bucket ready: s3://$bucket  (region=$region)"
}

# az-login — interactive Azure login for the operator. Use the UI's Setup
# tab to write Service Principal credentials non-interactively; this
# command exists for ad-hoc CLI use.
cmd_az_login() {
  command -v az >/dev/null 2>&1 || die "az CLI not installed (run framework/bootstrap.sh)"
  step "Running az login"
  az login
  ok "if successful, run: az account set --subscription <id>"
}

# az-bootstrap [<repo>]
# Creates the Azure Storage account + blob container Terragrunt uses for
# remote state. Mirror of cmd_aws_bootstrap. Idempotent.
#
# Without <repo>: creates `devopsaitfstate<sub-prefix>` storage account
# under a fresh `devops-ai-tfstate-rg` resource group.
# With <repo>: reads state_storage_account and state_container from that
# project's iac/inputs.yaml.
cmd_az_bootstrap() {
  local repo="${1:-}"
  command -v az >/dev/null 2>&1 || die "az CLI not installed"
  command -v yq >/dev/null 2>&1 || die "yq required"
  local id_json; id_json="$(az account show -o json 2>/dev/null)" \
    || die "not logged in to Azure (run: az login, or set creds in the UI Setup tab)"

  local subscription_id storage_account container_name region rg
  subscription_id="$(jq -r .id <<< "$id_json")"

  if [[ -n "$repo" ]]; then
    require_project "$repo"
    local vars_yaml="$(project_iac "$repo")/inputs.yaml"
    [[ -f "$vars_yaml" ]] || die "iac/inputs.yaml missing — run generate-iac first"
    storage_account="$(yq eval '.state_storage_account' "$vars_yaml")"
    container_name="$(yq eval '.state_container'  "$vars_yaml")"
    region="$(yq eval '.region' "$vars_yaml")"
    [[ -n "$storage_account" && "$storage_account" != "null" ]] || die "state_storage_account empty in $vars_yaml"
    [[ -n "$container_name"  && "$container_name"  != "null" ]] || die "state_container empty in $vars_yaml"
    # If inputs.yaml has a subscription_id, prefer it — it's what every
    # downstream terragrunt unit will actually target.
    local sub_from_inputs
    sub_from_inputs="$(yq eval '.subscription_id' "$vars_yaml" 2>/dev/null || true)"
    if [[ -n "$sub_from_inputs" && "$sub_from_inputs" != "null" && "$sub_from_inputs" != "$subscription_id" ]]; then
      warn "active az subscription ($subscription_id) differs from inputs.yaml ($sub_from_inputs) — using inputs.yaml's value"
      subscription_id="$sub_from_inputs"
    fi
  else
    # Storage account names: 3-24 chars, lowercase alphanumeric only.
    storage_account="devopsaitfst$(echo "$subscription_id" | tr -d '-' | head -c 8)"
    container_name="tfstate"
    region="${AZURE_DEFAULTS_LOCATION:-eastus}"
  fi

  rg="${storage_account}-rg"
  step "Bootstrapping Azure tfstate: $storage_account/$container_name  (rg=$rg region=$region sub=${subscription_id:0:8}…)"

  # Sanity-check the subscription is reachable AND in a state that allows
  # writes. Free Trial / PastDue / Disabled subscriptions show up in
  # `az account list` but reject `az resource create` calls with cryptic
  # errors like "SubscriptionNotFound". Surface the real status here so the
  # operator sees the actionable cause.
  local sub_state
  sub_state="$(az account show --subscription "$subscription_id" --query state -o tsv 2>/dev/null || echo "")"
  if [[ -z "$sub_state" ]]; then
    die "subscription '$subscription_id' is not visible to the active principal. Possible causes:
  - tenant mismatch — your SP is in a different tenant than this subscription
  - the SP has no role on this subscription — assign it Owner via Portal → Subscription → Access control (IAM)
  - subscription is suspended / cancelled
  Diagnose: az account list --output table   |   az account list-locations --subscription $subscription_id"
  fi
  if [[ "$sub_state" != "Enabled" ]]; then
    die "subscription state is '$sub_state' (expected 'Enabled'). Common cases:
  - 'Warned' / 'PastDue' — billing issue, fix in Portal → Billing
  - 'Disabled' — Free Trial expired or admin disabled it
  - 'Deleted' — subscription was cancelled
  Resource creates will fail until this is resolved."
  fi
  ok "subscription state: Enabled"

  # Ensure required Resource Providers are registered. Brand-new subscriptions
  # (Free Trial in particular) ship with most providers UNregistered, and the
  # error message Azure returns ("SubscriptionNotFound") is misleading —
  # what's actually missing is the provider registration. Register the ones
  # the skeleton actually uses.
  local providers=(Microsoft.Storage Microsoft.Network Microsoft.App Microsoft.OperationalInsights Microsoft.DBforPostgreSQL Microsoft.ContainerRegistry Microsoft.KeyVault Microsoft.ManagedIdentity Microsoft.Cache)
  step "Ensuring resource providers are registered (one-time per subscription)"
  local p
  for p in "${providers[@]}"; do
    local pstate
    pstate="$(az provider show --subscription "$subscription_id" --namespace "$p" --query registrationState -o tsv 2>/dev/null || echo "")"
    if [[ "$pstate" == "Registered" ]]; then
      c_dim "  $p — already Registered"
    else
      step "  registering $p (state was: ${pstate:-unknown})"
      az provider register --subscription "$subscription_id" --namespace "$p" -o none 2>/dev/null \
        || warn "  failed to register $p — operator may need to do this manually"
    fi
  done

  # Resource group.
  if ! az group show --subscription "$subscription_id" --name "$rg" >/dev/null 2>&1; then
    step "creating resource group $rg"
    az group create --subscription "$subscription_id" --name "$rg" --location "$region" -o none
  else
    ok "resource group $rg already exists"
  fi

  # Storage account.
  if ! az storage account show --subscription "$subscription_id" --name "$storage_account" --resource-group "$rg" >/dev/null 2>&1; then
    step "creating storage account $storage_account"
    az storage account create \
      --subscription "$subscription_id" \
      --name "$storage_account" --resource-group "$rg" --location "$region" \
      --sku Standard_RAGRS --kind StorageV2 \
      --https-only true --min-tls-version TLS1_2 \
      --allow-blob-public-access false -o none
  else
    ok "storage account $storage_account already exists"
  fi

  # Blob container — auth-mode=login uses the active principal's RBAC.
  # Requires "Storage Blob Data Contributor" on the storage account.
  # Resolving the principal's object ID differs by session type:
  #   - user session       → `az ad signed-in-user show` works
  #   - service principal  → `signed-in-user` returns "/me only works for
  #                          users, not SPs"; we resolve the SP's appId →
  #                          its objectId via `az ad sp show --id <appId>`
  # Without this branch, terragrunt later fails plan/apply with HTTP 403
  # AuthorizationPermissionMismatch on the blob backend.
  step "ensuring 'Storage Blob Data Contributor' on $storage_account for the active principal"

  local user_type principal_oid sa_id
  user_type="$(az account show --query user.type -o tsv 2>/dev/null || echo "user")"
  if [[ "$user_type" == "servicePrincipal" ]]; then
    local app_id
    app_id="$(az account show --query user.name -o tsv 2>/dev/null || true)"
    if [[ -n "$app_id" ]]; then
      principal_oid="$(az ad sp show --id "$app_id" --query id -o tsv 2>/dev/null || true)"
    fi
    [[ -n "$principal_oid" ]] && c_dim "  principal: SP appId=$app_id objectId=$principal_oid"
  else
    principal_oid="$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)"
    [[ -n "$principal_oid" ]] && c_dim "  principal: user objectId=$principal_oid"
  fi

  sa_id="$(az storage account show --subscription "$subscription_id" --name "$storage_account" --query id -o tsv 2>/dev/null || true)"

  if [[ -z "$principal_oid" ]]; then
    warn "  could not resolve principal object id — skipping role assignment."
    warn "  If terragrunt later fails with HTTP 403 on the blob backend,"
    warn "  manually grant 'Storage Blob Data Contributor' to your principal on $storage_account."
  elif [[ -z "$sa_id" ]]; then
    warn "  could not resolve storage account id — skipping role assignment"
  else
    # `az role assignment create --assignee` accepts either appId or objectId,
    # but using the explicit objectId via --assignee-object-id is more reliable
    # for SPs (avoids the "ambiguous" lookup error when an appId collides
    # with an Entra user UPN).
    if az role assignment create \
        --subscription "$subscription_id" \
        --assignee-object-id "$principal_oid" \
        --assignee-principal-type "$([[ "$user_type" == "servicePrincipal" ]] && echo "ServicePrincipal" || echo "User")" \
        --role "Storage Blob Data Contributor" \
        --scope "$sa_id" -o none 2>/dev/null; then
      ok "  role assignment ensured"
    else
      # Most likely already exists. Verify by listing assignments at this scope.
      if az role assignment list \
           --subscription "$subscription_id" \
           --assignee "$principal_oid" \
           --scope "$sa_id" \
           --query "[?roleDefinitionName=='Storage Blob Data Contributor'] | length(@)" -o tsv 2>/dev/null \
         | grep -qE '^[1-9]'; then
        c_dim "  role already assigned"
      else
        warn "  role assignment failed AND no existing assignment found — terragrunt may hit 403 later"
        warn "  manual fix: az role assignment create --assignee-object-id $principal_oid \\"
        warn "                --assignee-principal-type $([[ "$user_type" == "servicePrincipal" ]] && echo "ServicePrincipal" || echo "User") \\"
        warn "                --role 'Storage Blob Data Contributor' --scope $sa_id"
      fi
    fi
  fi

  # Role-assignment propagation through Azure ARM is async — typically 30-60s
  # but can be longer. Wait briefly so terragrunt's first init doesn't race
  # the assignment.
  step "waiting 45s for role propagation"
  sleep 45

  step "ensuring blob container '$container_name'"
  az storage container create \
    --subscription "$subscription_id" \
    --name "$container_name" \
    --account-name "$storage_account" \
    --auth-mode login \
    --public-access off -o none || true

  ok "tfstate ready: az://$storage_account/$container_name  (rg=$rg sub=$subscription_id)"
}

_approval_phrase_for_env() {
  case "$1" in
    prod) echo "apply prod" ;;
    *)    echo "apply"      ;;
  esac
}

# Portable mtime in epoch seconds for a file. Returns 0 if the file is gone
# or stat fails on this platform.
# Parse a terragrunt/terraform error log for stale-state-lock blocks and
# emit "<unit_name>\t<lock_id>" pairs.
#
# Each lock error block in the log looks like:
#   ╷
#   │ Error: Error acquiring the state lock
#   │ ...
#   │ Lock Info:
#   │   ID:        <uuid>
#   │   Path:      <bucket>/<repo>/<env>/<unit>/terraform.tfstate
#   │   ...
#   ╵
#
# We extract the UNIT name from the path (second-to-last segment before
# terraform.tfstate) and the lock ID — paired by block. Used by cmd_destroy
# to auto-recover from leftover locks (killed apply, container restart, etc.).
#
# Takes the log path as $1 — NOT stdin — because `python3 - <<'PY'` already
# binds stdin to the heredoc script, so a `< file` redirect from the caller
# would be silently ignored and `sys.stdin.read()` would return empty.
_extract_lock_pairs() {
  local logfile="$1"
  [[ -s "$logfile" ]] || return 0
  python3 - "$logfile" <<'PY'
import re, sys
log = open(sys.argv[1], 'r', errors='replace').read()
# Lock blocks have ID and Path on consecutive-ish lines (not always adjacent;
# Path can come either above or below ID in different terragrunt versions).
# Match within a reasonable window so we don't pair across unrelated blocks.
pattern = re.compile(
    r'(?:Path:\s*\S*?/(?P<unit1>[A-Za-z0-9_-]+)/terraform\.tfstate.*?'
    r'ID:\s*(?P<id1>[a-f0-9]{8}-[a-f0-9-]+)'
    r'|'
    r'ID:\s*(?P<id2>[a-f0-9]{8}-[a-f0-9-]+).*?'
    r'Path:\s*\S*?/(?P<unit2>[A-Za-z0-9_-]+)/terraform\.tfstate)',
    re.DOTALL,
)
seen = set()
for m in pattern.finditer(log):
    unit = m.group('unit1') or m.group('unit2')
    lid  = m.group('id1')   or m.group('id2')
    if unit and lid and (unit, lid) not in seen:
        seen.add((unit, lid))
        print(f"{unit}\t{lid}")
PY
}

# Format an integer token count as 1.2K / 3.4M for compact display.
# Falls through to the raw value for non-numeric input or <1000. Awk's
# rounding is used so 999500 displays as "1.0M" instead of "999.5K", and
# the K→M boundary doesn't get a confusing "1000.0K" line.
_fmt_tokens() {
  local n="${1:-0}"
  [[ "$n" =~ ^[0-9]+$ ]] || { echo "$n"; return; }
  if (( n >= 999500 )); then
    awk -v n="$n" 'BEGIN { printf "%.1fM", n/1000000 }'
  elif (( n >= 1000 )); then
    awk -v n="$n" 'BEGIN { printf "%.1fK", n/1000 }'
  else
    echo "$n"
  fi
}

# Print token usage for the goose session captured in <logfile>. Best-effort:
# silently skips if sqlite3, the goose sessions DB, or the session ID line
# can't be found. Uses tail -1 on the session-ID grep so retried recipes
# show the LAST attempt's tokens, not the first one.
#
# We display only `total_tokens` — goose's `input_tokens`/`output_tokens`
# columns hold only the LAST request/response pair, not cumulative sums,
# so they're misleading on multi-turn sessions (a 2M-token recipe shows
# input=53 because the final user message was tiny).
#
# Args: <logfile>
_print_token_usage() {
  local logfile="$1"
  [[ -s "$logfile" ]] || return 0
  local db="$HOME/.local/share/goose/sessions/sessions.db"
  [[ -f "$db" ]] || return 0
  command -v sqlite3 >/dev/null 2>&1 || return 0

  # Goose stamps the session ID in stdout right after "new session":
  #     __( O)>  ● new session · claude-acp claude-opus-4-7
  #    \____)    20260507_2 · /workspace
  local session_id
  session_id="$(grep -oE '[0-9]{8}_[0-9]+' "$logfile" | tail -1)"
  [[ -n "$session_id" ]] || return 0

  local total
  total="$(sqlite3 "$db" \
    "SELECT total_tokens FROM sessions WHERE id = '$session_id';" \
    2>/dev/null)" || return 0
  [[ "$total" =~ ^[0-9]+$ ]] || return 0

  c_dim "    tokens: $(_fmt_tokens "$total") (session $session_id)"
}

# Scan a terragrunt log for state-lock errors, force-unlock each affected
# unit, and echo the count of successful unlocks to stdout. Cloud-agnostic:
# `terragrunt force-unlock` delegates to the configured backend (S3 lockfile
# for AWS, blob lease for Azure). Returns 0 always — caller decides whether
# to retry based on the count.
#
# Args: <logfile> <iac_dir> <env>
_recover_state_locks() {
  local logfile="$1" iac_dir="$2" env="$3"
  [[ -s "$logfile" ]] || { echo 0; return 0; }
  grep -q "Error acquiring the state lock" "$logfile" || { echo 0; return 0; }

  local unit lid swept=0
  while IFS=$'\t' read -r unit lid; do
    [[ -z "$unit" || -z "$lid" ]] && continue
    local unit_dir="$iac_dir/environments/$env/$unit"
    [[ -d "$unit_dir" ]] || { warn "  skip '$unit' — directory not found" >&2; continue; }
    warn "  force-unlock unit='$unit' id=$lid" >&2
    if (cd "$unit_dir" && terragrunt force-unlock "$lid" --non-interactive >/dev/null 2>&1); then
      ok "    unit '$unit' unlocked" >&2
      swept=$((swept + 1))
    else
      warn "    force-unlock returned non-zero (already free, or wrong id)" >&2
    fi
  done < <(_extract_lock_pairs "$logfile")

  echo "$swept"
}

# Compute a stable SHA256 of every input that affects generate-iac's output.
# If the hash matches the previously-recorded one, the AI step would produce
# identical IaC — so cmd_generate_iac can skip the recipe entirely (saving
# ~3-5M tokens on a re-run with unchanged source/inputs).
#
# Hashed inputs:
#   - 00_overview.md  — captures app contract (from `assess`)
#   - state.yaml      — captures env/cloud/region/extensions/source_path
#   - recipe yaml     — captures workflow definition
#   - skeleton tree   — captures templates, provider pins, module code
#
# inputs.yaml is INTENTIONALLY omitted: it's derived deterministically from
# state.yaml + skeleton's inputs.yaml.tmpl, both already in the hash.
#
# Cache hits are safe by construction: same hash = same inputs = same output.
# sha256 collisions are practically impossible (2^256 keyspace).
_generate_iac_cache_key() {
  local repo="$1"
  local skeleton="$2"
  local overview_path; overview_path="$(project_docs "$repo")/00_overview.md"
  local state_file;    state_file="$(project_dir "$repo")/state.yaml"
  local recipe_yaml="$FRAMEWORK_DIR/recipes/generate-iac.yaml"
  local skeleton_dir="$FRAMEWORK_DIR/templates/iac/$skeleton"

  {
    [[ -f "$overview_path" ]] && sha256sum "$overview_path"
    [[ -f "$state_file"    ]] && sha256sum "$state_file"
    [[ -f "$recipe_yaml"   ]] && sha256sum "$recipe_yaml"
    [[ -d "$skeleton_dir"  ]] && find "$skeleton_dir" -type f -print0 2>/dev/null \
        | sort -z | xargs -0 -r sha256sum 2>/dev/null
  } | sha256sum | awk '{print $1}'
}

_file_mtime_epoch() {
  # mtime as unix epoch. Try GNU stat first (Linux containers),
  # then BSD stat (macOS). The previous order was reversed which
  # backfired: on GNU coreutils `stat -f` is "display filesystem
  # status" — it succeeds (rc=0) but prints `  File: ...` text,
  # not a number. The captured text then poisoned arithmetic
  # comparisons under `set -u` ("File: unbound variable").
  local path="$1" m
  [[ -e "$path" ]] || { echo 0; return; }
  if m=$(stat -c %Y "$path" 2>/dev/null) && [[ "$m" =~ ^[0-9]+$ ]]; then
    echo "$m"; return
  fi
  if m=$(stat -f %m "$path" 2>/dev/null) && [[ "$m" =~ ^[0-9]+$ ]]; then
    echo "$m"; return
  fi
  echo 0
}

# Real human gate between plan and apply.
#
# Why two recipes plus a bash `read` between them, instead of one recipe with
# "stop and ask for approval": Goose runs recipes with GOOSE_MODE=auto and no
# stdin, so any model-side approval prompt is decorative — the model has no
# physical way to wait for a human. We split the work:
#   1) infra-plan recipe (read-only) writes a Markdown summary to disk,
#   2) bash prints that summary and calls `read -r` against the operator's
#      terminal — this is the actual gate,
#   3) infra-apply recipe runs only on receiving the right phrase.
# The shell controls the gate, not the model.
#
# These three phases are exposed as three commands:
#   plan-infra    only (1)            — produces plan_summary.md, no AWS mutation
#   apply-infra   (2) + (3)           — uses an existing plan_summary.md
#   deploy-infra  (1) + (2) + (3)     — the full pipeline
# The phase bodies live in two helpers below to keep them DRY.

# Phase: run the read-only plan recipe and verify it wrote the summary file.
_infra_phase_plan() {
  local repo="$1" iac_dir="$2" env="$3" region="$4" plan_summary_path="$5"
  local cloud; cloud="$(state_get "$repo" cloud 2>/dev/null || echo "aws")"
  rm -f "$plan_summary_path"
  run_recipe infra-plan "PLAN READY plan_summary=${plan_summary_path}" \
    "repo_name=$repo" \
    "iac_dir=$iac_dir" \
    "env=$env" \
    "region=$region" \
    "cloud=$cloud" \
    "plan_summary_path=$plan_summary_path"

  [[ -s "$plan_summary_path" ]] \
    || die "infra-plan: success marker matched but $plan_summary_path is empty"
}

# Phase: show the existing plan summary, ask the operator for the right phrase
# on a TTY, and only on success run the apply recipe + record outputs.
_infra_phase_gate_and_apply() {
  local repo="$1" iac_dir="$2" env="$3" region="$4"
  local plan_summary_path="$5" outputs_path="$6"

  [[ -s "$plan_summary_path" ]] \
    || die "no plan summary at $plan_summary_path. Run: ./devops-ai.sh plan-infra $repo"

  # Soft staleness check: warn if inputs.yaml has been touched after the plan
  # was produced. The contract is "operator approves THIS summary", so if the
  # configuration drifted since, the summary may not describe what apply will
  # actually do. We only warn — terragrunt apply does its own internal plan.
  local inputs_yaml="$iac_dir/inputs.yaml"
  if [[ -f "$inputs_yaml" ]]; then
    local plan_mtime inputs_mtime
    plan_mtime="$(_file_mtime_epoch "$plan_summary_path")"
    inputs_mtime="$(_file_mtime_epoch "$inputs_yaml")"
    if (( inputs_mtime > plan_mtime )); then
      warn "inputs.yaml was modified AFTER the plan was produced —"
      warn "  the summary you are about to approve may not match current config."
      warn "  Consider re-planning: ./devops-ai.sh plan-infra $repo"
    fi
  fi

  echo
  c_dim "  ─────────────── plan summary ───────────────"
  cat "$plan_summary_path"
  c_dim "  ────────────────────────────────────────────"
  echo

  local need_phrase; need_phrase="$(_approval_phrase_for_env "$env")"
  if [[ "$env" == "prod" ]]; then
    warn "PRODUCTION deployment — type the literal phrase '$need_phrase'"
    warn "Verify the AWS account id at the top of the summary matches your prod account"
  fi

  # Approval gate. Default is "must be a TTY" — this prevents unattended
  # applies from silent contexts (cron, hooks, agent loops) that would
  # otherwise silently provision real AWS resources.
  #
  # The UI is a legitimate non-TTY caller: the operator approves in a
  # browser modal showing the same plan summary, then the backend sets
  # DEVOPS_AI_UI_APPROVED=1 and pipes the approval phrase on stdin. Honor
  # that path, but require the env var explicitly so a missing modal is
  # surfaced rather than silently applied.
  if [[ ! -t 0 && "${DEVOPS_AI_UI_APPROVED:-}" != "1" ]]; then
    die "stdin is not a TTY and DEVOPS_AI_UI_APPROVED is not set — refusing to apply. Run from a terminal, or set DEVOPS_AI_UI_APPROVED=1 and pipe the approval phrase on stdin."
  fi
  local confirm=""
  read -r -p "Type '${need_phrase}' to proceed (anything else aborts): " confirm

  local confirm_lc
  confirm_lc="$(printf '%s' "$confirm" | tr '[:upper:]' '[:lower:]')"
  if [[ "$confirm_lc" != "$need_phrase" ]]; then
    die "approval not given (got '$confirm', expected '$need_phrase'); deploy aborted"
  fi
  ok "approval received — running apply"

  local cloud; cloud="$(state_get "$repo" cloud 2>/dev/null || echo "aws")"

  # Apply with one-shot force-unlock retry. A previous interrupted apply
  # (Ctrl-C, container crash, OOM, killed Goose Monitor) leaves a state
  # lock that blocks every subsequent apply until cleared. We scan the
  # recipe's failure log for "Error acquiring the state lock", pull the
  # lock-id + unit pairs, force-unlock, and retry once. Mirrors cmd_destroy.
  local apply_args=(
    "repo_name=$repo"
    "iac_dir=$iac_dir"
    "env=$env"
    "region=$region"
    "cloud=$cloud"
    "plan_summary_path=$plan_summary_path"
    "outputs_path=$outputs_path"
  )
  local apply_marker="INFRA DEPLOYED env=${env} region=${region}"

  set +e
  run_recipe infra-apply "$apply_marker" "${apply_args[@]}"
  local apply_rc=$?
  set -e

  if (( apply_rc != 0 )); then
    local swept=0
    if [[ -n "${LAST_RECIPE_LOG:-}" && -s "$LAST_RECIPE_LOG" ]]; then
      swept="$(_recover_state_locks "$LAST_RECIPE_LOG" "$iac_dir" "$env")"
    fi
    [[ -n "${LAST_RECIPE_LOG:-}" ]] && rm -f "$LAST_RECIPE_LOG"
    LAST_RECIPE_LOG=""

    if (( swept > 0 )); then
      step "Retrying apply-infra after $swept force-unlock(s)"
      run_recipe infra-apply "$apply_marker" "${apply_args[@]}" \
        || die "apply-infra still failing after $swept force-unlock(s) — see output above"
    else
      die "apply-infra failed (no recoverable state-lock issue) — see output above"
    fi
  fi

  # Re-merge outputs deterministically. The recipe used to instruct the LLM
  # to run `terragrunt run --all output -- -json > outputs.json`, but that
  # form concatenates per-unit JSON without wrapping — the resulting file
  # is `{...}{...}{...}`, valid line-by-line but invalid as a single
  # document (`jq empty` fails with "Extra data"). Downstream readers
  # (deploy-app, _print_access_summary) all expect ONE valid JSON object.
  # We rebuild it ourselves via merge_terragrunt_outputs (lib/outputs.sh)
  # which iterates units and `jq * $outs`-merges them. Idempotent — safe
  # to call even if the recipe already wrote a correct file.
  step "Merging unit outputs into $outputs_path"
  if ! merge_terragrunt_outputs "$iac_dir/environments/$env" "$outputs_path"; then
    die "infra-apply: merge_terragrunt_outputs failed — apply may have produced no outputs (was $iac_dir/environments/$env actually applied?)"
  fi

  [[ -s "$outputs_path" ]] \
    || die "infra-apply: success marker matched but $outputs_path is empty"
  state_set_bool "$repo" status.infra_deployed true
  ok "infra deployed; plan → $plan_summary_path"
  ok "                outputs → $outputs_path"
}

# Resolve the standard infra parameters for a project. Sets locals in the
# caller's scope: repo, region, env, iac_dir, plan_summary_path, outputs_path.
# Also runs preflight + state check + AWS-side default normalization.
_infra_resolve_params() {
  local repo="$1"
  preflight_deploy_infra "$repo"
  state_check "$repo" iac_generated

  # Catch retired AWS-side defaults (e.g. RDS minor engine versions) before
  # we waste a Goose session and a real terraform apply on something we know
  # will fail. Best-effort; no-op if AWS API is unreachable.
  _normalize_db_engine_version "$repo"

  region="$(state_get "$repo" region)"
  env="$(state_get "$repo" env)"
  iac_dir="$(project_iac "$repo")"
  local deploy_dir; deploy_dir="$(project_dep "$repo")"
  mkdir -p "$deploy_dir"
  plan_summary_path="$deploy_dir/plan_summary.md"
  outputs_path="$deploy_dir/outputs.json"
}

cmd_plan_infra() {
  local repo="${1:-}"; ensure_param "<repo>" "$repo"
  local region env iac_dir plan_summary_path outputs_path
  _infra_resolve_params "$repo"

  step_intro "plan-infra" \
    "5-10 minutes (cold cache: cold init for each unit)" \
    "Run 'terragrunt run --all plan' against AWS — read-only, no resources created. Writes a plan summary you can review."

  step "Plan only — terragrunt plan (read-only)"
  _infra_phase_plan "$repo" "$iac_dir" "$env" "$region" "$plan_summary_path"
  ok "plan summary → $plan_summary_path"
  step_outro "plan-infra" \
    "Output:  $plan_summary_path  (open and read it — this is what you'll approve at apply)" \
    "Next:    ./devops-ai.sh apply-infra $repo   (will ask you to type 'apply' to confirm)"
}

# assess — combined analyze + recommend in one Goose session.
# Designed for Opus 4.7's 1M context: it can hold the full repo and the
# skeleton catalogue at once, so we save the round-trip cost of running
# analyze and recommend separately. Writes both 00_overview.md and
# 02_infra_options.md in one shot, then flips analyzed+recommended.
cmd_assess() {
  local repo="${1:-}"; shift || true
  ensure_param "<repo>" "$repo"

  # Optional --cloud flag pins cloud BEFORE select for an Azure-aware
  # fit assessment. Otherwise read state.yaml or default to aws.
  local cloud_override=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cloud)   cloud_override="$2"; shift 2 ;;
      --cloud=*) cloud_override="${1#*=}"; shift ;;
      *) shift ;;
    esac
  done
  if [[ -n "$cloud_override" ]]; then
    state_set "$repo" cloud "$cloud_override"
  fi

  preflight_recommend "$repo"
  local source_path
  source_path="$(state_get "$repo" source_path)"
  local docs; docs="$(project_docs "$repo")"
  local overview_path="$docs/00_overview.md"
  local templates_dir="$FRAMEWORK_DIR/templates/iac"
  local state_yaml; state_yaml="$(project_dir "$repo")/state.yaml"

  local cloud skeleton
  IFS=$'\t' read -r cloud skeleton <<< "$(_resolve_cloud_skeleton "$repo")"

  # assess writes a SINGLE concise overview (00_overview.md) that includes
  # both the project description AND the deployment-fit / extensions block.
  # Earlier we wrote a separate 02_infra_options.md; that doubled the
  # operator's reading load with no extra information. The combined doc
  # is the single source of truth for "what is this app + what to deploy".
  run_recipe assess "WROTE ${overview_path}" \
    "repo_name=$repo" \
    "source_path=$source_path" \
    "templates_dir=$templates_dir" \
    "cloud=$cloud" \
    "skeleton_id=$skeleton" \
    "overview_path=$overview_path" \
    "state_yaml=$state_yaml"

  [[ -s "$overview_path" ]] || die "assess: overview not produced at $overview_path"
  state_set_bool "$repo" status.analyzed true
  state_set_bool "$repo" status.recommended true
  ok "overview → $overview_path"
  ok "next: ./devops-ai.sh select $repo --cloud $cloud --region <r> --env <e>"
}

# audit — drift / posture check against deployed AWS resources. Reads
# state.yaml + outputs.json + queries AWS via aws-api MCP, flags drift,
# unused resources, security drift, missing tags. Run periodically.
cmd_audit() {
  local repo="${1:-}"; ensure_param "<repo>" "$repo"
  preflight_audit "$repo"
  state_check "$repo" iac_generated
  local deploy_dir; deploy_dir="$(project_dep "$repo")"
  local outputs_path="$deploy_dir/outputs.json"
  local docs; docs="$(project_docs "$repo")"
  local out_path="$docs/02_audit.md"
  local state_yaml; state_yaml="$(project_dir "$repo")/state.yaml"
  local iac_dir; iac_dir="$(project_iac "$repo")"

  local cloud; cloud="$(state_get "$repo" cloud 2>/dev/null || echo "aws")"
  local audit_recipe; audit_recipe="$(_recipe_for_cloud audit "$cloud")"

  step_intro "audit" \
    "1-3 minutes" \
    "AI compares iac/ vs deployed ${cloud^^} state, flags drift, unused resources, security drift, missing tags."

  run_recipe "$audit_recipe" "WROTE ${out_path}" \
    "repo_name=$repo" \
    "iac_dir=$iac_dir" \
    "outputs_path=$outputs_path" \
    "output_path=$out_path" \
    "state_yaml=$state_yaml"

  [[ -s "$out_path" ]] || die "audit: $out_path empty"
  ok "audit → $out_path"
  step_outro "audit" \
    "Output:  $out_path  (drift report — fix any flagged item or document why it's accepted)" \
    "Re-run periodically (weekly/monthly) to catch console-side changes."
}

# Print a human-readable access summary from outputs.json — ALB DNS,
# RDS endpoint, ECS cluster/service, Keycloak path, ECR repo. Best-effort
# (silent if outputs.json is missing or jq is not available).
_print_access_summary() {
  local repo="$1" stage="${2:-infra}"
  local outputs_path; outputs_path="$(project_dep "$repo")/outputs.json"
  [[ -s "$outputs_path" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  local region env
  region="$(state_get "$repo" region 2>/dev/null || echo "")"
  env="$(state_get "$repo" env 2>/dev/null || echo "")"

  local alb rds cluster service ecr kc_path
  alb="$(jq -r '.dns_name.value // empty' "$outputs_path" 2>/dev/null)"
  rds="$(jq -r '.db_instance_endpoint.value // empty' "$outputs_path" 2>/dev/null)"
  cluster="$(jq -r '.cluster_name.value // empty' "$outputs_path" 2>/dev/null)"
  service="$(jq -r '.service_name.value // empty' "$outputs_path" 2>/dev/null)"
  ecr="$(jq -r '.repository_url.value // empty' "$outputs_path" 2>/dev/null)"
  kc_path="$(jq -r '.url_path.value // empty' "$outputs_path" 2>/dev/null)"

  echo
  c_blue "═══ Access summary — $repo / $env / $region ═══"
  if [[ -n "$alb" ]]; then
    echo "  Application URL:       http://$alb/"
    echo "  Health check:          http://$alb/api/v1/health"
    [[ -n "$kc_path" && "$kc_path" != "null" ]] \
      && echo "  Keycloak admin:        http://$alb${kc_path}/"
  fi
  [[ -n "$rds"     ]] && echo "  RDS endpoint:          $rds"
  [[ -n "$cluster" ]] && echo "  ECS cluster:           $cluster"
  [[ -n "$service" ]] && echo "  ECS service:           $service"
  [[ -n "$ecr"     ]] && echo "  ECR repository:        $ecr"
  echo
  if [[ "$stage" == "infra" ]]; then
    c_yellow "  Infra is up but the app image hasn't been deployed yet."
    c_yellow "  Next: ./devops-ai.sh deploy-app $repo"
  elif [[ "$stage" == "app" ]]; then
    c_green "  App deployed. Smoke test:  curl -i http://$alb/api/v1/health"
  fi
  echo
}

cmd_apply_infra() {
  local repo="${1:-}"; ensure_param "<repo>" "$repo"
  local region env iac_dir plan_summary_path outputs_path
  _infra_resolve_params "$repo"

  step_intro "apply-infra" \
    "10-20 minutes (RDS dominates: ~6 min)" \
    "Approve the existing plan summary, then create real AWS resources (VPC, ALB, RDS, ECS, ECR, IAM, secrets). \$ accrues from now."

  step "Apply only — using existing plan summary"
  _infra_phase_gate_and_apply "$repo" "$iac_dir" "$env" "$region" \
    "$plan_summary_path" "$outputs_path"
  _print_access_summary "$repo" infra
  step_outro "apply-infra" \
    "Output:  $outputs_path  (terragrunt outputs, merged into one JSON)" \
    "Status:  AWS resources provisioned. ECS task is failing (no image yet) — that's expected." \
    "Next:    ./devops-ai.sh deploy-app $repo   (build, push, populate secrets, smoke test)"
}

cmd_deploy_infra() {
  local repo="${1:-}"; ensure_param "<repo>" "$repo"
  local region env iac_dir plan_summary_path outputs_path
  _infra_resolve_params "$repo"

  step "Phase 1/2 — terragrunt plan (read-only)"
  _infra_phase_plan "$repo" "$iac_dir" "$env" "$region" "$plan_summary_path"
  step "Phase 2/2 — human approval + apply"
  _infra_phase_gate_and_apply "$repo" "$iac_dir" "$env" "$region" \
    "$plan_summary_path" "$outputs_path"
  _print_access_summary "$repo" infra
}

cmd_deploy_app() {
  local repo="${1:-}"; shift || true
  ensure_param "<repo>" "$repo"
  local git_ref="${1:-}"

  preflight_deploy_app "$repo"
  state_check "$repo" infra_deployed

  step_intro "deploy-app" \
    "15-45 minutes (image build dominates; cross-arch qemu on Apple Silicon adds time)" \
    "Source-aware preflight → pre-fix obvious mismatches → docker build/push → ECS update → smoke test → up to 8 self-heal attempts (3/category)."

  local region env source_path outputs_path history_path iac_dir attempts_path failure_report_path
  region="$(state_get "$repo" region)"
  env="$(state_get "$repo" env)"
  source_path="$(state_get "$repo" source_path)"
  outputs_path="$(project_dep "$repo")/outputs.json"
  history_path="$(project_dep "$repo")/history.jsonl"
  iac_dir="$(project_iac "$repo")"
  attempts_path="$(project_docs "$repo")/deploy_attempts.md"
  failure_report_path="$(project_docs "$repo")/deploy_failure_report.md"

  local cloud; cloud="$(state_get "$repo" cloud 2>/dev/null || echo "aws")"
  local da_recipe; da_recipe="$(_recipe_for_cloud deploy-app "$cloud")"

  # Success marker matches either single-service (`APP DEPLOYED image=`) or
  # multi-service (`APP DEPLOYED backend=`) form. The self-healing loop in
  # the recipe prompt also accepts `APP DEPLOY FAILED ...` as a terminal
  # state, but that yields a non-zero exit at the script level.
  run_recipe "$da_recipe" 'APP DEPLOYED (image|backend)=' \
    "repo_name=$repo" \
    "source_path=$source_path" \
    "region=$region" \
    "env=$env" \
    "outputs_path=$outputs_path" \
    "history_path=$history_path" \
    "iac_dir=$iac_dir" \
    "attempts_path=$attempts_path" \
    "failure_report_path=$failure_report_path" \
    "git_ref=$git_ref"

  state_set_bool "$repo" status.app_deployed true
  ok "deploy-app finished; check $history_path for the record"
  _print_access_summary "$repo" app
  step_outro "deploy-app" \
    "Outputs:" \
    "  - $attempts_path  (every pre-fix and self-heal attempt with reasoning)" \
    "  - $history_path  (one line per deploy: git sha, image, attempts, result)" \
    "Open the Application URL above in your browser to use the app." \
    "When done, free AWS resources:  ./devops-ai.sh destroy $repo"
}

cmd_upgrade() {
  local repo="${1:-}"; shift || true
  ensure_param "<repo>" "$repo"
  local git_ref="${1:-}"; ensure_param "<git_ref>" "$git_ref"

  preflight_deploy_app "$repo"
  state_check "$repo" app_deployed

  local region env source_path outputs_path history_path
  region="$(state_get "$repo" region)"
  env="$(state_get "$repo" env)"
  source_path="$(state_get "$repo" source_path)"
  outputs_path="$(project_dep "$repo")/outputs.json"
  history_path="$(project_dep "$repo")/history.jsonl"

  local cloud; cloud="$(state_get "$repo" cloud 2>/dev/null || echo "aws")"
  local up_recipe; up_recipe="$(_recipe_for_cloud upgrade "$cloud")"

  run_recipe "$up_recipe" "UPGRADED ${env} -> " \
    "repo_name=$repo" \
    "source_path=$source_path" \
    "git_ref=$git_ref" \
    "region=$region" \
    "env=$env" \
    "outputs_path=$outputs_path" \
    "history_path=$history_path"

  ok "upgrade finished; see $history_path"
}

cmd_rollback() {
  local repo="${1:-}"; ensure_param "<repo>" "$repo"
  preflight_rollback "$repo"
  state_check "$repo" app_deployed

  local prev
  prev="$(state_last_success "$repo")"
  [[ -n "$prev" ]] || die "no prior successful deploy in history; nothing to roll back to"

  local previous_image
  previous_image="$(echo "$prev" | jq -r '.image // empty')"
  [[ -n "$previous_image" ]] || die "previous deploy record is missing 'image' field"

  local region env outputs_path history_path
  region="$(state_get "$repo" region)"
  env="$(state_get "$repo" env)"
  outputs_path="$(project_dep "$repo")/outputs.json"
  history_path="$(project_dep "$repo")/history.jsonl"

  local cloud; cloud="$(state_get "$repo" cloud 2>/dev/null || echo "aws")"
  local rb_recipe; rb_recipe="$(_recipe_for_cloud rollback "$cloud")"

  run_recipe "$rb_recipe" "ROLLED BACK ${env} -> ${previous_image}" \
    "repo_name=$repo" \
    "region=$region" \
    "env=$env" \
    "outputs_path=$outputs_path" \
    "history_path=$history_path" \
    "previous_image=$previous_image"

  ok "rollback finished; image=$previous_image"
}

cmd_status() {
  local repo="${1:-}"
  if [[ -z "$repo" ]]; then
    step "Initialized projects:"
    local n=0
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      n=$((n+1))
      echo "  - $p"
    done < <(state_list)
    [[ "$n" -eq 0 ]] && c_dim "  (none — run: ./devops-ai.sh init <path>)"
    return
  fi
  state_summary "$repo"
}

cmd_list() {
  state_list
}

cmd_catalog() {
  step "IaC skeleton catalog: $FRAMEWORK_DIR/templates/iac/"
  for d in "$FRAMEWORK_DIR/templates/iac"/*/; do
    local name; name="$(basename "$d")"
    echo
    c_blue "  $name"
    if [[ -f "$d/README.md" ]]; then
      # Print just the first few non-empty lines of README for a quick blurb.
      awk 'NF && /^>/ { sub(/^> ?/,""); print "    " $0; exit } NF && !/^#/ { print "    " $0; exit }' "$d/README.md"
    fi
  done
}

# Pre-destroy: empty every ECR repository tagged for this project before
# terragrunt destroy runs. The ecr.hcl skeleton sets
# repository_force_delete=false on purpose (so we never accidentally drop
# a populated registry from `apply`), but on destroy that means the
# `aws_ecr_repository` resource refuses to delete while images remain.
# We resolve repos by AWS tags (project=<repo>, env=<env>) — set by the
# root.hcl default_tags — so we never touch unrelated registries.
_purge_ecr_images() {
  local repo="$1" env="$2" region="$3"

  command -v aws >/dev/null 2>&1 || { warn "aws CLI not on PATH; skipping ECR purge"; return 0; }
  command -v jq  >/dev/null 2>&1 || { warn "jq not on PATH; skipping ECR purge";  return 0; }

  step "Pre-destroy: purging ECR images so terraform can drop the repos"

  local repos_json
  repos_json="$(aws ecr describe-repositories --region "$region" \
    --query 'repositories[].[repositoryArn,repositoryName]' --output json 2>/dev/null || echo '[]')"

  local found=0 purged_total=0
  while IFS=$'\t' read -r arn rname; do
    [[ -z "$arn" ]] && continue
    local tags_json
    tags_json="$(aws ecr list-tags-for-resource --resource-arn "$arn" --region "$region" \
      --query 'tags' --output json 2>/dev/null || echo '[]')"
    local mp me
    mp="$(jq -r --arg p "$repo" '.[]|select(.Key=="project" and .Value==$p)|.Key' <<< "$tags_json")"
    me="$(jq -r --arg e "$env"  '.[]|select(.Key=="env"     and .Value==$e)|.Key' <<< "$tags_json")"
    [[ -n "$mp" && -n "$me" ]] || continue
    found=$((found + 1))

    # Pages of up to 100 imageIds per batch-delete call.
    local next="" page_count=0
    while :; do
      local list_args=(ecr list-images --repository-name "$rname" --region "$region" --max-results 100 --output json)
      [[ -n "$next" ]] && list_args+=(--starting-token "$next")
      local list_json
      list_json="$(aws "${list_args[@]}" 2>/dev/null || echo '{"imageIds":[]}')"
      local ids
      ids="$(jq -c '.imageIds // []' <<< "$list_json")"
      local n; n="$(jq 'length' <<< "$ids")"
      if (( n > 0 )); then
        if aws ecr batch-delete-image --repository-name "$rname" --region "$region" \
            --image-ids "$ids" --output json >/dev/null 2>&1; then
          c_dim "  $rname — deleted $n image(s)"
        else
          warn "  $rname — batch-delete returned non-zero (some may have been deleted)"
        fi
        purged_total=$((purged_total + n))
        page_count=$((page_count + 1))
      fi
      next="$(jq -r '.nextToken // empty' <<< "$list_json")"
      [[ -z "$next" ]] && break
    done

    (( page_count == 0 )) && c_dim "  $rname — already empty"
  done < <(jq -r '.[] | "\(.[0])\t\(.[1])"' <<< "$repos_json")

  if (( found == 0 )); then
    ok "  no ECR repos tagged project=$repo env=$env — nothing to purge"
  else
    ok "  pre-destroy ECR purge complete — $purged_total image(s) across $found repo(s)"
  fi
}

# Azure analog: empty every ACR tagged for this project before terragrunt
# destroys it. Mirror of _purge_ecr_images — uses Azure tags (project, env)
# from root.hcl default_tags. Repositories named like "<project>-<env>" or
# "<project>-<env>-fe" live inside the registry; we delete all repositories
# inside any ACR matched by the tag filter.
_purge_acr_repositories() {
  local repo="$1" env="$2" region="$3"

  command -v az >/dev/null 2>&1 || { warn "az CLI not on PATH; skipping ACR purge"; return 0; }
  command -v jq >/dev/null 2>&1 || { warn "jq not on PATH; skipping ACR purge";  return 0; }

  step "Pre-destroy: purging ACR repositories so terraform can drop the registries"

  local registries_json
  registries_json="$(az acr list --query "[?tags.project=='${repo}' && tags.environment=='${env}'].{name:name, rg:resourceGroup}" -o json 2>/dev/null || echo '[]')"

  local found=0 purged_total=0
  local rname rg
  while IFS=$'\t' read -r rname rg; do
    [[ -z "$rname" ]] && continue
    found=$((found + 1))

    local repo_names
    repo_names="$(az acr repository list --name "$rname" -o tsv 2>/dev/null || true)"
    if [[ -z "$repo_names" ]]; then
      c_dim "  $rname — already empty"
      continue
    fi
    local rep
    while IFS= read -r rep; do
      [[ -z "$rep" ]] && continue
      if az acr repository delete --name "$rname" --repository "$rep" --yes -o none 2>/dev/null; then
        c_dim "  $rname — deleted repository '$rep'"
      else
        warn "  $rname — failed to delete repository '$rep' (will let terraform try)"
      fi
      purged_total=$((purged_total + 1))
    done <<< "$repo_names"
  done < <(jq -r '.[] | "\(.name)\t\(.rg)"' <<< "$registries_json")

  if (( found == 0 )); then
    ok "  no ACRs tagged project=$repo environment=$env — nothing to purge"
  else
    ok "  pre-destroy ACR purge complete — $purged_total repository(ies) across $found registry(ies)"
  fi
}

cmd_destroy() {
  local repo="${1:-}"; ensure_param "<repo>" "$repo"
  require_project "$repo"
  local env; env="$(state_get "$repo" env)"
  [[ "$env" == "dev" ]] || die "destroy is only allowed for env=dev (current: $env). For other envs, run terragrunt destroy manually."

  local region; region="$(state_get "$repo" region 2>/dev/null || true)"
  local cloud;  cloud="$(state_get "$repo" cloud 2>/dev/null || echo "aws")"
  local iac_dir; iac_dir="$(project_iac "$repo")"

  step_intro "destroy" \
    "5-15 minutes (RDS / Postgres deletion is the slow part)" \
    "Tears down ALL ${cloud^^} resources for $repo / env=$env. Stops the billing meter."

  warn "This will run 'terragrunt run --all destroy' on $iac_dir/environments/$env"
  read -r -p "Type the project name '$repo' to confirm: " confirm
  [[ "$confirm" == "$repo" ]] || die "confirmation mismatch — aborted"

  # Empty container registry before terragrunt destroy so the registry
  # resource can be dropped. ECR uses tag-filtered listing; ACR likewise.
  if [[ -n "$region" ]]; then
    case "$cloud" in
      aws)   _purge_ecr_images       "$repo" "$env" "$region" ;;
      azure) _purge_acr_repositories "$repo" "$env" "$region" ;;
      *)     warn "unknown cloud '$cloud' — skipping registry pre-purge" ;;
    esac
  else
    warn "no region in state.yaml — skipping registry pre-purge"
  fi

  # First attempt — captured to a temp log so we can inspect for lock errors.
  # We also pipe to stdout so the operator sees progress in real time.
  local destroy_log; destroy_log="$(mktemp -t devops-ai-destroy.XXXXXX)"
  local rc=0
  set +e
  (cd "$iac_dir/environments/$env" && \
    TG_PARALLELISM=1 terragrunt run --all destroy --non-interactive 2>&1) \
    | tee "$destroy_log"
  rc="${PIPESTATUS[0]}"
  set -e

  # Auto-recover from stale state locks. terragrunt 1.x with `use_lockfile=true`
  # uses S3 conditional writes for locking, so a killed apply leaves the state
  # version-bound to a lock-id and S3 returns 412 PreconditionFailed forever
  # until force-unlock. This pattern triggers when an earlier session was
  # interrupted (Ctrl-C, container restart, OOM, killed Goose Monitor).
  if (( rc != 0 )) && grep -q "Error acquiring the state lock" "$destroy_log"; then
    warn "stale state locks detected in destroy output — auto-recovering"

    local pair unit lid swept=0
    while IFS=$'\t' read -r unit lid; do
      [[ -z "$unit" || -z "$lid" ]] && continue
      local unit_dir="$iac_dir/environments/$env/$unit"
      [[ -d "$unit_dir" ]] || { warn "  skip '$unit' — directory not found"; continue; }
      warn "  force-unlock unit='$unit' id=$lid"
      if (cd "$unit_dir" && terragrunt force-unlock "$lid" --non-interactive >/dev/null 2>&1); then
        ok "    unit '$unit' unlocked"
        swept=$((swept + 1))
      else
        warn "    force-unlock returned non-zero (already free, or wrong id)"
      fi
    done < <(_extract_lock_pairs "$destroy_log")

    rm -f "$destroy_log"

    if (( swept == 0 )); then
      die "destroy hit lock errors but auto-recovery couldn't extract any IDs — see output above"
    fi

    step "Retrying destroy after $swept force-unlock(s)"
    (cd "$iac_dir/environments/$env" && \
      TG_PARALLELISM=1 terragrunt run --all destroy --non-interactive)
  elif (( rc != 0 )); then
    rm -f "$destroy_log"
    die "destroy failed (not a state-lock issue) — see output above"
  else
    rm -f "$destroy_log"
  fi

  state_set_bool "$repo" status.infra_deployed false
  state_set_bool "$repo" status.app_deployed false
  ok "destroyed env=$env for $repo"
  step_outro "destroy" \
    "All Terragrunt-managed AWS resources for $repo / $env have been deleted." \
    "Possible leftovers (NOT in Terragrunt state, check manually):" \
    "  - Secrets created by deploy-app self-heal:  aws secretsmanager list-secrets --filters Key=name,Values=$repo/" \
    "  - CloudWatch log groups:                    aws logs describe-log-groups --log-group-name-prefix /aws/ecs/$repo" \
    "  - ECR images (if force-delete didn't run):  aws ecr describe-repositories --repository-names $repo-dev"
}

# ---- entrypoint -------------------------------------------------------------

main() {
  local cmd="${1:-}"; [[ $# -gt 0 ]] && shift || true

  case "$cmd" in
    ""|menu)               cmd_menu ;;
    -h|--help|help)        cmd_help ;;
    init)                  cmd_init "$@" ;;
    analyze)               cmd_analyze "$@" ;;
    recommend)             cmd_recommend "$@" ;;
    assess)                cmd_assess "$@" ;;
    select)                cmd_select "$@" ;;
    generate-iac)          cmd_generate_iac "$@" ;;
    audit)                 cmd_audit "$@" ;;
    aws-login)             cmd_aws_login "$@" ;;
    aws-bootstrap)         cmd_aws_bootstrap "$@" ;;
    az-login)              cmd_az_login "$@" ;;
    az-bootstrap)          cmd_az_bootstrap "$@" ;;
    plan-infra)            cmd_plan_infra "$@" ;;
    apply-infra)           cmd_apply_infra "$@" ;;
    deploy-infra)          cmd_deploy_infra "$@" ;;
    deploy-app)            cmd_deploy_app "$@" ;;
    upgrade)               cmd_upgrade "$@" ;;
    rollback)              cmd_rollback "$@" ;;
    destroy)               cmd_destroy "$@" ;;
    status)                cmd_status "$@" ;;
    list)                  cmd_list "$@" ;;
    catalog)               cmd_catalog "$@" ;;
    *) die "unknown command: $cmd  (try '--help')" ;;
  esac
}

main "$@"
