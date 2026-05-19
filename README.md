# claude-docs

A small public reference repo for using **Claude Code** — especially the
**cloud / phone-driven** flavour (the iOS app and `claude.ai/code`).

What you'll find here:

- **`cloud-environment.md`** — what the Anthropic cloud sandbox actually
  gives you: Firecracker microVM, persistence rules, what's pre-installed,
  network egress proxy quirks, the GitHub MCP boundary. Empirically captured,
  not guessed.
- **`templates/`** — drop-in `SessionStart` hook + `.claude/settings.json`
  wiring for any new repo. Two flavours: `basic` (just bootstrap missing
  tools) and `with-secrets` (also clones a private secrets repo and sources
  its `.env`).
- **`docs/secrets-bootstrap.md`** — pattern doc for keeping API keys out of
  your project repos by stashing them in a separate private repo and pulling
  them in at session start.
- **`docs/ios-attach.md`** — checklist for attaching the iOS Claude Code app
  (and a-Shell `lg2`) to a repo, including PAT scoping.
- **`docs/using-vendor-submodules.md`** — how to read the bundled Anthropic
  docs without authenticated `WebFetch`.
- **`docs/sandbox-security-analysis.md`** — from-the-inside security review
  of the cloud sandbox: Firecracker microVM boundary, capability/seccomp
  posture, TLS interception by Anthropic's egress proxy, threat model.
  Useful as input for an adoption / risk review.
- **`docs/sandbox-recon-runbook.md`** — reproducible checklist of the
  exact probes that produced the security analysis. Hand to a future
  Claude session (or a colleague) to rerun the recon end-to-end.
- **`docs/sandbox-recon.sh`** — scripted version of the runbook. Emits
  a diff-friendly report tagged stable / variable / per-session, so two
  sessions can be `diff`ed to see what actually changes per VM.
- **`docs/sandbox-recon-baseline.txt`** — saved output of
  `sandbox-recon.sh` (safe mode) from one session, kept as a known-good
  reference. Run the script in a future session and
  `diff -u docs/sandbox-recon-baseline.txt /tmp/new.txt` to see what
  drifted.
- **`docs/sandbox-recon-rerun.txt`** — second snapshot, captured after a
  VM rotation inside the same iOS chat thread. Diff against the baseline
  to see exactly what changes when the platform reschedules you onto a
  fresh host (spoiler: only `:V`/`:P` blocks — CPU SKU, microcode
  mitigation strings, broker port, uptime).
- **`vendor/`** — Anthropic's docs as **git submodules**:
  - `vendor/claude-code-docs` → `ericbuess/claude-code-docs` (Claude Code CLI)
  - `vendor/claude-wiki` → `johnzfitch/claude-wiki` (broader Anthropic ecosystem)

  Both upstreams refresh daily. Run `git submodule update --remote` to pull
  new snapshots.

## Using this repo from another project

Two common patterns:

1. **Cross-link from your project's `CLAUDE.md`:**

   ```markdown
   See https://github.com/<your-username>/claude-docs/blob/main/cloud-environment.md
   for what's pre-installed in the Claude Code cloud sandbox.
   ```

   Zero coupling. Your Claude session fetches the URL on demand.

2. **Copy a template into a new repo:**

   ```sh
   curl -fsSL https://raw.githubusercontent.com/<your-username>/claude-docs/main/templates/settings.json \
     -o .claude/settings.json
   curl -fsSL https://raw.githubusercontent.com/<your-username>/claude-docs/main/templates/session-start.basic.sh \
     -o .claude/hooks/session-start.sh
   chmod +x .claude/hooks/session-start.sh
   ```

   Then edit the `TODO` block at the top of the hook to list your
   project's apt/pip dependencies.

## Cloning this repo

If you want the vendored docs available locally:

```sh
git clone --recurse-submodules https://github.com/<your-username>/claude-docs.git
```

If you forgot `--recurse-submodules`, run:

```sh
git submodule update --init --recursive --depth 1
```

The `SessionStart` hook in `.claude/hooks/session-start.sh` does this for you
when a Claude Code session starts in this repo.

## License

The user-authored content (`README.md`, `CLAUDE.md`, `cloud-environment.md`,
`docs/`, `templates/`, the wrapper hook) is offered under the MIT terms in
`LICENSE`.

The `vendor/` submodules are independent third-party repos with their own
licenses — see each one's `LICENSE` file.
