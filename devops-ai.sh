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

c_red()    { printf '\033[31m%s\033[0m\n' "$*"; }
c_green()  { printf '\033[32m%s\033[0m\n' "$*"; }
c_yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
c_blue()   { printf '\033[34m%s\033[0m\n' "$*"; }
c_dim()    { printf '\033[90m%s\033[0m\n' "$*"; }

step()  { c_blue "==> $*"; }
ok()    { c_green "  ✓ $*"; }
warn()  { c_yellow "  ! $*"; }
die()   { c_red "  ✗ $*" >&2; exit 1; }

# ---- helpers ----------------------------------------------------------------

project_dir()   { printf '%s/projects/%s' "$DEVOPS_AI_ROOT" "$1"; }
project_docs()  { printf '%s/docs' "$(project_dir "$1")"; }
project_iac()   { printf '%s/iac' "$(project_dir "$1")"; }
project_dep()   { printf '%s/deploy' "$(project_dir "$1")"; }

ensure_param() {
  local name="$1" value="${2:-}"
  [[ -n "$value" ]] || die "missing required argument: $name"
}

# Per-recipe MCP-extension plan. The framework automatically enables/disables
# `aws-api` (talks to AWS) and `terraform` (HashiCorp registry lookups) in
# the user's ~/.config/goose/config.yaml before each recipe so that:
#   - read-only steps (analyze, recommend) run with the smallest possible
#     tool surface — fewer tool definitions in the system prompt = less risk
#     of overwhelming the local model.
#   - generate-iac gets `terraform` MCP for grounded module lookups.
#   - infra-plan / infra-apply get `aws-api` MCP for AWS calls plus `terraform`
#     for plan reasoning.
#   - deploy-app / upgrade / rollback get `aws-api` only.
#
# Format: space-separated "name:true" / "name:false" pairs.
_recipe_mcp_plan() {
  case "$1" in
    # analyze/recommend now run with aws-api ON so Opus 4.7 can ground its
    # suggestions in the user's actual AWS account state (existing VPC, IAM,
    # quotas, prior deploys). terraform MCP gives access to live registry
    # docs for accurate provider versioning.
    analyze|recommend|assess)      echo "aws-api:true  terraform:true"  ;;
    review-iac)                    echo "aws-api:true  terraform:true"  ;;
    audit)                         echo "aws-api:true  terraform:true"  ;;
    explain-plan)                  echo "aws-api:true  terraform:false" ;;
    generate-iac)                  echo "aws-api:false terraform:true"  ;;
    infra-plan|infra-apply)        echo "aws-api:true  terraform:true"  ;;
    deploy-app|upgrade|rollback)   echo "aws-api:true  terraform:false" ;;
    *)                             echo ""                              ;;
  esac
}

# Cross-check db_engine_version in <repo>'s iac/inputs.yaml against AWS RDS's
# currently-offered versions in the configured region. AWS retires minor
# engine versions over time, so a value that was valid when generate-iac ran
# can be rejected at apply time (we hit this with postgres 16.1 in early 2026).
# If we find the configured version is no longer offered, we rewrite
# inputs.yaml to the latest minor of the same major and warn the operator.
#
# Best-effort:
#   - silent if inputs.yaml or db_engine_version is missing (other skeletons)
#   - silent if AWS rds API does not answer (network / IAM); terragrunt apply
#     will catch any real incompatibility definitively
#   - never blocks deploy on its own
#
# Currently hardcodes engine=postgres because that is the only RDS engine the
# bundled skeleton uses. Extend the engine detection if you add mysql/etc skeletons.
_normalize_db_engine_version() {
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

  local available
  available="$(aws rds describe-db-engine-versions \
        --engine "$engine" \
        --region "$region" \
        --query "DBEngineVersions[?starts_with(EngineVersion, '${major}.')].EngineVersion" \
        --output text 2>/dev/null \
        | tr '\t' '\n' | sort -V | uniq)"

  if [[ -z "$available" ]]; then
    warn "could not query AWS RDS engine versions (network / IAM?). Continuing with '$current' — terragrunt apply will catch any incompatibility."
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

  # Default attempts=1 since we run on Claude Opus 4.7 which gets it right
  # the first time; retries only mask real environment problems (Gatekeeper,
  # missing AWS resources, wrong creds). Override with RECIPE_MAX_ATTEMPTS=N
  # for debugging.
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
      goose run --recipe "$recipe_path" "${args[@]}" 2>&1 | tee -a "$logfile"
    rc="${PIPESTATUS[0]}"
    set -e

    if grep -qE "$success_re" "$logfile"; then
      ok "recipe '$recipe' completed (success marker matched)"
      rm -f "$logfile"
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
  return 1
}

# ---- subcommands ------------------------------------------------------------

cmd_help() {
  cat <<EOF
DevOps AI Framework — CLI

Usage: devops-ai.sh <command> [args...]

Workflow commands:
  init <repo-path>             Register a project. Creates projects/<name>/.
  analyze <repo>               Read source → docs/01_overview.md (English).
  recommend <repo>             Pick 2–3 IaC skeletons → docs/02_infra_options.md.
  assess <repo>                analyze + recommend in one Opus 4.7 session
                               (faster, lower token cost on 1M-context models).
  select <repo> <opts>         Lock a choice (skeleton, region, env, optional extensions).
                               Required: --skeleton, --region, --env
                               Optional: --account-id, --include <csv>
                               --include accepts a comma list of opt-in extensions
                                         (ecs-fargate-rds: keycloak, alb-https).
  generate-iac <repo>          Render skeleton + AI completes TODO markers.
  review-iac <repo>            Self-review of generated IaC (security/cost/policy)
                               → docs/03_review.md. Run BEFORE plan-infra.
  aws-login                    Helper around 'aws configure sso'.
  aws-bootstrap [<repo>]       Create the S3 tfstate bucket. Without args:
                               creates 'devops-ai-tfstate-<account>'. With
                               <repo>: reads bucket name from its inputs.yaml.
  plan-infra <repo>            terragrunt run --all plan only. Writes a
                               human-reviewable plan_summary.md. No AWS mutation.
  explain-plan <repo>          Risk/cost/blast-radius narrative on top of
                               plan_summary.md → docs/06_plan_review.md.
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
                               → docs/07_audit.md. Run periodically.

Each step gates on prior state. The command flow is roughly:
  init → analyze → recommend → select → generate-iac → review-iac
       → plan-infra → explain-plan → apply-infra → deploy-app
                                                  → upgrade / rollback / audit
  Or shortcut: init → assess → select → generate-iac → ...
EOF
}

cmd_menu() {
  cat <<EOF
=== DevOps AI Framework ===
  Workspace: $DEVOPS_AI_ROOT

What do you want to do?
  1) init <repo-path>     — register a new project
  2) analyze <repo>       — read repo, write overview
  3) recommend <repo>     — get 2-3 infra options
  4) select <repo> ...    — lock skeleton + region + env
  5) generate-iac <repo>  — render Terragrunt + finish TODOs via AI
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
  local source_path="" name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)   name="$2"; shift 2 ;;
      --name=*) name="${1#*=}"; shift ;;
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

  step "Initializing project '$name' from $source_path"
  state_init "$name" "$source_path"
  ok "project registered at $(project_dir "$name")"
  ok "next: ./devops-ai.sh analyze $name"
}

cmd_analyze() {
  local repo="${1:-}"; ensure_param "<repo>" "$repo"
  preflight_analyze "$repo"
  local out_path="$(project_docs "$repo")/01_overview.md"
  local source_path
  source_path="$(state_get "$repo" source_path)"

  run_recipe analyze "WROTE ${out_path}" \
    "repo_name=$repo" \
    "source_path=$source_path" \
    "output_path=$out_path"

  [[ -s "$out_path" ]] || die "analyze: success marker matched but $out_path is empty"
  state_set_bool "$repo" status.analyzed true
  ok "overview written → $out_path"
}

cmd_recommend() {
  local repo="${1:-}"; ensure_param "<repo>" "$repo"
  preflight_recommend "$repo"
  state_check "$repo" analyzed
  local overview_path="$(project_docs "$repo")/01_overview.md"
  local out_path="$(project_docs "$repo")/02_infra_options.md"
  local templates_dir="$FRAMEWORK_DIR/templates/iac"

  run_recipe recommend "WROTE ${out_path}" \
    "repo_name=$repo" \
    "overview_path=$overview_path" \
    "templates_dir=$templates_dir" \
    "output_path=$out_path"

  [[ -s "$out_path" ]] || die "recommend: success marker matched but $out_path is empty"
  state_set_bool "$repo" status.recommended true
  ok "options written → $out_path"
}

cmd_select() {
  local repo="${1:-}"; shift || true
  ensure_param "<repo>" "$repo"

  local skeleton="" region="" env="" account_id="" include_csv=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
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

  ensure_param "--skeleton" "$skeleton"
  ensure_param "--region" "$region"
  ensure_param "--env" "$env"
  require_aws_region "$region"
  case "$env" in dev|stage|prod) ;; *) die "--env must be one of dev|stage|prod (got '$env')" ;; esac
  [[ -d "$FRAMEWORK_DIR/templates/iac/$skeleton" ]] \
    || die "skeleton '$skeleton' not found in $FRAMEWORK_DIR/templates/iac/"

  # Validate --include values against the skeleton's known optional units.
  # Each skeleton can advertise its own catalogue of opt-in extensions; for now
  # we hardcode the ecs-fargate-rds set. Adding new ones means: add a leaf with
  # `skip = !try(local.inputs_yaml.include_X == "true", false)` and accept the
  # name here.
  local known_extensions=(keycloak alb-https)
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

  # Render the operator runbook for this project from docs-templates/.
  local source_path; source_path="$(state_get "$repo" source_path)"
  local rb_vars; rb_vars="$(mktemp)"
  cat > "$rb_vars" <<EOF
repo_name: $repo
skeleton: $skeleton
region: $region
env: $env
source_path: $source_path
EOF
  render_file "$FRAMEWORK_DIR/docs-templates/runbook.md.tmpl" \
              "$(project_docs "$repo")/04_runbook.md" \
              "$rb_vars"
  rm -f "$rb_vars"

  ok "selection saved: skeleton=$skeleton region=$region env=$env"
  if (( ${#extensions_arr[@]} > 0 )); then
    ok "extensions:        ${extensions_arr[*]}"
  fi
  ok "runbook → $(project_docs "$repo")/04_runbook.md"
  ok "next: ./devops-ai.sh generate-iac $repo"
}

cmd_generate_iac() {
  local repo="${1:-}"; ensure_param "<repo>" "$repo"
  preflight_generate_iac "$repo"
  state_check "$repo" selected

  local skeleton region env source_path
  skeleton="$(state_get "$repo" infra_option)"
  region="$(state_get "$repo" region)"
  env="$(state_get "$repo" env)"
  source_path="$(state_get "$repo" source_path)"

  local skeleton_dir="$FRAMEWORK_DIR/templates/iac/$skeleton"
  local iac_dir; iac_dir="$(project_iac "$repo")"
  local vars_yaml="$iac_dir/inputs.yaml"

  step "Rendering skeleton '$skeleton' → $iac_dir"
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
  local extensions_csv inc_keycloak="false" inc_alb_https="false"
  extensions_csv="$(state_get "$repo" extensions 2>/dev/null || true)"
  if [[ -n "$extensions_csv" && "$extensions_csv" != "null" ]]; then
    case ",${extensions_csv}," in
      *,keycloak,*)  inc_keycloak="true"  ;;
    esac
    case ",${extensions_csv}," in
      *,alb-https,*) inc_alb_https="true" ;;
    esac
  fi

  local tmp_vars
  tmp_vars="$(mktemp)"
  cat > "$tmp_vars" <<EOF
project_name: "$repo"
region: "$region"
account_id: "$acct"
container_name: "app"
container_port: "8080"
health_check_path: "/health"
db_engine_version: "16.13"
db_name: "appdb"
db_master_username: "appuser"
domain_name: ""
log_retention_days: "14"
include_keycloak: "$inc_keycloak"
include_alb_https: "$inc_alb_https"
cluster_version: "1.30"
app_namespace: "default"
app_service_account: "${repo}-sa"
app_port: "8080"
artifact_bucket: "${repo}-artifacts"
function_handler: "app.handler"
dynamo_partition_key: "pk"
dynamo_sort_key: ""
state_bucket: "${repo}-tfstate"
EOF

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
  local overview_path="$(project_docs "$repo")/01_overview.md"
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
  local todo_count
  todo_count="$(grep -rn 'TODO(devops-ai)' "$iac_dir" 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${todo_count:-0}" -gt 0 ]]; then
    warn "$todo_count TODO(devops-ai) marker(s) remain in $iac_dir — review before deploy-infra"
    grep -rn 'TODO(devops-ai)' "$iac_dir" 2>/dev/null | sed 's|^|    |' >&2 || true
  fi

  state_set_bool "$repo" status.iac_generated true
  ok "IaC ready in $iac_dir"
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

_approval_phrase_for_env() {
  case "$1" in
    prod) echo "apply prod" ;;
    *)    echo "apply"      ;;
  esac
}

# Portable mtime in epoch seconds for a file. Returns 0 if the file is gone
# or stat fails on this platform.
_file_mtime_epoch() {
  local path="$1"
  [[ -e "$path" ]] || { echo 0; return; }
  stat -f %m "$path" 2>/dev/null \
    || stat -c %Y "$path" 2>/dev/null \
    || echo 0
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
  rm -f "$plan_summary_path"
  run_recipe infra-plan "PLAN READY plan_summary=${plan_summary_path}" \
    "repo_name=$repo" \
    "iac_dir=$iac_dir" \
    "env=$env" \
    "region=$region" \
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

  if [[ ! -t 0 ]]; then
    die "stdin is not a TTY — refusing to apply without an interactive operator. Run this command in a terminal."
  fi
  local confirm=""
  read -r -p "Type '${need_phrase}' to proceed (anything else aborts): " confirm

  local confirm_lc
  confirm_lc="$(printf '%s' "$confirm" | tr '[:upper:]' '[:lower:]')"
  if [[ "$confirm_lc" != "$need_phrase" ]]; then
    die "approval not given (got '$confirm', expected '$need_phrase'); deploy aborted"
  fi
  ok "approval received — running apply"

  run_recipe infra-apply "INFRA DEPLOYED env=${env} region=${region}" \
    "repo_name=$repo" \
    "iac_dir=$iac_dir" \
    "env=$env" \
    "region=$region" \
    "plan_summary_path=$plan_summary_path" \
    "outputs_path=$outputs_path"

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

  step "Plan only — terragrunt plan (read-only)"
  _infra_phase_plan "$repo" "$iac_dir" "$env" "$region" "$plan_summary_path"
  ok "plan summary → $plan_summary_path"
  ok "next: ./devops-ai.sh apply-infra $repo"
}

# assess — combined analyze + recommend in one Goose session.
# Designed for Opus 4.7's 1M context: it can hold the full repo and the
# skeleton catalogue at once, so we save the round-trip cost of running
# analyze and recommend separately. Writes both 01_overview.md and
# 02_infra_options.md in one shot, then flips analyzed+recommended.
cmd_assess() {
  local repo="${1:-}"; ensure_param "<repo>" "$repo"
  preflight_recommend "$repo"
  local source_path
  source_path="$(state_get "$repo" source_path)"
  local docs; docs="$(project_docs "$repo")"
  local overview_path="$docs/01_overview.md"
  local options_path="$docs/02_infra_options.md"
  local templates_dir="$FRAMEWORK_DIR/templates/iac"
  local state_yaml; state_yaml="$(project_dir "$repo")/state.yaml"

  run_recipe assess "WROTE ${options_path}" \
    "repo_name=$repo" \
    "source_path=$source_path" \
    "templates_dir=$templates_dir" \
    "overview_path=$overview_path" \
    "options_path=$options_path" \
    "state_yaml=$state_yaml"

  [[ -s "$overview_path" ]] || die "assess: overview not produced at $overview_path"
  [[ -s "$options_path" ]]  || die "assess: options not produced at $options_path"
  state_set_bool "$repo" status.analyzed true
  state_set_bool "$repo" status.recommended true
  ok "overview → $overview_path"
  ok "options  → $options_path"
  ok "next: ./devops-ai.sh select $repo --skeleton <id> --region <r> --env <e>"
}

# review-iac — Opus self-reviews freshly generated IaC for security, cost,
# correctness, and policy issues BEFORE plan-infra. Writes 03_review.md;
# does not block plan-infra automatically — operator decides.
cmd_review_iac() {
  local repo="${1:-}"; ensure_param "<repo>" "$repo"
  preflight_generate_iac "$repo"
  state_check "$repo" iac_generated
  local iac_dir; iac_dir="$(project_iac "$repo")"
  local docs; docs="$(project_docs "$repo")"
  local overview_path="$docs/01_overview.md"
  local out_path="$docs/03_review.md"
  local state_yaml; state_yaml="$(project_dir "$repo")/state.yaml"

  run_recipe review-iac "WROTE ${out_path}" \
    "repo_name=$repo" \
    "iac_dir=$iac_dir" \
    "overview_path=$overview_path" \
    "output_path=$out_path" \
    "state_yaml=$state_yaml"

  [[ -s "$out_path" ]] || die "review-iac: $out_path empty"
  ok "review → $out_path"
}

# explain-plan — read deploy/plan_summary.md plus terragrunt outputs and
# write a risk/cost/blast-radius narrative for human review prior to apply.
cmd_explain_plan() {
  local repo="${1:-}"; ensure_param "<repo>" "$repo"
  preflight_explain_plan "$repo"
  state_check "$repo" iac_generated
  local deploy_dir; deploy_dir="$(project_dep "$repo")"
  local plan_summary_path="$deploy_dir/plan_summary.md"
  [[ -s "$plan_summary_path" ]] || die "explain-plan: $plan_summary_path missing — run plan-infra first"
  local docs; docs="$(project_docs "$repo")"
  local out_path="$docs/06_plan_review.md"
  local state_yaml; state_yaml="$(project_dir "$repo")/state.yaml"

  run_recipe explain-plan "WROTE ${out_path}" \
    "repo_name=$repo" \
    "plan_summary_path=$plan_summary_path" \
    "output_path=$out_path" \
    "state_yaml=$state_yaml"

  [[ -s "$out_path" ]] || die "explain-plan: $out_path empty"
  ok "plan review → $out_path"
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
  local out_path="$docs/07_audit.md"
  local state_yaml; state_yaml="$(project_dir "$repo")/state.yaml"
  local iac_dir; iac_dir="$(project_iac "$repo")"

  run_recipe audit "WROTE ${out_path}" \
    "repo_name=$repo" \
    "iac_dir=$iac_dir" \
    "outputs_path=$outputs_path" \
    "output_path=$out_path" \
    "state_yaml=$state_yaml"

  [[ -s "$out_path" ]] || die "audit: $out_path empty"
  ok "audit → $out_path"
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

  step "Apply only — using existing plan summary"
  _infra_phase_gate_and_apply "$repo" "$iac_dir" "$env" "$region" \
    "$plan_summary_path" "$outputs_path"
  _print_access_summary "$repo" infra
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

  local region env source_path outputs_path history_path
  region="$(state_get "$repo" region)"
  env="$(state_get "$repo" env)"
  source_path="$(state_get "$repo" source_path)"
  outputs_path="$(project_dep "$repo")/outputs.json"
  history_path="$(project_dep "$repo")/history.jsonl"

  run_recipe deploy-app "APP DEPLOYED image=" \
    "repo_name=$repo" \
    "source_path=$source_path" \
    "region=$region" \
    "env=$env" \
    "outputs_path=$outputs_path" \
    "history_path=$history_path" \
    "git_ref=$git_ref"

  state_set_bool "$repo" status.app_deployed true
  ok "deploy-app finished; check $history_path for the record"
  _print_access_summary "$repo" app
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

  run_recipe upgrade "UPGRADED ${env} -> " \
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

  run_recipe rollback "ROLLED BACK ${env} -> ${previous_image}" \
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

cmd_destroy() {
  local repo="${1:-}"; ensure_param "<repo>" "$repo"
  require_project "$repo"
  local env; env="$(state_get "$repo" env)"
  [[ "$env" == "dev" ]] || die "destroy is only allowed for env=dev (current: $env). For other envs, run terragrunt destroy manually."

  local iac_dir; iac_dir="$(project_iac "$repo")"
  warn "This will run 'terragrunt run --all destroy' on $iac_dir/live/$env"
  read -r -p "Type the project name '$repo' to confirm: " confirm
  [[ "$confirm" == "$repo" ]] || die "confirmation mismatch — aborted"

  (cd "$iac_dir/live/$env" && TG_PARALLELISM=1 terragrunt run --all destroy --non-interactive)
  state_set_bool "$repo" status.infra_deployed false
  state_set_bool "$repo" status.app_deployed false
  ok "destroyed env=$env for $repo"
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
    review-iac)            cmd_review_iac "$@" ;;
    explain-plan)          cmd_explain_plan "$@" ;;
    audit)                 cmd_audit "$@" ;;
    aws-login)             cmd_aws_login "$@" ;;
    aws-bootstrap)         cmd_aws_bootstrap "$@" ;;
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
