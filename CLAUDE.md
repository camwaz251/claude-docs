# claude-docs — Project Instructions

## What this repo is

A small **public** reference repo for Claude Code workflows, especially
phone-driven cloud sessions. It holds:

- A canonical sandbox cheat sheet (`cloud-environment.md`)
- Two `SessionStart` hook templates (`templates/session-start.*.sh`)
- Pattern docs (`docs/secrets-bootstrap.md`, `docs/ios-attach.md`,
  `docs/using-vendor-submodules.md`)
- Anthropic's docs as **read-only submodules** under `vendor/`

It is consumed by other projects two ways:
1. As a URL the agent `WebFetch`es on demand, or
2. As a `git clone --recurse-submodules` into a session that wants the
   vendored Anthropic docs available locally.

## Rules for any Claude session attached here

1. **Public + agnostic.** Treat every committed file as readable by anyone on
   the internet. Never paste:
   - Secrets, API keys, OAuth tokens, PATs
   - Personal usernames, repo names, machine IDs, container IDs, or IPs
   - Specific paths from another project (CookLang, FinanceApp, etc.)

   Where an example needs a placeholder, use angle-bracket form like
   `<your-username>/<your-repo>` or `<your-secrets-repo>`.

2. **What to edit:**
   - `README.md`, `CLAUDE.md`
   - `cloud-environment.md`
   - Anything under `docs/`
   - Anything under `templates/`
   - `.claude/settings.json` and `.claude/hooks/session-start.sh`
     (these wire up *this* repo's submodule init — don't use them as a
     project template; the templates in `templates/` are the public versions)

3. **What NOT to edit:**
   - **Anything under `vendor/`.** These are submodules pinned to upstream
     repos. To refresh them, run
     `git submodule update --remote vendor/<name>` and commit the new
     submodule pointer — never edit the contents inline.
   - `.gitmodules` unless adding/removing a submodule deliberately.

4. **Adding new content:**
   - Prefer adding to an existing doc over creating a new top-level file.
     This repo is meant to scan in one minute.
   - If you must add a new doc, put it under `docs/` and link it from
     `README.md`.
   - Always sanity-check: would this be useful in *any* project, or is it
     specific to one app? Specifics belong in that app's own repo.

5. **Don't add scripts that need API keys** to run. The whole point is that
   any reader can clone this and use it without provisioning anything.

6. **Commit style.** Keep messages short and present-tense:
   - `docs: clarify egress proxy CA bundle path`
   - `templates: add Node-flavoured comment to basic hook`
   - `vendor: bump claude-wiki to 2026-04-25 snapshot`

7. **Branches and PRs.** Direct commits to `main` are fine for typo fixes,
   doc clarifications, and submodule bumps. Use a short-lived branch for
   anything that touches the templates or restructures `docs/`.

## Refreshing the vendored Anthropic docs

```sh
git submodule update --remote vendor/claude-code-docs vendor/claude-wiki
git add vendor/claude-code-docs vendor/claude-wiki
git commit -m "vendor: bump submodules to $(date -u +%Y-%m-%d) snapshot"
```

Both upstreams self-update daily, so a weekly bump is plenty.

## Verifying agnosticism before commit

```sh
# Should print nothing — names, IPs, machine IDs all stripped.
grep -RIn -E '(camwaz|cooklang|financeapp|homeneeds|34\.57\.|machine_id|container_id)' \
  --exclude-dir=vendor --exclude-dir=.git .
```

If it prints anything, either redact it or move it back to the project repo
where it belongs.

## SessionStart hook

`.claude/hooks/session-start.sh` runs on every cloud-session boot for *this*
repo and does two things only:

1. `git submodule update --init --recursive --depth 1` so `vendor/` is
   readable on the freshly-spawned VM.
2. Echo a one-line confirmation.

Set `CLAUDE_DOCS_SKIP_SUBMODULES=1` to skip the init (e.g., on a slow link
or when you only want the user-authored docs).
