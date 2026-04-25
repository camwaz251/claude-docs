# Using the vendored Anthropic docs

This repo bundles two community-maintained mirrors of Anthropic's docs as
**git submodules** under `vendor/`. They give you grep-able, locally
readable docs in a Claude Code session without having to authenticate
`WebFetch` calls or pay the round-trip latency.

## What's vendored

| Path | Upstream | Scope |
|---|---|---|
| `vendor/claude-code-docs` | github.com/ericbuess/claude-code-docs | Claude Code CLI: hooks, MCP servers, slash commands, settings, IDE integrations. ~6 MB. Auto-syncs from the official Claude Code documentation. |
| `vendor/claude-wiki` | github.com/johnzfitch/claude-wiki | Broader Anthropic ecosystem in 24 categories: Claude Code, API reference, Agent SDK, MCP, plugins/skills, models, billing, etc. ~28 MB. Refreshed daily, multi-source. |

Both are **read-only mirrors** of upstream docs. Neither holds proprietary
or per-user content.

## Cloning with submodules

```sh
git clone --recurse-submodules https://github.com/<your-username>/claude-docs.git
```

If you cloned without `--recurse-submodules`:

```sh
cd claude-docs
git submodule update --init --recursive --depth 1
```

The `SessionStart` hook in this repo's `.claude/hooks/session-start.sh`
runs the same command on every cloud-session boot, so a fresh sandbox
will have the docs available without manual intervention.

To skip that auto-init (e.g., on a slow link):

```sh
CLAUDE_DOCS_SKIP_SUBMODULES=1 claude
```

## Refreshing the snapshots

Both upstreams self-update daily. To pull a fresh snapshot into this repo:

```sh
git submodule update --remote vendor/claude-code-docs vendor/claude-wiki
git add vendor/claude-code-docs vendor/claude-wiki
git commit -m "vendor: bump submodules to $(date -u +%Y-%m-%d) snapshot"
git push
```

A weekly bump is plenty for most workflows.

## Searching the vendored docs from a Claude session

```sh
# Find every page that mentions SessionStart hooks
rg -i 'SessionStart' vendor/

# Read a specific page
cat vendor/claude-wiki/07-Hooks/SessionStart.md

# Quick directory tour
ls vendor/claude-wiki/
ls vendor/claude-code-docs/docs/
```

In a Claude Code session attached to this repo, the agent can `Read`,
`Grep`, or use the `Explore` agent against `vendor/` directly — no
network round trip, no authenticated fetch.

## When NOT to use the vendored copy

- **When you need today's bleeding-edge changes.** The submodule pointer
  is whatever was committed last; both upstreams may have moved since.
  Run a refresh, or hit `docs.claude.com` / `docs.anthropic.com` directly
  via `WebFetch`.
- **When upstream's structure has shifted** since the last refresh. Cross-
  check against the live URLs before quoting.

## Caveats

- **Submodules on iOS `lg2` are flaky.** If you've cloned this repo into
  a-Shell, `lg2` may not init nested submodules cleanly. Fall back to
  reading the docs via the GitHub web UI on the phone, or only do
  submodule work from the Claude Code cloud surface.
- **Total size with both submodules** is ~35 MB, mostly markdown. Trivial
  on a cloud sandbox; noticeable on iCloud Drive if you're sync-conscious.
