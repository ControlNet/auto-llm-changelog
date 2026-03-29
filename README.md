# auto-llm-changelog

A lightweight **composite GitHub Action** that generates a Markdown changelog from Git history by sending Git evidence to an **OpenAI-compatible Chat Completions API**.

Full repository design, semantics, and implementation notes are in [REPO.md](REPO.md).

## How it works

The action:

1. resolves `current_ref`
2. resolves `previous_tag`
3. collects Git evidence between them:
   - `git log previous_tag..current_ref`
   - `git diff --name-status previous_tag current_ref`
   - `git diff --stat previous_tag current_ref`
   - `git diff --unified=2 --no-color previous_tag current_ref`
   - optional per-commit patches
4. builds a prompt
5. calls your OpenAI-compatible API
6. returns the generated changelog as Markdown output

This action only **generates** changelog content. It does **not** write files, commit, or push.

## Get started

### Minimal example

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

      - name: Generate changelog
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

### Save to `.github/changelog/<version>.md`

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

A fuller example is in [examples/workflow.yml](examples/workflow.yml).

## Inputs

### Required

| Input | Description |
|---|---|
| `api_endpoint` | OpenAI-compatible Chat Completions endpoint |
| `api_key` | API key sent as `Authorization: Bearer <api_key>` |
| `model` | Model name sent in the request body |

### Optional

| Input | Default | Description |
|---|---:|---|
| `current_ref_override` | `""` | Explicitly set `current_ref` |
| `current_version_override` | `""` | Explicitly set `current_version` |
| `previous_tag_override` | `""` | Use this tag directly and skip automatic previous-tag lookup |
| `temperature` | `0.2` | Sampling temperature |
| `max_diff_bytes` | `200000` | Maximum bytes included for the aggregate diff section |
| `system_prompt` | `""` | Override the built-in system prompt |
| `fetch_remote_refs` | `true` | Fetch tags and remote refs before resolving ranges |
| `include_commit_patches` | `false` | Include per-commit patches in the prompt |
| `debug` | `false` | Enable verbose debug logging |
| `max_prompt_bytes` | `300000` | Soft cap for assembled prompt size |

## Outputs

| Output | Description |
|---|---|
| `markdown` | Final Markdown changelog |
| `current_ref` | Resolved target ref |
| `version` | Resolved version, or empty string |
| `previous_tag` | Resolved previous semver tag |
| `compare_range` | Compare range in `previous_tag..current_ref` form |

## Notes

- Use `actions/checkout@v5` with `fetch-depth: 0`
- If `current_ref` is **not** `release/<version>`, provide either `current_version_override` or `previous_tag_override`
- Full semantics for `current_ref`, `current_version`, `previous_tag`, and Git range choices are documented in [REPO.md](REPO.md)
