# Repository Notes

This document contains the detailed repository-level design and semantics for `auto-llm-changelog`.

## Purpose

`auto-llm-changelog` is a standalone **composite GitHub Action** that generates a **Markdown changelog string** from Git history and repository diff, then sends that evidence to an **OpenAI-compatible Chat Completions API** using `curl`.

It is intentionally implemented with **bash + git + curl + python3**, with no Node.js, npm, or TypeScript scaffold.

## What the action does

1. resolves the target ref as `current_ref`
2. resolves the previous release tag as `previous_tag`
3. collects Git evidence between them:
   - commit list from `previous_tag..current_ref`
   - file changes from `git diff previous_tag current_ref`
   - diff stat
   - aggregate final diff
   - optional per-commit patches
4. builds a prompt
5. calls an OpenAI-compatible Chat Completions API
6. returns the generated **Markdown changelog** as an action output

The action **does not**:

- save the changelog to a file
- commit changes
- push changes
- perform checkout

Those behaviors belong to the caller workflow.

---

## Design goals

- **No gitflow assumption**: works with general Git repositories
- **Gitflow-compatible**: refs like `release/v1.2.3` work naturally
- **Stable Git semantics**: explicit two-endpoint comparison, not merge-base heuristics
- **Minimal dependencies**: shell-first, readable, easy to debug

---

## Ref and version semantics

### `current_ref`

`current_ref` means the target ref for which the changelog is generated.

Resolution order:

1. `current_ref_override`, if provided
2. otherwise the GitHub Actions checkout/ref context
3. otherwise the current local checked-out ref or `HEAD` commit SHA as a last fallback

`current_ref` may be:

- `release/v0.0.2`
- `origin/dev`
- `main`
- `master`
- a tag
- a commit SHA

### `current_version`

`current_version` is optional.

Resolution rules:

1. if `current_version_override` is provided, use it
2. otherwise, only auto-derive it when `current_ref` matches:
   - `release/vX.Y.Z`
   - `release/X.Y.Z`
3. otherwise `current_version` is empty

The action does **not** infer versions from arbitrary branch names, tag names, commit messages, or generic refs.

Supported version formats for this version:

- `vX.Y.Z`
- `X.Y.Z`

### `previous_tag`

`previous_tag` means the previous formal release tag.

Resolution order:

1. if `previous_tag_override` is provided, use it directly
2. otherwise, if `current_version` is available:
   - scan repository tags
   - keep only simple semver tags like `v1.2.3` or `1.2.3`
   - find the **largest tag strictly less than `current_version`**
3. otherwise fail with a clear error

If `current_version` is unavailable, the user must provide either:

- `current_version_override`, or
- `previous_tag_override`

The action intentionally does **not** guess `previous_tag` with fuzzy heuristics.

---

## Git semantics

### Commit range

This action uses:

```bash
git log previous_tag..current_ref
```

Meaning:

> commits reachable from `current_ref` but not reachable from `previous_tag`

Recommended formatting:

```bash
git log --reverse --no-merges --pretty=format:'- %h %s (%an)' previous_tag..current_ref
```

### Diff semantics

This action uses:

```bash
git diff previous_tag current_ref
```

Meaning:

> the final code snapshot difference between `previous_tag` and `current_ref`

### Why not three-dot diff

This action does **not** use:

```bash
git diff previous_tag...current_ref
```

Three-dot diff is merge-base based. That is useful in some review workflows, but changes the question from:

> what is the final difference between these two release points?

into:

> what changed on the `current_ref` side since the merge-base?

For changelog generation, the repository intentionally uses:

- `git log previous_tag..current_ref`
- `git diff previous_tag current_ref`

So the commit list and final diff are anchored to the same comparison pair.

---

## Prompt contents

The generated prompt includes:

### Always included

1. `current_ref`
2. `current_version` if available
3. `previous_tag`
4. `compare_range`
5. commit list from `git log previous_tag..current_ref`
6. changed files from `git diff --name-status previous_tag current_ref`
7. diff stat from `git diff --stat previous_tag current_ref`
8. aggregate final diff from `git diff --unified=2 --no-color previous_tag current_ref`

### Optionally included

9. per-commit patches from `git show --stat --unified=2 --no-color <sha>`

### Truncation behavior

If diff or optional patch sections are truncated or omitted, the prompt explicitly says so and instructs the model **not to invent unsupported changes**.

---

## Default system prompt behavior

If `system_prompt` is not provided, the built-in prompt tells the model to:

- behave like a senior release engineer
- output **Markdown only**
- avoid code fences
- avoid unsupported claims
- begin with a short summary paragraph
- use sections only when needed:
  - `Added`
  - `Changed`
  - `Fixed`
  - `Refactored`
  - `Docs`
  - `Infrastructure`
- prioritize user-visible changes while preserving important technical detail
- clearly say when the changes are mostly internal

---

## API contract

The action sends a `POST` request to:

```text
<api_endpoint>
```

with headers:

```http
Authorization: Bearer <api_key>
Content-Type: application/json
```

The request body contains at least:

- `model`
- `temperature`
- `messages`

The response parser supports:

- `choices[0].message.content` as a string
- `choices[0].message.content` as an array, extracting text chunks

The action fails clearly when:

- the endpoint returns non-2xx
- the response body is not valid JSON
- `choices[0].message.content` is missing
- the model returns empty content

When possible, the response body is printed to aid debugging.

---

## Checkout and fetch requirements

The action does **not** perform checkout.

Caller workflows should use:

- `actions/checkout@v5`
- `fetch-depth: 0`

This matters because shallow clones commonly break:

- previous tag discovery
- `git log previous_tag..current_ref`
- diff generation across older history

When `fetch_remote_refs=true`, the action tries to fetch:

- tags
- remote branch refs from `origin`

If there is no `origin` remote, the action logs a warning and continues.

---

## Important behavior notes

### Only certain refs auto-derive `current_version`

Automatic version-based previous-tag lookup happens **only** when:

- `current_version_override` is provided, or
- `current_ref` matches `release/vX.Y.Z`, or
- `current_ref` matches `release/X.Y.Z`

If neither is true, `current_version` stays empty.

### `previous_tag` must be a semver tag

Automatic previous-tag lookup only considers simple semver tags:

- `v1.2.3`
- `1.2.3`

Pre-release tags such as `1.2.3-beta.1` are intentionally out of scope in this version.

### `current_ref` is not hard-coded to `HEAD`

The public concept is `current_ref`, which may resolve to a branch name, tag, remote ref, or commit SHA depending on context and overrides.

---

## Error cases handled explicitly

The action fails with clear errors when:

1. `current_ref` cannot be resolved
2. `current_ref` does not exist locally
3. `current_version` is needed for automatic tag lookup but unavailable
4. `previous_tag` cannot be found
5. `previous_tag` does not exist locally
6. Git commands fail
7. the API request fails
8. the model returns empty content
9. the collected prompt input is empty or obviously abnormal

---

## Repository layout

```text
action.yml
README.md
REPO.md
scripts/
  main.sh
  build_prompt.py
  call_api.py
  lib/
    git.sh
    log.sh
    version.sh
examples/
  workflow.yml
```

---

## Development notes

- shell scripts use `set -euo pipefail`
- main logic lives in scripts, not in `action.yml`
- `GITHUB_OUTPUT` is used for composite-action outputs
- logs use GitHub Actions annotations such as `::group::`, `::debug::`, and `::error::`
