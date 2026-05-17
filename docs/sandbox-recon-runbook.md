# Sandbox Recon Runbook

A reproducible checklist for fingerprinting the Claude Code on the Web
sandbox from inside a session — same probes that produced
[`sandbox-security-analysis.md`](sandbox-security-analysis.md). If you want
a future Claude instance (or a colleague) to redo the analysis from
scratch, point them at this file.

## How to use

Three modes, in order of effort:

- **Scripted (recommended)** — run [`sandbox-recon.sh`](sandbox-recon.sh):

  ```sh
  # safe mode — sanitises session-identifying values, prints to stdout
  ./docs/sandbox-recon.sh

  # save two sessions and diff them
  ./docs/sandbox-recon.sh -o /tmp/run-a.txt   # session A
  ./docs/sandbox-recon.sh -o /tmp/run-b.txt   # session B (new VM)
  diff -u /tmp/run-a.txt /tmp/run-b.txt
  ```

  Each section is tagged `:S` (stable across sessions), `:V` (varies
  in value but not shape), or `:P` (per-session identifying — only
  printed with `--unsafe`). That makes a diff between two sessions
  immediately readable: the `:S` blocks should match exactly, the
  `:V` blocks tell you what the platform reschedules, and the `:P`
  blocks show what genuinely identifies one session vs another.

- **Human-driven** — paste each command below into a terminal and read
  the result against the "expected" line. Skip phases you don't need.

- **Agent-driven** — say to a Claude Code session:

  > Run `./docs/sandbox-recon.sh -o /tmp/recon.txt` (and again with
  > `--unsafe -o /tmp/recon-unsafe.txt` locally), then update
  > `docs/sandbox-security-analysis.md` with any deltas from what's
  > currently documented. Apply the agnosticism rules from `CLAUDE.md`
  > before committing — no IPs, usernames, or session IDs.

Everything below is read-only. Nothing here attempts to escape,
escalate, or probe Anthropic's control plane aggressively.

---

## Phase 1 — Quick fingerprint

```sh
uname -a
cat /etc/os-release | head -5
whoami; id
pwd; echo "HOME=$HOME"
nproc; free -h; df -hT | head -5
```

**Expected:** Ubuntu 24.04, kernel 6.18.x custom build, `root` (uid 0),
cwd under `/home/user/<repo>` with `HOME=/root`, 4 vCPU, ~15 GiB RAM,
~252 GB ext4 root, tmpfs on `/dev/shm` and `/sys/fs/cgroup`.

## Phase 2 — Container vs microVM

```sh
ls -la /.dockerenv /run/.containerenv 2>&1 | head
cat /proc/1/comm
cat /proc/1/cmdline | tr '\0' ' '; echo
systemd-detect-virt
dmesg | grep -E 'Hypervisor|Linux version' | head -3
```

**Expected:** No container marker files. PID 1 is `process_api`. Kernel
cmdline contains `rdinit=/process_api --firecracker-init`.
`systemd-detect-virt` says `docker` (misleading — it's matching on cgroup
paths) but `dmesg` confirms `Hypervisor detected: KVM`. This is a
**microVM**, not a container.

## Phase 3 — Kernel cmdline hardening

```sh
cat /proc/cmdline
lsmod | head
```

**Expected:** Cmdline includes `nomodule` (modules disabled),
`init_on_free=1` (freed pages zeroed), `ipv6.disable=1`, `panic=1
reboot=k`, `swiotlb=noforce`. `lsmod` empty.

## Phase 4 — Isolation primitives (deliberately permissive interior)

```sh
grep -E 'Seccomp|CapEff|CapBnd|NoNewPrivs' /proc/self/status
cat /proc/sys/kernel/seccomp/actions_avail
cat /proc/self/attr/current
getenforce 2>/dev/null || echo 'no SELinux'
ls /etc/apparmor.d/ 2>/dev/null | head
```

**Expected:** `Seccomp: 0`, `NoNewPrivs: 0`, `CapEff` ≈
`000001fffeffffff` (all caps except `cap_sys_resource`), AppArmor profile
shows `kernel` (unconfined), no SELinux. AppArmor profiles exist on disk
but aren't loaded against the agent.

## Phase 5 — Mounts & harness binaries

```sh
grep ' / ' /proc/self/mountinfo | head -5
awk '{print $4, $5, $6}' /proc/self/mountinfo | sort -u | head -20
ls -la /opt/
ls -la /opt/claude-code/ /opt/env-runner/ 2>/dev/null
ls -la /var/run/docker.sock /run/docker.sock 2>&1 | head
```

**Expected:** No overlayfs (microVM uses a normal ext4 root). `/opt/`
holds vendored toolchains (node20/21/22, ruby 3.1/3.2/3.3, rbenv, maven,
gradle, playwright). `/opt/claude-code` and `/opt/env-runner` are
read-only mounts holding the agent + harness binaries. No docker socket.

## Phase 6 — cgroup / ulimit

```sh
stat -fc %T /sys/fs/cgroup
cat /sys/fs/cgroup/memory.max 2>/dev/null
cat /sys/fs/cgroup/cpu.max 2>/dev/null
cat /sys/fs/cgroup/pids.max 2>/dev/null
ulimit -a
```

**Expected:** No meaningful caps visible from inside (microVM sees its
own resources, not host cgroup limits). `ulimit -n` 4096, `-u` ≈ 64290.

## Phase 7 — Network egress matrix

```sh
cat /etc/resolv.conf
cat /etc/hosts
ip -4 addr; ip route
ip -6 addr 2>/dev/null | head

# port probe — adjust the host if example.com is blocked
for p in 22 25 80 443 587 993 3306 5432 6379 8080 8443; do
  timeout 3 bash -c "exec 3<>/dev/tcp/example.com/$p" \
    2>/dev/null && echo "$p: open" || echo "$p: blocked"
done

# HTTPS reachability to a sample of public hosts
for h in github.com api.anthropic.com pypi.org registry.npmjs.org example.com; do
  curl -sS -o /dev/null -w "$h: %{http_code} (%{time_total}s)\n" "https://$h"
done

# raw outbound TCP to a non-web port should fail
timeout 5 bash -c 'exec 3<>/dev/tcp/8.8.8.8/53 && echo open' \
  2>&1 || echo 'tcp/53 blocked (expected)'
```

**Expected:** DNS → `8.8.8.8`, route table empty, IPv6 absent. Only
TCP/80 and TCP/443 reach the outside. HTTPS to public hosts returns
2xx/3xx in <300 ms. Raw TCP to non-web ports (e.g. 53) times out —
network is L7-mediated, not L3-bridged.

## Phase 8 — TLS interception (the headline finding)

```sh
echo | openssl s_client -connect github.com:443 -servername github.com \
  2>/dev/null | openssl x509 -noout -issuer -subject

echo | openssl s_client -connect example.com:443 -servername example.com \
  -showcerts 2>/dev/null | grep -E 'depth=|s:|i:' | head

env | grep -iE 'CA_(BUNDLE|CERT)|SSL_CERT|NODE_EXTRA_CA'
```

**Expected:** Every leaf is re-signed by
`O=Anthropic, CN=sandbox-egress-production TLS Inspection CA`. The
chain has length 2 (leaf + the Anthropic CA acting as its own root —
no intermediate). The Anthropic CA is installed in
`/etc/ssl/certs/ca-certificates.crt` and `NODE_EXTRA_CA_CERTS`,
`REQUESTS_CA_BUNDLE`, `SSL_CERT_FILE` are all wired to it. **This is the
TLS-interception proxy.** Document it explicitly in any security review.

## Phase 9 — Inbound binding (kernel allows, outside world can't reach)

```sh
timeout 2 python3 -c \
  'import socket; s=socket.socket(); s.setsockopt(1,2,1); s.bind(("0.0.0.0",8080)); s.listen(1); print("bound :8080 OK")'

timeout 2 python3 -c \
  'import socket; s=socket.socket(); s.setsockopt(1,2,1); s.bind(("0.0.0.0",80)); s.listen(1); print("bound :80 OK")'

ss -tlnp 2>/dev/null
```

**Expected:** Both binds succeed (interior is permissive, you're root).
`ss -tlnp` shows nothing pre-listening on public ports. But nothing
outside the VM routes to these ports — the microVM has no public
ingress.

## Phase 10 — Cloud metadata & SSRF pivots

```sh
getent hosts metadata.google.internal 169.254.169.254
curl -sS --max-time 3 -o /dev/null -w '%{http_code} %{errormsg}\n' \
  http://169.254.169.254/computeMetadata/v1/ -H 'Metadata-Flavor: Google'
curl -sS --max-time 3 -o /dev/null -w '%{http_code} %{errormsg}\n' \
  http://169.254.169.254/latest/meta-data/ -H 'X-aws-ec2-metadata-token: x'
```

**Expected:** All blocked. Cloud-metadata endpoints (GCE link-local,
AWS IMDS) are not reachable — important because these are the standard
pivot for SSRF-style exfil.

## Phase 11 — Identity, session, GitHub broker

```sh
# DO NOT paste the values into a public doc — just confirm the names.
env | grep -E '^(CLAUDE|IS_SANDBOX|ANT_|ANTHROPIC)' | cut -d= -f1 | sort
ls -la /proc/self/fd 2>/dev/null | head
git config --get remote.origin.url 2>/dev/null
```

**Expected names worth noting (values are session-identifying, redact
before committing):**
- `CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR` — OAuth token lives on an
  inherited file descriptor, not in env (good practice).
- `CLAUDE_CODE_WEBSOCKET_AUTH_FILE_DESCRIPTOR` — same for websocket
  auth.
- `CLAUDE_CODE_ACCOUNT_UUID`, `CLAUDE_CODE_ORGANIZATION_UUID`,
  `CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_CONTAINER_ID` — identity
  metadata.
- `CLAUDE_CODE_PROXY_RESOLVES_HOSTS` — confirms the egress proxy
  performs DNS, not the guest.
- `CLAUDE_CODE_REMOTE_ENVIRONMENT_TYPE`, `ANT_IMAGE_REPOSITORY`,
  `ANT_IMAGE_TAG` — environment-tier info.
- `IS_SANDBOX=yes`.

`remote.origin.url` will look like
`http://local_proxy@127.0.0.1:<random-port>/git/<owner>/<repo>` — that's
the local credential-broker shim. The GitHub PAT itself is never
exposed to the agent.

## Phase 12 — Toolchain inventory

```sh
for b in python3 node npm bun go rustc cargo gcc make curl wget jq git \
         docker kubectl ssh nc nmap openssl ip ss; do
  v=$(command -v $b 2>/dev/null) && echo "$b -> $v"
done
python3 --version; node --version; go version; gcc --version | head -1
ls /opt/  # vendored runtimes
find /usr/bin /usr/sbin /bin /sbin -perm -4000 -type f 2>/dev/null
getcap -r /usr/bin /usr/sbin /usr/local/bin 2>/dev/null
```

**Expected:** Python 3.11, Node 22 (also 20, 21 via `/opt`), Go 1.24,
Rust stable, gcc 13. SUID set includes the standard
`sudo|su|mount|passwd|chsh|chfn|newgrp|gpasswd|umount`. No file
capabilities set on tracked binaries. `docker` CLI is present but
the daemon isn't running.

## Phase 13 — Egress IP (note, do **not** publish the specific address)

```sh
curl -sS --max-time 5 https://ifconfig.me; echo
curl -sS --max-time 5 https://api.ipify.org; echo
```

**Expected:** A public IP inside a **Google Cloud (GCE) prefix**.
Anthropic NATs sessions out from a managed IP pool; sessions in the
same environment can land on different IPs. Record the *prefix* and
the reverse DNS owner if you need a network-edge allowlist, but don't
publish the specific address in a public doc — it changes and it
identifies infrastructure.

## Phase 14 — CPU mitigations / hypervisor leakage

```sh
ls /sys/devices/system/cpu/vulnerabilities/
head -2 /sys/devices/system/cpu/vulnerabilities/* 2>/dev/null
grep -m1 -E 'flags' /proc/cpuinfo | tr ' ' '\n' \
  | grep -E '^(hypervisor|vmx|svm)$' | sort -u
cat /proc/sys/kernel/random/entropy_avail
```

**Expected:** The standard set of Spectre/Meltdown/MDS/etc.
vulnerability files exists; mitigation status reflects the host's
microcode. The `hypervisor` CPU flag is present (KVM guest). Entropy
≥ 256.

## Phase 15 — Synthesis

After running phases 1–14, diff the findings against
[`sandbox-security-analysis.md`](sandbox-security-analysis.md). For
anything new or changed:

1. Sanitise per `CLAUDE.md` rules — no usernames, no session IDs,
   no specific IPs, no machine IDs.
2. Update the analysis doc inline (don't create a new top-level
   doc; this repo is meant to scan in one minute).
3. Run the agnosticism grep before commit:

   ```sh
   grep -RIn -E '(camwaz|cooklang|financeapp|homeneeds|34\.57\.|machine_id|container_id)' \
     --exclude-dir=vendor --exclude-dir=.git .
   ```

4. Commit on a topic branch with a short, present-tense message like
   `docs: refresh sandbox security analysis`.

## Phases deliberately *not* in this runbook

- **No control-plane fuzzing.** `process_api` listens on
  `0.0.0.0:2024` and is the harness's RPC surface. Probing it
  beyond observing the cmdline is out of scope — it's Anthropic's
  control plane, not in-scope for a tenant-side review.
- **No attempt at hypervisor escape.** Even running a known
  Firecracker CVE PoC inside the guest would be inappropriate; if
  you're authorised to do that level of testing, do it under an
  Anthropic-coordinated security disclosure.
- **No probing of other tenants.** There aren't any reachable
  anyway — the network egress is L7-mediated and the disk is
  per-VM.

These phases would belong to a coordinated security assessment, not
a tenant-side recon walk.
