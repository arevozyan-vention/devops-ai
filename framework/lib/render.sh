#!/usr/bin/env bash
# lib/render.sh — variable substitution for templates.
# Source this file from devops-ai.sh; do not execute directly.
#
# Templates use {{key}} placeholders. Variables come from a flat YAML file
# whose top-level keys are scalar strings, e.g.:
#
#   project_name: hiriskpro
#   region: us-east-1
#   env: dev
#   container_port: "8080"
#
# Nested structures and multi-line values are NOT supported — keep vars files
# flat. This is intentional: it keeps substitution predictable and avoids
# whitespace/quote bugs in generated HCL.
#
# Public API:
#   render_string  <vars-yaml>                 (stdin -> stdout)
#   render_file    <template> <output> <vars-yaml>
#   render_dir     <src-dir>  <dst-dir> <vars-yaml>
#       Copies src-dir to dst-dir verbatim, then for every file ending in .tmpl
#       the .tmpl extension is stripped and {{vars}} are substituted. Files
#       without .tmpl are copied byte-for-byte (binary-safe).

set -euo pipefail

: "${FRAMEWORK_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

_render_require() {
  command -v yq >/dev/null 2>&1 || { echo "render.sh: 'yq' is required" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "render.sh: 'jq' is required" >&2; return 1; }
}

# Internal: emit TSV (key<TAB>value) lines from a flat vars YAML.
# Rejects nested objects/arrays.
_render_kv_tsv() {
  local vars_yaml="$1"
  [[ -f "$vars_yaml" ]] || { echo "render.sh: vars file '$vars_yaml' not found" >&2; return 1; }

  local json
  json="$(yq -o=json '.' "$vars_yaml")"

  if echo "$json" | jq -e 'to_entries[] | select(.value | type | IN("object","array"))' >/dev/null 2>&1; then
    echo "render.sh: vars file '$vars_yaml' contains non-scalar values; keep it flat" >&2
    return 1
  fi

  echo "$json" | jq -r 'to_entries[] | "\(.key)\t\(.value // "")"'
}

# render_string <vars-yaml>
# Reads template body on stdin, writes substituted body to stdout.
# Uses bash literal substitution — no sed/awk escaping required.
render_string() {
  _render_require
  local vars_yaml="$1"
  local body k v
  body="$(cat)"
  while IFS=$'\t' read -r k v; do
    [[ -z "$k" ]] && continue
    # bash ${var//pat/rep}: pattern allows globs, replacement is literal.
    # Keys are alphanumeric+_ (validated upstream); {{ }} have no glob meaning.
    body="${body//\{\{$k\}\}/$v}"
  done < <(_render_kv_tsv "$vars_yaml")
  printf '%s' "$body"
}

# render_file <template> <output> <vars-yaml>
render_file() {
  local template="$1" output="$2" vars_yaml="$3"
  [[ -f "$template" ]] || { echo "render.sh: template '$template' not found" >&2; return 1; }
  mkdir -p "$(dirname "$output")"
  render_string "$vars_yaml" < "$template" > "$output"
}

# render_dir <src-dir> <dst-dir> <vars-yaml>
# Copy tree, then in-place substitute .tmpl files (and strip the suffix).
render_dir() {
  local src="$1" dst="$2" vars_yaml="$3"
  [[ -d "$src" ]] || { echo "render.sh: source dir '$src' not found" >&2; return 1; }

  mkdir -p "$dst"
  (cd "$src" && find . -type d -exec mkdir -p "$dst/{}" \;)
  (cd "$src" && find . -type f -print0 | while IFS= read -r -d '' rel; do
    cp -p "$rel" "$dst/$rel"
  done)

  # Render every .tmpl file in place; strip the .tmpl suffix from the output.
  find "$dst" -type f -name '*.tmpl' -print0 | while IFS= read -r -d '' tmpl; do
    local out="${tmpl%.tmpl}"
    render_string "$vars_yaml" < "$tmpl" > "$out"
    rm -f "$tmpl"
  done
}

# render_check_unresolved <path>
# Greps a rendered file/dir for any leftover {{...}} placeholders.
# Useful as a post-step after render_dir to catch missing vars.
# Returns 1 (and prints offenders) if any unresolved placeholder is found.
render_check_unresolved() {
  local target="$1"
  [[ -e "$target" ]] || { echo "render.sh: target '$target' not found" >&2; return 1; }
  local hits
  if [[ -d "$target" ]]; then
    hits="$(grep -rEn '\{\{[A-Za-z0-9_]+\}\}' "$target" || true)"
  else
    hits="$(grep -En '\{\{[A-Za-z0-9_]+\}\}' "$target" || true)"
  fi
  if [[ -n "$hits" ]]; then
    echo "render.sh: unresolved placeholders found:" >&2
    echo "$hits" >&2
    return 1
  fi
  return 0
}
