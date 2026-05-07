#!/usr/bin/env bash
# lib/outputs.sh — merge per-unit Terragrunt outputs into a single valid
# JSON file at $outputs_path.
#
# Why: `terragrunt run --all output -- -json` concatenates each unit's
# `terraform output -json` to stdout WITHOUT wrapping them as a single
# document. The resulting file is `{...}{...}{...}` — looks valid line-by-
# line but `jq empty` fails with "Extra data". Downstream callers
# (deploy-app, _print_access_summary) all assume one valid JSON object.
#
# This helper merges those per-unit objects into a flat object via
# `jq '. * $outs'`. Last writer wins on key collisions — acceptable for
# our skeleton because the keys USED downstream (dns_name,
# db_instance_endpoint, repository_url, etc.) are unique per unit family.
#
# Two implementations:
#   _merge_fast  — one terragrunt invocation + `jq -s` reduction over the
#                  resulting JSON stream. Single pass through all units,
#                  ~30 seconds for ~15 units.
#   _merge_slow  — explicit loop, one `terragrunt output` per unit. ~5-7 min
#                  for 15 units. Only used as fallback when fast path fails
#                  (e.g. one unit's state is corrupted and breaks the stream).

# merge_terragrunt_outputs <env_dir> <out_path>
#   env_dir:  e.g. <iac_dir>/environments/dev — must contain unit subdirs
#             each with their own terragrunt.hcl
#   out_path: where to write the merged JSON
# Returns 0 on success (valid JSON written), non-zero if no units yielded
# outputs OR jq is unavailable. NEVER fabricates content.
merge_terragrunt_outputs() {
  local env_dir="$1" out_path="$2"

  [[ -d "$env_dir" ]] || {
    echo "merge_terragrunt_outputs: env dir not found: $env_dir" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    echo "merge_terragrunt_outputs: jq is required" >&2
    return 1
  }
  command -v terragrunt >/dev/null 2>&1 || {
    echo "merge_terragrunt_outputs: terragrunt is required" >&2
    return 1
  }

  # Try the fast path first.
  if _merge_fast "$env_dir" "$out_path"; then
    return 0
  fi

  echo "merge_terragrunt_outputs: fast path failed, falling back to per-unit loop" >&2
  _merge_slow "$env_dir" "$out_path"
}

# Fast: single `terragrunt run --all output` pass; jq slurps the resulting
# concatenated JSON stream and folds it into one object.
_merge_fast() {
  local env_dir="$1" out_path="$2" stderr_log
  stderr_log="$(mktemp)"

  # Capture stdout (the concatenated JSON stream); stderr to a temp file so
  # we can inspect failures without polluting outputs.
  if ! (cd "$env_dir" && \
        TG_PARALLELISM=1 terragrunt run --all output --non-interactive -- -json \
        2>"$stderr_log") \
       | jq -s 'reduce .[] as $o ({}; . * $o)' \
       > "$out_path.tmp" 2>>"$stderr_log"; then
    rm -f "$out_path.tmp" "$stderr_log"
    return 1
  fi

  # Validate the result is a non-empty object.
  if ! jq -e 'type == "object" and (. != {})' "$out_path.tmp" >/dev/null 2>&1; then
    rm -f "$out_path.tmp" "$stderr_log"
    return 1
  fi

  mv "$out_path.tmp" "$out_path"
  rm -f "$stderr_log"

  local key_count
  key_count="$(jq -r 'keys | length' "$out_path" 2>/dev/null)"
  echo "merge_terragrunt_outputs (fast): single pass — ${key_count:-?} top-level keys" >&2
  return 0
}

# Slow fallback: iterate units and call `terragrunt output` per unit. Used
# only when _merge_fast fails (corrupted state for one unit, terragrunt
# version mismatch, etc.). This is the original implementation.
_merge_slow() {
  local env_dir="$1" out_path="$2"

  echo '{}' > "$out_path" || return 1

  local merged_count=0 skipped_count=0
  local unit_dir unit_name unit_out
  while IFS= read -r unit_dir; do
    unit_name="$(basename "$unit_dir")"
    [[ "$unit_name" == _* || "$unit_name" == .* ]] && continue

    if ! unit_out="$(cd "$unit_dir" && terragrunt output --non-interactive -- -json 2>/dev/null)"; then
      skipped_count=$((skipped_count + 1))
      continue
    fi
    [[ -z "$unit_out" || "$unit_out" == "{}" ]] && {
      skipped_count=$((skipped_count + 1))
      continue
    }
    if ! printf '%s' "$unit_out" | jq -e 'type == "object"' >/dev/null 2>&1; then
      skipped_count=$((skipped_count + 1))
      continue
    fi

    if jq --argjson outs "$unit_out" '. * $outs' "$out_path" > "$out_path.tmp"; then
      mv "$out_path.tmp" "$out_path"
      merged_count=$((merged_count + 1))
    else
      rm -f "$out_path.tmp"
      skipped_count=$((skipped_count + 1))
    fi
  done < <(find "$env_dir" -mindepth 2 -maxdepth 2 -name terragrunt.hcl -type f \
             -not -path '*/_envcommon/*' -exec dirname {} \;)

  if ! jq empty "$out_path" 2>/dev/null; then
    echo "merge_terragrunt_outputs (slow): produced file failed jq empty: $out_path" >&2
    return 1
  fi

  echo "merge_terragrunt_outputs (slow): merged ${merged_count} units, skipped ${skipped_count}" >&2
  (( merged_count > 0 )) || return 2
  return 0
}
