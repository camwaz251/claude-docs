# Claude Code Cloud — Environment Reference

A general-purpose cheat sheet for what the **Claude Code remote/cloud** sandbox
gives you (the VM Anthropic spawns when you start a session from the iOS app or
`claude.ai/code`). Project-agnostic — drop this URL in any repo's `CLAUDE.md`
and feed it to the assistant so it knows what's available.

> Captured from a live session on 2026-04-25. Re-verify with `uname -a` and
> `cat /etc/os-release` if anything looks off — Anthropic updates the image.

---

## TL;DR

- **Firecracker microVM**, fresh per session, **destroyed when the session ends**.
- You're **root**, but `IS_SANDBOX=yes` — no escape, no inbound ports, no GPU.
- **Full outbound HTTPS** (GitHub, PyPI, npm, Anthropic, most of the public internet).
- **Persistent state lives only in the git repo** that's checked out (and pushed).
- Heavy toolchain pre-installed; `apt`, `pip`, `npm`, `cargo`, `go install`, `bun add` all work.

---

## Persistence model (verified empirically 2026-04-25)

A two-session probe (two sister sessions bound to the same `Unrestricted`
environment) confirmed:

- **Each session is a brand-new microVM.** Different `CLAUDE_CODE_CONTAINER_ID`,
  fresh `/proc/uptime`, no shared filesystem.
- **Same environment ≠ shared anything except** the env vars you set in the
  iOS/web *Environment variables* box, the network-access policy, and the
  base image (the `ANT_IMAGE_REPOSITORY=sandbox-ccr-default` tag in effect at
  session start).
- **`/etc/machine-id` is baked into the image** — every spawned VM has the
  *same* machine-id. Don't use it as a uniqueness signal; use
  `CLAUDE_CODE_CONTAINER_ID` or boot time.
- **Nothing you `apt-get install` or `pip install` survives** the session
  unless you've configured a **Setup Script** on the environment in the web
  UI (`claude.ai/code`). Setup Script output *is* cached and rehydrated; the
  iOS app's *New environment* form does **not** expose this field, so an
  iOS-only environment effectively has a no-op setup and starts cold every
  time.
- **`/tmp` is empty at session start** even within the same environment.
- **GitHub is reached via a local HTTP proxy**
  (`http://local_proxy@127.0.0.1:<port>/git/<owner>/<repo>`). Anthropic's
  proxy holds the token; the agent never sees your PAT. This is why
  `gh` CLI is not the right path here — use the GitHub MCP server
  (`mcp__github__*` tools) for repo ops.
- **Repos are checked out in detached-HEAD** even when the iOS UI shows a
  branch name. Pushes still go to the named branch via the proxy.

### Picking a bootstrap layer

| Need | Right layer |
|---|---|
| Same heavy tools across every project (ffmpeg, yt-dlp, whisper) | Setup Script on the environment (web UI only) |
| Per-project install (`pip install -r requirements.txt`, `npm install`) | `.claude/settings.json` SessionStart hook in the repo |
| Secrets / API keys / SSH key material | Environment variables on the environment |
| Ephemeral scratch space | `/tmp` (gone next session) |
| Anything you want to survive | git commit + push |

> **iOS workaround:** since the iOS app can't add a Setup Script, anything
> you'd put there has to live in a SessionStart hook instead — pay the install
> cost every session, or open the environment on a desktop browser to add the
> script.

---

## Hardware & OS

| | |
|---|---|
| OS | Ubuntu 24.04 LTS (Noble), kernel 6.18.x |
| Arch | x86_64, Intel Xeon @ 2.10 GHz, AVX-512 + AMX |
| vCPU | 4 |
| RAM | ~15 GiB, **no swap** |
| Disk | 252 GB volume, ~30 GB free on `/`, plus 7.9 GB tmpfs on `/dev/shm` |
| GPU | **None** — no CUDA, no `nvidia-smi`. Don't plan local-LLM/training work. |
| Hypervisor | KVM (Firecracker) |
| Hostname | `vm` |
| User | `root` (uid 0). `/home/claude` and `/home/user` also exist. |
| Timezone | UTC |

---

## Filesystem layout

```
/home/user/<repo>/        # your checked-out project, cwd at start
/home/claude/             # claude user's home (mostly unused)
/root/                    # your real $HOME — bash/zsh, dotfiles, .claude/
/opt/                     # vendored toolchains (see below)
/tmp/                     # ephemeral, large
/dev/shm/                 # 7.9 GB tmpfs, fast scratch
```

**Persistence rule:** anything outside the git repo evaporates at session end.
If you want it to survive, commit and push it.

---

## Pre-installed languages

| Tool | Version / location |
|---|---|
| Python | 3.11.x at `/usr/local/bin/python3` |
| Node | 22 at `/opt/node22/bin/node` (also `/opt/node20`, `/opt/node21`, `nvm`) |
| Bun | `/root/.bun/bin/bun` |
| Rust | stable via rustup (`/root/.cargo/bin/{rustc,cargo}`) |
| Go | `/usr/local/go/bin/go` |
| Java | OpenJDK 21 at `/usr/lib/jvm/java-21-openjdk-amd64` |
| Ruby | 3.1, 3.2, 3.3 via rbenv at `/opt/rbenv` |
| C/C++ | gcc, g++, make, cmake, autoconf, automake, pkg-config |

## Pre-installed tooling

- **Build:** Maven 3.9, Gradle 8.14, Conan 2.27
- **Browsers:** Playwright + browsers cached at `/opt/pw-browsers`, chromedriver
- **Web dev:** TypeScript, ts-node, Prettier, ESLint, http-server, serve, nodemon
- **Misc CLIs:** git, jq, ripgrep (`rg`), curl, wget, vim, nano, tmux, openssl, gdb, valgrind, strace, psql, redis-cli
- **Claude Code itself:** `/opt/claude-code/bin/claude` (v2.x, single ~245 MB binary)

## Notably **missing** from the default image

You'll often want to `apt-get install -y` these:

- `ffmpeg`, `yt-dlp` / `youtube-dl` — for any media pipeline
- `imagemagick` (`convert`/`magick`), `tesseract-ocr`, `poppler-utils` (`pdftotext`)
- `pandoc`, `ghostscript`
- `htop`, `tree`, `nmap`, `tcpdump`, `socat`, `shellcheck`, `fd-find`, `bat`
- `sqlite3`, `mysql-client`
- Cloud CLIs: `awscli`, `gcloud`, `azure-cli`, `terraform`, `ansible`
- `lg2` (iOS-only — fall back to plain `git` here)

`docker` **CLI** is installed but **the daemon is not running** and can't be
started in the sandbox. Use it only for parsing `Dockerfile`s, not for running
containers.

---

## Network

- DNS: `8.8.8.8`
- Outbound: HTTPS works to anything public — verified github.com, anthropic.com,
  pypi.org, registry.npmjs.org all return 200.
- Outbound HTTP traffic is routed through Anthropic's egress proxy
  (`http.proxyAuthMethod = basic` is preset in `~/.gitconfig`); CA bundle at
  `/etc/ssl/certs/ca-certificates.crt` is wired via `NODE_EXTRA_CA_CERTS` and
  `REQUESTS_CA_BUNDLE`. The proxy presents a self-signed chain — tools that
  use their own bundled CA store (notably `yt-dlp`) need
  `--no-check-certificate` to talk to the public internet through it.
- Egress NATs out from a stable Anthropic-managed IP; don't rely on a session
  having a unique outgoing address.
- Inbound: **no public ingress**. You can run `python -m http.server 8000`
  locally and hit it with curl in the same VM, but no one outside can reach it.
- `ss` is **not** installed; use `ip` (`ip -br addr`, `ip route`).

---

## Identity & secrets

- Git is preconfigured as `Claude <noreply@anthropic.com>` with SSH commit
  signing through `/tmp/code-sign`.
- `~/.ssh` is empty by default — no key for arbitrary `git@` remotes. GitHub
  access goes through the **GitHub MCP server** (tools prefixed `mcp__github__`),
  scoped to whichever repo Anthropic attached to the session.
- The session has its own OAuth token mounted via file descriptor — do not try
  to read or print it.
- Useful env vars to know:
  - `CLAUDECODE=1`, `IS_SANDBOX=yes`, `CLAUDE_CODE_REMOTE=true`
  - `CLAUDE_CODE_REMOTE_ENVIRONMENT_TYPE=cloud_default`
  - `CLAUDE_CODE_VERSION` — the agent build
  - `CLAUDE_CODE_SESSION_ID` — handy for log correlation
  - `MAX_THINKING_TOKENS=31999`

---

## What you actually can / can't do

### ✅ Yes
- Heavy compiles (Rust, Go, large npm installs) — 4 cores + 15 GiB RAM
- Headless browser automation (Playwright already has browsers cached)
- Pull/push to the attached GitHub repo via MCP tools
- Download big files into `/tmp` or `/dev/shm`
- Spin up local servers and hit them with curl
- Install extra apt/pip/npm/cargo/go packages freely
- Run long-running tasks via `Bash(run_in_background: true)` and stream with `Monitor`

### ❌ No
- **No GPU / CUDA** — anything needing nvidia drivers is out
- **No Docker daemon, no nested VMs, no systemd**
- **No inbound network** — can't expose a public URL from this VM
- **No persistence** between sessions outside committed git state
- **No access to other GitHub repos** beyond the one the MCP server is scoped to
- **No SSH out to arbitrary hosts** (no keys, sandbox blocks it)

---

## Quick install snippets

```bash
# Common one-liners
apt-get update && apt-get install -y ffmpeg imagemagick tesseract-ocr poppler-utils jq tree htop

# Python media stack
pip install yt-dlp openai-whisper pillow

# Node tooling
npm i -g vercel netlify-cli wrangler

# Cloud CLIs
curl -sSL https://sdk.cloud.google.com | bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscli.zip && unzip -q awscli.zip && ./aws/install
```

Remember: every install dies with the VM. For repeat workflows, script the
install in a `SessionStart` hook (see `templates/` in this repo) or — if your
environment is set up via the desktop web UI — paste the install commands
into the **Setup Script** field so the result is cached.

---

## Tips for feeding this into a new session

1. Cross-link this file from any repo's `CLAUDE.md`:
   ```
   See https://github.com/<your-username>/claude-docs/blob/main/cloud-environment.md
   for what's pre-installed in the Claude Code cloud sandbox.
   ```
2. Or paste the **TL;DR** section directly into your project's `CLAUDE.md` so
   it loads automatically with every prompt.
3. If you're unsure the image still matches this doc, ask the assistant to
   run `uname -a; cat /etc/os-release; df -h /; free -h` and reconcile.

---

*Generated from a live recon of the Claude Code cloud sandbox on 2026-04-25.
Anthropic may rev the image; treat versions as approximate.*
