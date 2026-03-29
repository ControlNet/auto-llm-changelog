#!/usr/bin/env bash

parse_version_from_ref() {
  local ref="$1"
  if [[ "$ref" =~ ^release/(v?[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    printf '\n'
  fi
}

normalize_version() {
  local version="$1"
  version="${version#v}"
  if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s\n' "$version"
  else
    return 1
  fi
}

validate_semver_tag() {
  local tag="$1"
  [[ "$tag" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

find_previous_tag() {
  local current_version="$1"
  python3 - "$current_version" <<'PY'
import re
import subprocess
import sys

raw_version = sys.argv[1].strip()
version = raw_version[1:] if raw_version.startswith('v') else raw_version
if not re.fullmatch(r"\d+\.\d+\.\d+", version):
    print(f"invalid current_version for semver lookup: {raw_version}", file=sys.stderr)
    sys.exit(2)

def parse(ver: str):
    return tuple(int(part) for part in ver.split('.'))

target = parse(version)
try:
    output = subprocess.check_output(["git", "tag", "-l"], text=True)
except subprocess.CalledProcessError as exc:
    print(f"failed to list tags: {exc}", file=sys.stderr)
    sys.exit(exc.returncode or 1)

best_tag = None
best_version = None
for line in output.splitlines():
    tag = line.strip()
    if not re.fullmatch(r"v?\d+\.\d+\.\d+", tag):
        continue
    normalized = tag[1:] if tag.startswith('v') else tag
    parsed = parse(normalized)
    if parsed >= target:
        continue
    if best_version is None or parsed > best_version:
        best_version = parsed
        best_tag = tag

if best_tag is None:
    sys.exit(1)

print(best_tag)
PY
}
