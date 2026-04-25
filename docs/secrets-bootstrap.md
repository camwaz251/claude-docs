# Secrets bootstrap pattern

Keep API keys, OAuth tokens, and other secrets **out of your project repos**
without giving up the convenience of a session-local `.env`.

## The pattern

```
┌─────────────────────────────┐         ┌──────────────────────────────┐
│ <your-username>/<project>   │         │ <your-username>/<secrets>    │
│ public OR private           │         │ private                      │
│   .claude/hooks/            │         │   .env                       │
│     session-start.sh        │         │   (KEY=VALUE lines)          │
└──────────┬──────────────────┘         └──────────────┬───────────────┘
           │                                           │
           │  SessionStart hook                        │
           │  clones secrets repo using SECRETS_PAT,   │
           │  copies .env to $CLAUDE_PROJECT_DIR/.env  │
           ▼                                           │
┌─────────────────────────────────────────────────────┘
│ /tmp/secrets/.env  →  ./.env  (gitignored in project repo)
│ Loaded by your project at runtime via dotenv / load_dotenv etc.
└──────────────────────────────────────────────────────
```

Two repos, one PAT, one env var pair set in the Anthropic web UI. Project
repo stays clean.

## Why not just put secrets in the project repo

- **Public projects** can't have any secrets, ever.
- **Private projects** still leak secrets to anyone you grant access — and
  you usually want broader access to the project than you want to the keys.
- **Rotation gets painful** when secrets are versioned in the same history
  as code; you have to rewrite history or live with leaked-key commits.
- A separate repo gives you **one place to rotate** and **one PAT to revoke**
  if anything goes sideways.

## Setup checklist

1. **Create the secrets repo.** Private. Single file `.env` with one
   `KEY=VALUE` per line. No history of keys you don't currently use — when
   rotating, replace in place.

2. **Mint a PAT scoped only to that repo.**
   - GitHub → Settings → Developer settings → Personal access tokens →
     Fine-grained tokens → Generate new token.
   - Repository access: *Only select repositories* → `<your-secrets-repo>`.
   - Permissions: Repository → Contents → **Read-only**. Nothing else.
   - Expiration: short. 30 or 90 days. Calendar-reminder the rotation.

3. **Set environment variables on the Anthropic environment.**
   In the iOS app or `claude.ai/code`, edit your environment and add:
   ```
   SECRETS_PAT  = <the PAT>
   SECRETS_REPO = <your-username>/<your-secrets-repo>
   ```
   These are stored at the environment level and re-injected on every
   session boot — but only into the sandbox, not into git.

4. **Drop the hook into your project.**
   Copy `templates/session-start.with-secrets.sh` from this repo into
   `.claude/hooks/session-start.sh`, plus `templates/settings.json` into
   `.claude/settings.json`. Edit the `PROJECT` name and the TODO tool list.

5. **Gitignore `.env`** in your project repo. (Should already be standard.)

That's it. Next session start, the hook clones the secrets repo, copies the
`.env` into your project root, and your runtime loads it the normal way.

## How the secrets actually reach your code

The hook runs in a **child process** of the agent, so `export`s inside the
hook do not leak back into the agent's environment. Two ways around that,
both implemented in `templates/session-start.with-secrets.sh`:

1. **Copy `.env` to `$CLAUDE_PROJECT_DIR/.env`** (default). Your runtime
   loads it the standard way — `dotenv` in Node, `python-dotenv` in
   Python, `set -a; . ./.env; set +a` in shell. This is the recommended
   path because it doesn't depend on Claude Code internals.

2. **Emit `additionalContext`** with the variable names (not values). The
   `SessionStart` hook can return JSON like
   `{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"loaded SECRETS: FOO_KEY, BAR_TOKEN"}}`
   so the agent sees the names in its initial context. Useful for telling
   the model "yes, BAR_TOKEN is available, use it" without committing the
   list to a file.

## Threat model

What this protects against:
- Accidental commit of `.env` into the project repo (separation of repos
  enforces it).
- Granting collaborators access to the project without granting them keys.
- One leaked key compromising other unrelated systems (still possible if
  you stuff everything into one secrets repo — split by domain if your
  blast radius matters).

What it does **not** protect against:
- A Claude session reading `/tmp/secrets/.env` or `./.env` and surfacing
  values to you in the transcript. The agent has full filesystem access to
  the sandbox VM. Treat anything sourced into the session as visible to
  the model. If a secret must never be model-visible, don't put it in
  `.env` — keep it on the host that calls the API and never expose it to
  Claude Code at all.
- A compromised `SECRETS_PAT` exfiltrating the secrets repo. Use a
  fine-grained PAT with read-only Contents and a short expiry. Rotate on
  any suspicion.
- Leaked Anthropic environment variables. The web UI stores them in
  Anthropic's infrastructure; if you're concerned about that surface, you
  shouldn't be putting secrets in the environment vars at all — use the
  Setup Script field on a desktop-only environment to inject them at boot
  without storing the values in the env panel.

## Rotation runbook

1. Mint a fresh `.env` with new keys.
2. Push to the secrets repo (`git commit -am "rotate keys"; git push`).
3. Revoke the old keys at their respective providers.
4. Next session start in any project — old `.env` is replaced from the new
   secrets-repo content.
5. Mint a new SECRETS_PAT before the old one expires (calendar reminder!).
   Update the env var in Anthropic web UI.
6. Revoke the old SECRETS_PAT.

## When to use Anthropic's Setup Script field instead

If your environment is created via the desktop `claude.ai/code` (not iOS),
the **Setup Script** field is a superior place for the bootstrap commands —
it's cached and rehydrated, so you don't pay the clone cost every session.

Two limitations:

- **iOS-created environments don't expose Setup Script.** This hook is the
  only path on iOS-only environments.
- **Setup Script output is held by Anthropic.** If you'd rather your
  secrets only ever live transiently in `/tmp`, the SessionStart hook
  pattern is preferable even on desktop.
