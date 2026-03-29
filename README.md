# auto-llm-changelog

A standalone **composite GitHub Action** that generates a **Markdown changelog string** from Git history and repository diff, then sends that evidence to an **OpenAI-compatible Chat Completions API** using `curl`.

It is intentionally implemented with **bash + git + curl + python3**, with no Node.js, npm, or TypeScript project scaffold.

## What this action does

This action:

1. resolves the target ref to describe as `current_ref`
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

This action **does not**:

- save the changelog to a file
- commit changes
- push changes
- run checkout for you

Those behaviors belong to the calling workflow.

---

## Design goals

- **No gitflow assumption**: works with general Git repositories
- **Gitflow-compatible**: if you use refs like `release/v1.2.3`, automatic version lookup works
- **Stable Git semantics**: commit range and diff semantics are explicit and not based on merge-base heuristics
- **Minimal dependencies**: shell-first, readable, easy to debug

---

## Ref and version semantics

### `current_ref`

`current_ref` means: **the target ref for which this changelog is being generated**.

Resolution order:

1. `current_ref_override`, if provided
2. otherwise the current GitHub Actions checkout/ref context
3. otherwise the current local checked-out ref or `HEAD` commit SHA as a last fallback

`current_ref` may be any valid commit-ish, for example:

- `release/v0.0.2`
- `origin/dev`
- `main`
- `master`
- a tag
- a commit SHA

### `current_version`

`current_version` is **optional**.

It is resolved strictly as follows:

1. if `current_version_override` is provided, use it
2. otherwise, only auto-derive it when `current_ref` matches one of these forms:
   - `release/vX.Y.Z`
   - `release/X.Y.Z`
3. otherwise `current_version` is empty

This action **does not** try to guess a version from:

- arbitrary branch names
- tag names
- commit messages
- `main`, `master`, `dev`, or other refs

Supported version formats for this first implementation:

- `vX.Y.Z`
- `X.Y.Z`

### `previous_tag`

`previous_tag` means: **the previous formal release tag**.

Resolution order:

1. if `previous_tag_override` is provided, use it directly
2. otherwise, if `current_version` is available:
   - scan repository tags
   - keep only simple semver tags like `v1.2.3` or `1.2.3`
   - find the **largest tag strictly less than `current_version`**
3. otherwise fail with a clear error

If `current_version` is unavailable, the action will tell you to provide either:

- `current_version_override`, or
- `previous_tag_override`

This is intentional: the action does **not** guess `previous_tag` by fuzzy heuristics.

---

## Why these Git semantics are used

### Commit range

This action uses:

```bash
git log previous_tag..current_ref
```

That means:

> commits reachable from `current_ref` but not reachable from `previous_tag`

This matches the intended release-note semantics for the commit list.

Recommended internal formatting is:

```bash
git log --reverse --no-merges --pretty=format:'- %h %s (%an)' previous_tag..current_ref
```

### Diff semantics

This action uses:

```bash
git diff previous_tag current_ref
```

That means:

> the final code snapshot difference between `previous_tag` and `current_ref`

This is what you usually want for a release changelog prompt.

### Why not three-dot diff?

This action **does not** use:

```bash
git diff previous_tag...current_ref
```

Three-dot diff is merge-base based. That is useful for some code review workflows, but it changes the question from:

> what is the final difference between these two release points?

into:

> what changed on the `current_ref` side since the merge-base?

For changelog generation, this repository intentionally uses:

- `git log previous_tag..current_ref`
- `git diff previous_tag current_ref`

So the commit list and final diff are both anchored to the same comparison pair.

---

## Inputs

### Required

| Input | Description |
|---|---|
| `api_endpoint` | OpenAI-compatible Chat Completions endpoint, e.g. `https://example.com/v1/chat/completions` |
| `api_key` | API key sent as `Authorization: Bearer <api_key>` |
| `model` | Model name sent in the request body |

### Optional

| Input | Default | Description |
|---|---:|---|
| `current_ref_override` | `""` | Explicitly set `current_ref` |
| `current_version_override` | `""` | Explicitly set `current_version`; required for auto previous-tag lookup when `current_ref` is not `release/<version>` |
| `previous_tag_override` | `""` | Use this tag directly and skip automatic previous-tag lookup |
| `temperature` | `0.2` | Sampling temperature for the API request |
| `max_diff_bytes` | `200000` | Max bytes included for aggregate final diff; larger diffs are truncated with an explicit note |
| `system_prompt` | `""` | Override the built-in default system prompt |
| `fetch_remote_refs` | `true` | Fetch tags and remote branches before resolving refs |
| `include_commit_patches` | `false` | Include per-commit patches in the prompt, also size-limited |
| `debug` | `false` | Enable verbose debug logs |
| `max_prompt_bytes` | `300000` | Soft cap for assembled prompt size; optional sections may be omitted when over budget |

### Why `max_prompt_bytes` exists

`max_diff_bytes` only limits the aggregate diff section. In practice, prompt size can still grow because of commit lists, diff stat, and optional commit patches. `max_prompt_bytes` provides a second safety valve so optional sections can be dropped before making the API call.

---

## Outputs

| Output | Description |
|---|---|
| `markdown` | Final Markdown changelog string returned by the model |
| `current_ref` | Actual `current_ref` used for the comparison |
| `version` | Resolved `current_version`, or empty string if none was available |
| `previous_tag` | Actual previous semver tag used for comparison |
| `compare_range` | Compare range in `previous_tag..current_ref` form |

---

## Default system prompt

If `system_prompt` is not provided, the action uses a built-in prompt that tells the model to:

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

You can override the whole system prompt through the `system_prompt` input.

---

## API contract

This action sends a `POST` request to:

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

The response parser supports both of these content forms:

- `choices[0].message.content` as a string
- `choices[0].message.content` as an array of content objects, extracting `text`

### API error handling

The action fails clearly when:

- the endpoint returns non-2xx
- the response body is not valid JSON
- `choices[0].message.content` is missing
- the model returns empty content

When possible, the response body is printed to aid debugging.

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

If the diff or optional patch sections are truncated or omitted, the prompt explicitly says so and instructs the model **not to invent unsupported changes**.

---

## Checkout and fetch requirements

This action does **not** perform checkout for you.

Your workflow should use:

- `actions/checkout@v5`
- `fetch-depth: 0`

This matters because shallow clones commonly cause wrong or missing results for:

- previous tag discovery
- `git log previous_tag..current_ref`
- diff generation across older history

Even with full checkout, it is still a good idea to ensure tags and refs are present.

When `fetch_remote_refs=true`, the action will try to fetch:

- tags
- remote branch refs from `origin`

If there is no `origin` remote, the action logs a warning and continues.

---

## Minimal usage example

```yaml
name: Generate changelog

on:
  workflow_dispatch:

jobs:
  changelog:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout full history
        uses: actions/checkout@v5
        with:
          fetch-depth: 0
          fetch-tags: true

      - name: Generate changelog markdown
        id: changelog
        uses: ControlNet/auto-llm-changelog@v1
        with:
          api_endpoint: ${{ secrets.LLM_API_ENDPOINT }}
          api_key: ${{ secrets.LLM_API_KEY }}
          model: gpt-4o

      - name: Print markdown
        run: |
          printf '%s\n' '${{ steps.changelog.outputs.markdown }}'
```

---

## Example: save output to `.github/changelog/<version>.md`

```yaml
name: Generate and save changelog

on:
  workflow_dispatch:
    inputs:
      current_version_override:
        required: false
        default: ''
      previous_tag_override:
        required: false
        default: ''

jobs:
  changelog:
    runs-on: ubuntu-latest
    permissions:
      contents: write

    steps:
      - name: Checkout full history
        uses: actions/checkout@v5
        with:
          fetch-depth: 0
          fetch-tags: true

      - name: Generate changelog
        id: changelog
        uses: ControlNet/auto-llm-changelog@v1
        with:
          api_endpoint: ${{ secrets.LLM_API_ENDPOINT }}
          api_key: ${{ secrets.LLM_API_KEY }}
          model: gpt-4o
          current_version_override: ${{ inputs.current_version_override }}
          previous_tag_override: ${{ inputs.previous_tag_override }}

      - name: Save markdown to file
        env:
          CHANGELOG_MARKDOWN: ${{ steps.changelog.outputs.markdown }}
          VERSION: ${{ steps.changelog.outputs.version }}
          RANGE: ${{ steps.changelog.outputs.compare_range }}
        run: |
          set -euo pipefail
          mkdir -p .github/changelog

          if [[ -z "$VERSION" ]]; then
            VERSION="${RANGE//[.\/]/-}"
          fi

          printf '%s\n' "$CHANGELOG_MARKDOWN" > ".github/changelog/${VERSION}.md"
```

A fuller example, including optional commit-back behavior, is available in [examples/workflow.yml](examples/workflow.yml).

---

## Important behavior notes

### Only certain refs auto-derive `current_version`

Automatic version-based previous-tag lookup happens **only** when one of these is true:

- `current_version_override` is provided, or
- `current_ref` matches `release/vX.Y.Z`, or
- `current_ref` matches `release/X.Y.Z`

If neither is true, `current_version` stays empty.

In that case, you must provide one of:

- `current_version_override`, or
- `previous_tag_override`

### `previous_tag` must be a semver tag

Automatic previous-tag lookup only considers simple semver tags:

- `v1.2.3`
- `1.2.3`

Pre-release tags such as `1.2.3-beta.1` are intentionally out of scope for this first version.

### `current_ref` is not hard-coded to `HEAD`

This action does not expose `HEAD` as the public semantic object. The public concept is `current_ref`, which may resolve to a branch name, tag, remote ref, or commit SHA depending on context and overrides.

---

## Error cases handled explicitly

This action fails with clear errors when:

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

---

## Example release flow

A common pattern is:

1. checkout full history
2. call this action
3. save `${{ steps.changelog.outputs.markdown }}` to `.github/changelog/<version>.md`
4. optionally commit and push the file

That keeps this action focused on changelog generation and leaves repository mutation to the calling workflow.
