#!/usr/bin/env bash

fetch_refs() {
  if ! git remote get-url origin >/dev/null 2>&1; then
    log_warning "No origin remote found. Skipping fetch_remote_refs step."
    return 0
  fi

  log_group "Fetching tags and remote refs"
  git fetch --force --prune --tags origin
  git fetch --force --prune origin '+refs/heads/*:refs/remotes/origin/*'
  log_endgroup
}

resolve_current_ref() {
  if [[ -n "${INPUT_CURRENT_REF_OVERRIDE:-}" ]]; then
    printf '%s\n' "$INPUT_CURRENT_REF_OVERRIDE"
    return 0
  fi

  if [[ -n "${GITHUB_HEAD_REF:-}" ]]; then
    printf '%s\n' "$GITHUB_HEAD_REF"
    return 0
  fi

  if [[ -n "${GITHUB_REF_TYPE:-}" && "$GITHUB_REF_TYPE" == "tag" && -n "${GITHUB_REF_NAME:-}" ]]; then
    printf '%s\n' "$GITHUB_REF_NAME"
    return 0
  fi

  if [[ -n "${GITHUB_REF_NAME:-}" ]]; then
    printf '%s\n' "$GITHUB_REF_NAME"
    return 0
  fi

  local symbolic_ref
  symbolic_ref="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [[ -n "$symbolic_ref" ]]; then
    printf '%s\n' "$symbolic_ref"
    return 0
  fi

  local head_sha
  head_sha="$(git rev-parse HEAD 2>/dev/null || true)"
  if [[ -n "$head_sha" ]]; then
    printf '%s\n' "$head_sha"
    return 0
  fi

  return 1
}

ref_exists_commitish() {
  local ref="$1"
  git rev-parse --verify --quiet "$ref^{commit}" >/dev/null
}

resolve_ref_for_git() {
  local ref="$1"
  local -a candidates=()
  local candidate

  if [[ -n "$ref" ]]; then
    candidates+=("$ref")
  fi

  if [[ -n "$ref" && "$ref" != origin/* && "$ref" != refs/* && ! "$ref" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
    candidates+=("origin/$ref" "refs/remotes/origin/$ref")
  fi

  if [[ -n "${GITHUB_SHA:-}" ]]; then
    candidates+=("$GITHUB_SHA")
  fi

  for candidate in "${candidates[@]}"; do
    if [[ -n "$candidate" ]] && ref_exists_commitish "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

ensure_ref_exists() {
  local ref="$1"
  resolve_ref_for_git "$ref" >/dev/null
}

ensure_tag_exists() {
  local tag="$1"
  git show-ref --verify --quiet "refs/tags/$tag"
}

collect_commits() {
  local previous_tag="$1"
  local current_ref="$2"
  git log --reverse --no-merges --pretty=format:'- %h %s (%an)' "$previous_tag..$current_ref"
}

collect_commit_shas() {
  local previous_tag="$1"
  local current_ref="$2"
  git log --reverse --no-merges --format='%H' "$previous_tag..$current_ref"
}

collect_diff_namestat() {
  local previous_tag="$1"
  local current_ref="$2"
  git diff --name-status "$previous_tag" "$current_ref"
}

collect_diff_stat() {
  local previous_tag="$1"
  local current_ref="$2"
  git diff --stat "$previous_tag" "$current_ref"
}

collect_diff_unified() {
  local previous_tag="$1"
  local current_ref="$2"
  git diff --unified=2 --no-color "$previous_tag" "$current_ref"
}

collect_commit_patches() {
  local previous_tag="$1"
  local current_ref="$2"
  local max_bytes="$3"

  python3 - "$previous_tag" "$current_ref" "$max_bytes" <<'PY'
import subprocess
import sys

previous_tag, current_ref, max_bytes_raw = sys.argv[1:4]
max_bytes = int(max_bytes_raw)
shas = subprocess.check_output(
    ["git", "log", "--reverse", "--no-merges", "--format=%H", f"{previous_tag}..{current_ref}"],
    text=True,
).splitlines()
chunks = []
used = 0
truncated = False
for sha in shas:
    patch = subprocess.check_output(
        ["git", "show", "--stat", "--unified=2", "--no-color", "--format=medium", sha],
        text=True,
    )
    size = len(patch.encode("utf-8"))
    if used + size > max_bytes:
      remaining = max_bytes - used
      if remaining > 0:
          encoded = patch.encode("utf-8")[:remaining]
          chunks.append(encoded.decode("utf-8", errors="ignore"))
      truncated = True
      break
    chunks.append(patch)
    used += size

sys.stdout.write("".join(chunks))
if truncated:
    sys.stderr.write("TRUNCATED\n")
PY
}
