#!/usr/bin/env python3
import json
import os
import sys
from typing import Tuple

DEFAULT_SYSTEM_PROMPT = """You are a senior release engineer. Generate a changelog from the provided git history and diff.

Rules:
- Output Markdown only.
- Do not use code fences.
- Do not invent changes that are not supported by the provided commits, file changes, or diff.
- Start with a short summary paragraph.
- Then use these sections only when relevant:
  ## Added
  ## Changed
  ## Fixed
  ## Refactored
  ## Docs
  ## Infrastructure
- Prioritize user-visible changes, but keep important technical details when they matter.
- Avoid repeating the same change in multiple sections.
- If the changes are mostly internal, tooling, or infrastructure, say that clearly.
- If any diff section is marked truncated or omitted, treat missing details as unknown rather than guessing.
"""


def read_env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


def read_file(path_env: str) -> str:
    path = read_env(path_env)
    if not path:
        return ""
    with open(path, "r", encoding="utf-8") as handle:
        return handle.read().strip()


def section(title: str, body: str) -> str:
    if not body.strip():
        return f"## {title}\n<empty>"
    return f"## {title}\n{body.strip()}"


def byte_len(text: str) -> int:
    return len(text.encode("utf-8"))


def maybe_trim_optional(base_parts, optional_parts, max_prompt_bytes: int) -> Tuple[list[str], list[str]]:
    parts = list(base_parts)
    notes: list[str] = []
    total = byte_len("\n\n".join(parts))
    for title, content, omission_note in optional_parts:
        if not content.strip():
            continue
        candidate = section(title, content)
        candidate_size = byte_len("\n\n".join(parts + [candidate]))
        if candidate_size <= max_prompt_bytes:
            parts.append(candidate)
            total = candidate_size
        else:
            notes.append(omission_note)
    return parts, notes


def main() -> int:
    current_ref = read_env("CURRENT_REF")
    current_version = read_env("CURRENT_VERSION")
    previous_tag = read_env("PREVIOUS_TAG")
    compare_range = read_env("COMPARE_RANGE")
    max_diff_bytes = read_env("INPUT_MAX_DIFF_BYTES", "200000")
    max_prompt_bytes = int(read_env("INPUT_MAX_PROMPT_BYTES", "300000"))

    commits = read_file("COMMITS_FILE")
    name_status = read_file("DIFF_NAME_STATUS_FILE")
    diff_stat = read_file("DIFF_STAT_FILE")
    aggregate_diff = read_file("DIFF_FILE")
    aggregate_diff_note = read_env("AGGREGATE_DIFF_NOTE")
    commit_patches = read_file("COMMIT_PATCHES_FILE")
    commit_patches_note = read_env("COMMIT_PATCHES_NOTE")

    if not current_ref:
        print("missing CURRENT_REF", file=sys.stderr)
        return 1
    if not previous_tag:
        print("missing PREVIOUS_TAG", file=sys.stderr)
        return 1
    if not compare_range:
        print("missing COMPARE_RANGE", file=sys.stderr)
        return 1
    if not any([commits.strip(), name_status.strip(), diff_stat.strip(), aggregate_diff.strip()]):
        print("prompt input is empty or incomplete; no git history or diff content was collected", file=sys.stderr)
        return 1

    metadata_lines = [
        f"current_ref: {current_ref}",
        f"previous_tag: {previous_tag}",
        f"compare_range: {compare_range}",
        f"max_diff_bytes: {max_diff_bytes}",
    ]
    if current_version:
        metadata_lines.insert(1, f"current_version: {current_version}")
    if aggregate_diff_note:
        metadata_lines.append(f"aggregate_diff_note: {aggregate_diff_note}")
    if commit_patches_note:
        metadata_lines.append(f"commit_patches_note: {commit_patches_note}")

    base_parts = [
        "Generate a release changelog from the following git evidence.",
        section("Release Context", "\n".join(metadata_lines)),
        section("Commit List", commits),
        section("Changed Files (git diff --name-status)", name_status),
        section("Diff Stat (git diff --stat)", diff_stat),
        section("Final Aggregate Diff (git diff previous_tag current_ref)", aggregate_diff),
    ]

    optional_parts = [
        (
            "Per-Commit Patches",
            commit_patches,
            "Per-commit patches were omitted because they would exceed the prompt size limit. Do not infer per-commit details beyond the included aggregate diff and commit list.",
        ),
    ]

    parts, notes = maybe_trim_optional(base_parts, optional_parts, max_prompt_bytes)
    if notes:
        parts.append(section("Prompt Assembly Notes", "\n".join(f"- {note}" for note in notes)))

    user_prompt = "\n\n".join(parts).strip()
    if not user_prompt:
        print("assembled user prompt is empty", file=sys.stderr)
        return 1

    payload = {
        "model": read_env("INPUT_MODEL"),
        "temperature": float(read_env("INPUT_TEMPERATURE", "0.2")),
        "messages": [
            {
                "role": "system",
                "content": read_env("INPUT_SYSTEM_PROMPT") or DEFAULT_SYSTEM_PROMPT,
            },
            {
                "role": "user",
                "content": user_prompt,
            },
        ],
    }

    json.dump(payload, sys.stdout, ensure_ascii=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
