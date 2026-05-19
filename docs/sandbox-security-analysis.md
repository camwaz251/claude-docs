# Sandbox Security Analysis — Claude Code on the Web

A from-the-inside review of the per-session sandbox Anthropic provisions for
Claude Code remote sessions. Captured from a live session on 2026-05-17, then
sanitised for public posting.

This doc complements [`cloud-environment.md`](../cloud-environment.md) — that
one is the developer cheat sheet ("what's pre-installed, what works"). This
one is the security view: isolation primitives, network architecture, TLS
posture, what an attacker could do from inside, and what the platform itself
can do to the user.

Treat it as a snapshot. Anthropic can rev the runtime, and individual
*network-access policies* (chosen when the environment is created) change the
egress shape. Re-verify with the commands below before relying on any
specific value.

## TL;DR

1. **Each session is its own Firecracker microVM**, not a shared container.
   Per-session KVM guest with a custom Anthropic-built kernel and a
   control-plane PID 1 (`process_api`). The isolation boundary is a
   hypervisor, not a kernel namespace.
2. **Inside the guest the agent is root with almost full Linux capabilities,
   no seccomp filter, unconfined AppArmor.** The interior is intentionally
   permissive — the boundary is the VM, not the container's capability
   profile.
3. **All TLS egress is intercepted** by an Anthropic-owned root CA
   (`O=Anthropic, CN=sandbox-egress-production TLS Inspection CA`) preloaded
   into the system trust store. Every byte the agent sends to the public
   internet is decryptable by Anthropic at the proxy.
4. **Egress is L7-only**: only TCP/80 and TCP/443 reach the outside, and
   both go through the inspecting proxy. Cloud metadata is unreachable,
   IPv6 disabled, raw outbound TCP to non-web ports blocked.
5. **GitHub access is brokered** through an MCP server holding the token
   server-side; the agent never sees the PAT and is scoped to a single
   repo at provision time.
6. **No persistent state survives the session** outside `git push`. The
   VM is destroyed on timeout.

## Probe methodology

Read-only fingerprinting from within a normal interactive session, using
standard userland tools available in the base image (`curl`, `openssl`,
`ip`, `ss`, `/proc/*`, `/sys/*`, `dmesg`). No exploitation attempted, no
aggressive probing of control-plane endpoints. Every finding below can be
reproduced with one shell command — they're shown inline so a future
reviewer can confirm them.

## Architecture: per-session microVM

Evidence the boundary is a hypervisor, not a kernel namespace:

```sh
$ cat /proc/cmdline
console=ttyS0 reboot=k panic=1 nomodule random.trust_cpu=1 ipv6.disable=1
swiotlb=noforce rdinit=/process_api init_on_free=1 -- --firecracker-init
--addr 0.0.0.0:2024 --max-ws-buffer-size 32768 --block-local-connections

$ dmesg | grep Hypervisor
[    0.000000] Hypervisor detected: KVM

$ cat /proc/1/comm
process_api

$ ls /.dockerenv /run/.containerenv 2>&1
ls: cannot access ...: No such file or directory
```

Interpretation:

- The kernel boots a custom Anthropic init binary (`process_api`) directly
  via `rdinit=`, not `systemd` or `init`. It takes Firecracker-style flags.
- The absence of `/.dockerenv` / `/run/.containerenv` and the presence of
  `--firecracker-init` confirm this is a microVM, not a container, even
  though `systemd-detect-virt` reports `docker` (it's matching on cgroup
  paths, which microVMs also use).
- The cmdline carries non-trivial hardening flags:
  - `nomodule` — kernel modules can't be loaded at runtime
  - `init_on_free=1` — freed memory is zeroed (reduces infoleak surface)
  - `panic=1 reboot=k` — panics force immediate reboot, no panic shell
  - `ipv6.disable=1` — entire v6 stack disabled (confirmed: no v6 iface)
  - `swiotlb=noforce` — bounce-buffer DMA off (no PCI passthrough exists)
- `--block-local-connections` on process_api suggests the init also blocks
  intra-guest connections to its own control surface from non-loopback.

The kernel is a custom Anthropic build (visible in `uname -v` / `dmesg`),
not stock Ubuntu. No kernel modules are loaded.

Firecracker is the same isolation primitive AWS Lambda and Fly.io use in
production; it has a small audited attack surface compared to a stock
Linux-namespace container.

## Guest interior — deliberately permissive

```sh
$ id
uid=0(root) gid=0(root) groups=0(root)

$ grep -E 'Seccomp|CapEff|NoNewPrivs' /proc/self/status
CapEff:      000001fffeffffff     # all caps except cap_sys_resource
NoNewPrivs:  0                    # SUID escalation paths work
Seccomp:     0                    # no seccomp filter active

$ cat /proc/self/attr/current
kernel                            # AppArmor: unconfined

$ getenforce 2>/dev/null
(no SELinux)
```

Inside the VM:

- Almost full Linux capability set.
- No seccomp filter at all — every syscall is reachable.
- No AppArmor profile applied.
- No SELinux.
- SUID binaries (`sudo`, `su`, `mount`, `passwd`, …) are present and work.

For a normal Docker container these would be alarming defaults. For a
single-tenant microVM they're deliberate: the *guest kernel* is the
attack surface, and a kernel exploit inside the guest still has to
escape the hypervisor — Firecracker's job — to reach anything Anthropic
cares about.

Practical implication: **don't trust anything inside the guest.** Anyone
who can ship code into your session (you, the model, a dependency you
`pip install`) gets root inside that VM. The guarantee is "can't affect
other tenants or persistent state," not "can't do anything."

## Network architecture

### Egress shape

Port matrix to a known public host:

```
22:  blocked      443:  open
25:  blocked      587:  blocked
80:  open         993:  blocked
                  3306: blocked
                  5432: blocked
                  6379: blocked
                  8080: blocked
                  8443: blocked
```

- Only TCP/80 and TCP/443 reach the outside.
- No raw outbound TCP to e.g. `8.8.8.8:53`, even though `/etc/resolv.conf`
  points there. DNS resolution *does* succeed, so the data path is
  plausibly: resolver lookup → process_api → forwarded out.
- The IPv4 route table inside the guest (`ip route`) is **empty**.
  Networking is almost certainly terminated in `process_api` and proxied
  out at L7, not bridged at L3.
- IPv6 disabled at the kernel.
- ICMP not available (`ping` not installed, and egress is L4-mediated).
- Cloud metadata addresses (`169.254.169.254`,
  `metadata.google.internal`) unreachable — important, since metadata
  endpoints are a frequent pivot in SSRF-style exfiltration.
- The `iptables` INPUT/FORWARD chains are visible but empty inside the
  guest, which is consistent with filtering happening *outside* the VM,
  not inside it.

### TLS interception — the most important finding

```sh
$ echo | openssl s_client -connect github.com:443 -servername github.com \
    2>/dev/null | openssl x509 -noout -issuer -subject
issuer = O = Anthropic, CN = sandbox-egress-production TLS Inspection CA
subject = CN = github.com
```

Every HTTPS connection from the sandbox terminates at an Anthropic-operated
proxy that re-signs the leaf cert with a private Anthropic root CA. That CA
is preloaded into the guest's system trust bundle, and the relevant runtime
env vars are wired to pick it up:

```sh
$ env | grep -i CA
NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt
REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
```

So curl, Python (requests), Node, Go, et al. all silently trust the
proxy's substituted certificate. The same was true for arbitrary hosts —
`example.com`, `pypi.org`, third-party APIs — not just Anthropic-owned
destinations.

What this means in plain language:

- **Anthropic can decrypt, log, and inspect every byte the agent sends to
  the public internet,** including request bodies, headers, response
  contents, OAuth tokens you fetch, API keys you POST, etc.
- This is consistent with what a responsible AI-agent operator has to do
  — detect abuse, prevent data exfiltration, enforce egress policy. It
  is not in itself "secretly malicious." But it *is* a meaningful trust
  handoff and any external security reviewer should record it
  explicitly.
- Tools that pin certificates or ship their own CA bundle (`yt-dlp`,
  some Go binaries compiled without system roots, mTLS clients) will
  reject the proxy and need explicit configuration.
- The CA's `sandbox-egress-production` naming hints at a separate CA per
  environment tier; assume each tier has its own proxy fleet and its
  own logs.

## Identity, secrets, and GitHub

- The guest has its own user namespace; the "root" inside is
  namespace-root, not host-root.
- `/etc/passwd` is the standard Ubuntu set plus a `claude` service user
  (uid 999). No surprise tenants.
- GitHub access is brokered through an MCP server (`mcp__github__*`
  tools) that holds the user's token server-side. The agent never sees
  the PAT and cannot reach repos outside the one scoped at provision
  time.
- An OAuth-style session token is mounted via file descriptor, out of
  the agent's normal reach.
- `git push` traffic goes through `http://local_proxy@127.0.0.1:<port>/`
  — a local helper that re-authenticates against GitHub on the agent's
  behalf, so the credential never lands in `.gitconfig` or the URL
  visible to the model.

## Persistence and isolation between sessions

- Disk: ~252 GB ext4, single block device, fresh per VM.
- RAM: ~15 GiB, no swap, reclaimed on VM destruction.
- `/tmp` and `/dev/shm` are clean at boot.
- A **Setup Script** (web UI only) can run before the agent starts and
  produces a cached layer — that's the only thing that crosses sessions
  unless you `git push`.
- Sister sessions in the same environment share **nothing** at the
  filesystem level. The only shared inputs are: env vars set on the
  environment, the network-access policy, and the base image tag.

### Chat session ≠ VM session

An important detail for anyone using the iOS or web app: **a single chat
thread can outlive the VM that started it.** If you let a chat go idle
for long enough the VM is reclaimed; the next message you send to the
same chat spawns a *new* microVM, restores the conversation transcript
into it, and resumes — you (the human) never see the seam.

What this means in practice:

- The agent's memory of *what was said* persists across VM rotations
  (it's stored on Anthropic's side, not in the VM).
- The VM's filesystem, processes, open ports, and any unpushed work
  do *not* persist. The agent picks up in the new VM with an empty
  `/tmp`, a re-cloned repo, and zero installed-via-`apt` state.
- The SessionStart hook fires *again* on resume — that's how the
  vendored submodules and any custom bootstrap come back up.
- Two consecutive runs of `sandbox-recon.sh` inside one chat thread
  can land on different physical hosts. Observed empirically: same
  kernel/OS/policy/CA, but different CPU SKU and different microcode
  mitigation strings. See
  [`sandbox-recon-baseline.txt`](sandbox-recon-baseline.txt) vs
  [`sandbox-recon-rerun.txt`](sandbox-recon-rerun.txt) — 8/200 lines
  drift, all in `:V`/`:P` blocks, zero `:S` drift.

Security implication: anything an attacker tries to *land* in the VM
(reverse shell, cron, modified `.bashrc`) dies on the next VM rotation.
Anything the attacker has already pushed to the repo, sent over the
network, or returned to the chat transcript persists.

## Threat model

### What an attacker inside one session *cannot* do

- Escape to the host or to another tenant's session (Firecracker is
  the boundary).
- Read or modify another tenant's code, secrets, or filesystem.
- Reach cloud metadata or internal infrastructure (egress is HTTPS-only,
  metadata IPs blocked).
- Open an inbound port reachable from the public internet. (You *can*
  bind to `0.0.0.0:8080` — the kernel allows it — but nothing routes
  to that port from outside the VM.)
- Persist anything outside `git push`. Crontabs, SUID droppers, and
  cached creds die with the VM.
- Exfil the user's GitHub PAT — it lives in the MCP broker.
- Reach repositories outside the one scoped at provision time.

### What an attacker inside one session *can* do

- Anything they want inside the guest: arbitrary syscalls, full root,
  raw sockets within the guest's net ns, write to the working tree.
- Make outbound HTTPS to attacker-controlled hosts on TCP/443. This is
  the dominant exfiltration channel — restricting it would break the
  product (the agent has to fetch docs, packages, npm modules). The
  TLS-inspecting proxy is the mitigation.
- Push commits to the attached repo, if the agent has been instructed
  to push.
- Burn the user's compute by running expensive jobs in the background.

### What the platform itself can do *to* the user

The honest half of the model — what trust the user grants by using the
service at all:

- Read everything in the working tree (it's mounted into a VM the
  platform controls).
- Read everything sent over HTTPS (TLS interception is in place).
- Read every shell command and tool call the agent runs.
- Push commits on the user's behalf via the MCP broker, scoped to the
  attached repo.

None of this is hidden — the egress CA is observable to any user, the
MCP scope is enforced, the persistence model is documented. It is,
however, a non-trivial set of grants. A reviewer evaluating this for
regulated workloads (PHI, PCI, code under NDA, customer PII) should
weigh those grants against their own controls.

## Practical recommendations

For an organisation evaluating Claude Code on the Web:

1. **Treat the sandbox like a third-party SaaS that sees plaintext
   request bodies.** If you wouldn't run that data through a SaaS DLP
   gateway, don't run it through this agent.
2. **Pin the GitHub token to least-privileged scopes.** The MCP broker
   enforces *repo* scope, but the underlying PAT's *permission* scope
   still determines what the agent can do inside that repo.
3. **Use a Setup Script (web UI) for trusted tooling.** Don't rely on
   `apt install` of untrusted packages every session — that's a fresh
   supply-chain risk each time.
4. **Don't paste secrets into prompts.** Use the environment-variables
   feature so the secret enters the VM out-of-band, then the agent
   reads from `env`.
5. **Monitor outbound HTTPS to `*.anthropic.com` at your network edge**
   if you adopt this on a corporate network — it's a new dataflow your
   DLP probably hasn't profiled.
6. **For genuinely sensitive review work, prefer the desktop CLI** on
   a trusted endpoint over the cloud sandbox. Same model, different
   trust boundary — no TLS interception, no remote disk.
7. **Pick the right network-access policy** at environment-creation
   time. The defaults are documented at
   <https://code.claude.com/docs/en/claude-code-on-the-web>; stricter
   policies narrow the proxy's allow-list and reduce blast radius.

## References

- Firecracker microVM (production isolation for AWS Lambda / Fly.io):
  <https://firecracker-microvm.github.io/>
- Claude Code on the Web — official docs:
  <https://code.claude.com/docs/en/claude-code-on-the-web>
- The TLS-interception CA is directly observable to any user via
  `openssl s_client -connect <host>:443`.
- Anthropic's published security posture for the cloud sandbox: see
  the official docs vendored under `vendor/claude-code-docs/`.

---

*Captured from a live session on 2026-05-17. Re-verify any specific
value with `cat /proc/cmdline`, `openssl s_client -connect <host>:443`,
and `grep -E 'Seccomp|CapEff' /proc/self/status` — Anthropic may change
the runtime.*
