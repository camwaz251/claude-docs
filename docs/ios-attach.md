# Attaching the iOS Claude Code app to a repo

There are two distinct iOS surfaces that can edit a repo, with very
different auth models. Pick the right one for the job.

## Surface 1: iOS Claude Code app (cloud sandbox)

The first-party iOS app. Spawns a Firecracker microVM in Anthropic's cloud
on demand. Reads/writes the repo via the **GitHub MCP server** with a token
Anthropic holds — **you never paste a PAT into the app**.

### Setup

1. Open the Claude app → Code tab → New environment.
2. Choose *Connect a GitHub repo*. Authenticate the GitHub connector if
   prompted (one-time per GitHub account).
3. Pick the repo you want to attach.
4. Optional: in the environment settings, add Environment Variables (e.g.
   `SECRETS_PAT`, `SECRETS_REPO` for the secrets-bootstrap pattern).
5. Optional: pick a network policy (`Restricted` or `Unrestricted`).
   `Unrestricted` is needed for `apt-get`, `pip install`, etc.

### Caveats

- **No Setup Script field on iOS.** The desktop `claude.ai/code` exposes a
  Setup Script that runs once and caches its output — the iOS *New
  environment* form doesn't. Use a `SessionStart` hook in the repo
  (see `templates/`) to bootstrap deps every session instead.
- **No persistence** outside the git repo. `/tmp/`, installed packages,
  whisper models — all gone next session.
- **The GitHub MCP server is scoped** to the single repo Anthropic
  attached. A session attached to repo A cannot read or write repo B.

### When to use it

Almost always, for editing one repo from your phone. No PAT to manage,
no key rotation, full Linux toolchain, push goes through Anthropic's
proxy directly.

## Surface 2: a-Shell + lg2 (iCloud Drive sandbox)

For repos you want to keep an iCloud-Drive-synced working copy of —
typically because another iOS app reads the files (e.g. an editor app, a
recipe app, a notes app). a-Shell is a free terminal app for iOS with a
bundled `lg2` (libgit2 CLI).

### Setup

1. Install **a-Shell** from the App Store.
2. In a-Shell:
   ```sh
   pickFolder           # browse to where you want the repo, then "Open"
   lg2 clone https://github.com/<your-username>/<your-repo>.git
   ```
3. Mint a fine-grained PAT scoped only to that one repo:
   - GitHub → Settings → Developer settings → Personal access tokens →
     Fine-grained tokens → Generate new token.
   - Repository access: *Only select repositories* → `<your-repo>`.
   - Permissions: Repository → **Contents: Read and write**.
   - Expiration: 90 days. Calendar-reminder the rotation date.
4. Store the PAT in `~/Documents/.gitconfig` (a-Shell-local, NOT iCloud):
   ```sh
   cat >> ~/Documents/.gitconfig <<EOF
   [user]
       email = your-email@example.com
       name = Your Name
       password = <PAT>
   EOF
   chmod 600 ~/Documents/.gitconfig
   ```

### a-Shell quirks

- No `bash`. Use `sh` / `dash` syntax.
- No `hostname` command. Use `uname -n`.
- `$HOME` is sandboxed read-only — log files go in the repo, not `~`.
- `lg2 fetch` needs an explicit URL, not a remote name.
- `lg2 push` needs `refs/heads/main:refs/heads/main`, not bare `main`.
- After `lg2 init`, HEAD is detached — `lg2 branch main HEAD` then check
  out `main` before pushing.

### When to use it

Only when you specifically need an iCloud-resident working copy because a
non-Claude iOS app on your phone reads the files. Otherwise, surface 1 is
strictly easier.

## Both surfaces on the same repo

Common when you want phone editing in two contexts (Claude cloud for code
work, a-Shell for quick `git pull` / `git status` / running scripts that
touch iCloud-resident assets).

Coordination tips:

- **GitHub `main` is the source of truth.** Both surfaces push to and pull
  from `main`. Conflicts are rare in solo workflow because each surface
  usually edits different files.
- **Run a sync after editing on either surface, before opening the other.**
  - On the cloud surface, the GitHub MCP push is automatic.
  - On a-Shell, run `lg2 commit -am "..." && lg2 push origin refs/heads/main:refs/heads/main`.
- **Hydrate iCloud placeholders** before `lg2 add` — iCloud may have
  evicted files locally. `cat` each file first or use a small script that
  does so.

## PAT rotation

If you used surface 2, set a calendar reminder for **PAT expiry minus
7 days**. When it fires:

1. Mint a new fine-grained PAT, same scope.
2. Update `~/Documents/.gitconfig` with the new token.
3. Revoke the old token at github.com/settings/tokens.

If you only use surface 1, no PAT rotation — Anthropic's GitHub connector
handles it.
