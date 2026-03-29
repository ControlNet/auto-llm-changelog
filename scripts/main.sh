#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"
# shellcheck source=scripts/lib/git.sh
source "$SCRIPT_DIR/lib/git.sh"
# shellcheck source=scripts/lib/version.sh
source "$SCRIPT_DIR/lib/version.sh"

DEBUG="${INPUT_DEBUG:-false}"
export DEBUG

require_input() {
  local name="$1"
  local value="$2"
  [[ -n "$value" ]] || fail "Missing required input: $name"
}

cleanup() {
  if [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

write_output() {
  local key="$1"
  local value="$2"
  local delimiter="EOF_$(python3 - <<'PY'
import secrets
print(secrets.token_hex(8))
PY
)"
  {
    printf '%s<<%s\n' "$key" "$delimiter"
    printf '%s\n' "$value"
    printf '%s\n' "$delimiter"
  } >> "$GITHUB_OUTPUT"
}

main() {
  require_input "api_endpoint" "${INPUT_API_ENDPOINT:-}"
  require_input "api_key" "${INPUT_API_KEY:-}"
  require_input "model" "${INPUT_MODEL:-}"
  require_input "temperature" "${INPUT_TEMPERATURE:-}"
  require_input "max_diff_bytes" "${INPUT_MAX_DIFF_BYTES:-}"

  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "This action must run inside a git repository. Did you run actions/checkout first?"
  : "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required by GitHub Actions composite actions}"

  if [[ "${INPUT_FETCH_REMOTE_REFS:-true}" == "true" ]]; then
    fetch_refs
  else
    log_info "Skipping remote fetch because fetch_remote_refs=false"
  fi

  log_group "Resolving current_ref"
  CURRENT_REF="$(resolve_current_ref || true)"
  [[ -n "$CURRENT_REF" ]] || fail "Unable to resolve current_ref. Provide current_ref_override or ensure the checkout/ref environment is available."
  GIT_CURRENT_REF="$(resolve_ref_for_git "$CURRENT_REF" || true)"
  [[ -n "$GIT_CURRENT_REF" ]] || fail "Resolved current_ref does not exist as a commit-ish: $CURRENT_REF"
  log_info "current_ref=$CURRENT_REF"
  log_debug "git_current_ref=$GIT_CURRENT_REF"
  log_endgroup

  log_group "Resolving current_version"
  CURRENT_VERSION=""
  if [[ -n "${INPUT_CURRENT_VERSION_OVERRIDE:-}" ]]; then
    CURRENT_VERSION="${INPUT_CURRENT_VERSION_OVERRIDE}"
    normalize_version "$CURRENT_VERSION" >/dev/null || fail "current_version_override must be a simple semver like v1.2.3 or 1.2.3"
  else
    CURRENT_VERSION="$(parse_version_from_ref "$CURRENT_REF")"
    if [[ -n "$CURRENT_VERSION" ]]; then
      normalize_version "$CURRENT_VERSION" >/dev/null || fail "Parsed current_version is not valid semver: $CURRENT_VERSION"
    fi
  fi
  log_info "current_version=${CURRENT_VERSION:-<empty>}"
  log_endgroup

  log_group "Resolving previous_tag"
  PREVIOUS_TAG=""
  if [[ -n "${INPUT_PREVIOUS_TAG_OVERRIDE:-}" ]]; then
    PREVIOUS_TAG="${INPUT_PREVIOUS_TAG_OVERRIDE}"
    validate_semver_tag "$PREVIOUS_TAG" || fail "previous_tag_override must be a semver tag like v1.2.3 or 1.2.3"
  else
    if [[ -z "$CURRENT_VERSION" ]]; then
      fail "Unable to resolve previous_tag automatically because current_version is empty. Provide current_version_override or previous_tag_override. current_version is only auto-derived from release/<version> refs."
    fi
    PREVIOUS_TAG="$(find_previous_tag "$CURRENT_VERSION" || true)"
    [[ -n "$PREVIOUS_TAG" ]] || fail "No previous semver tag exists that is strictly lower than current_version=$CURRENT_VERSION. Provide previous_tag_override if needed."
  fi
  ensure_tag_exists "$PREVIOUS_TAG" || fail "Resolved previous_tag does not exist in the local repository: $PREVIOUS_TAG"
  log_info "previous_tag=$PREVIOUS_TAG"
  log_endgroup

  COMPARE_RANGE="$PREVIOUS_TAG..$CURRENT_REF"
  WORK_DIR="$(mktemp -d)"
  export CURRENT_REF CURRENT_VERSION PREVIOUS_TAG COMPARE_RANGE WORK_DIR

  COMMITS_FILE="$WORK_DIR/commits.txt"
  DIFF_NAME_STATUS_FILE="$WORK_DIR/diff-name-status.txt"
  DIFF_STAT_FILE="$WORK_DIR/diff-stat.txt"
  DIFF_FILE="$WORK_DIR/diff.patch"
  COMMIT_PATCHES_FILE="$WORK_DIR/commit-patches.patch"
  PAYLOAD_FILE="$WORK_DIR/payload.json"
  MARKDOWN_FILE="$WORK_DIR/changelog.md"
  export COMMITS_FILE DIFF_NAME_STATUS_FILE DIFF_STAT_FILE DIFF_FILE COMMIT_PATCHES_FILE

  log_group "Collecting git evidence"
  collect_commits "$PREVIOUS_TAG" "$GIT_CURRENT_REF" > "$COMMITS_FILE"
  collect_diff_namestat "$PREVIOUS_TAG" "$GIT_CURRENT_REF" > "$DIFF_NAME_STATUS_FILE"
  collect_diff_stat "$PREVIOUS_TAG" "$GIT_CURRENT_REF" > "$DIFF_STAT_FILE"
  collect_diff_unified "$PREVIOUS_TAG" "$GIT_CURRENT_REF" > "$DIFF_FILE"

  AGGREGATE_DIFF_NOTE=""
  if [[ "$(wc -c < "$DIFF_FILE")" -gt "${INPUT_MAX_DIFF_BYTES}" ]]; then
    python3 - "$DIFF_FILE" "${INPUT_MAX_DIFF_BYTES}" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
max_bytes = int(sys.argv[2])
data = path.read_bytes()[:max_bytes]
path.write_bytes(data)
PY
    AGGREGATE_DIFF_NOTE="Aggregate diff was truncated at ${INPUT_MAX_DIFF_BYTES} bytes. The diff may be incomplete. Do not infer changes that are not directly shown."
  fi
  export AGGREGATE_DIFF_NOTE

  COMMIT_PATCHES_NOTE="Per-commit patches were not requested."
  : > "$COMMIT_PATCHES_FILE"
  if [[ "${INPUT_INCLUDE_COMMIT_PATCHES:-false}" == "true" ]]; then
    COMMIT_PATCHES_NOTE=""
    if collect_commit_patches "$PREVIOUS_TAG" "$GIT_CURRENT_REF" "${INPUT_MAX_DIFF_BYTES}" > "$COMMIT_PATCHES_FILE" 2> "$WORK_DIR/commit-patches.stderr"; then
      if grep -q '^TRUNCATED$' "$WORK_DIR/commit-patches.stderr" 2>/dev/null; then
        COMMIT_PATCHES_NOTE="Per-commit patches were truncated at ${INPUT_MAX_DIFF_BYTES} bytes. They may be incomplete. Do not infer omitted patch details."
      fi
    else
      fail "Failed to collect per-commit patches."
    fi
  fi
  export COMMIT_PATCHES_NOTE

  if [[ ! -s "$COMMITS_FILE" && ! -s "$DIFF_NAME_STATUS_FILE" && ! -s "$DIFF_STAT_FILE" && ! -s "$DIFF_FILE" ]]; then
    fail "Prompt input is empty or abnormal. No commit or diff evidence was collected for $COMPARE_RANGE"
  fi
  log_endgroup

  log_group "Building prompt payload"
  python3 "$SCRIPT_DIR/build_prompt.py" > "$PAYLOAD_FILE"
  log_debug "payload_file=$PAYLOAD_FILE"
  log_endgroup

  log_group "Calling Chat Completions API"
  python3 "$SCRIPT_DIR/call_api.py" "$PAYLOAD_FILE" > "$MARKDOWN_FILE"
  [[ -s "$MARKDOWN_FILE" ]] || fail "Model returned empty content."
  log_endgroup

  log_group "Writing action outputs"
  write_output "markdown" "$(<"$MARKDOWN_FILE")"
  write_output "current_ref" "$CURRENT_REF"
  write_output "version" "${CURRENT_VERSION:-}"
  write_output "previous_tag" "$PREVIOUS_TAG"
  write_output "compare_range" "$COMPARE_RANGE"
  log_endgroup

  log_info "Changelog generation completed."
}

main "$@"
