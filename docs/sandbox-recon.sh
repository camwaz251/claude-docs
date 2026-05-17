#!/usr/bin/env bash
# sandbox-recon.sh — reproducible fingerprint of the Claude Code on the Web
# sandbox, formatted for diffing between sessions.
#
# Companion to docs/sandbox-recon-runbook.md and docs/sandbox-security-analysis.md.
#
# Usage:
#   ./docs/sandbox-recon.sh                    # safe mode, print to stdout
#   ./docs/sandbox-recon.sh -o /tmp/run-a.txt  # save to file
#   ./docs/sandbox-recon.sh --unsafe           # include session-identifying values
#                                              # (egress IP, account/session UUIDs)
#   ./docs/sandbox-recon.sh --phases host,net  # run a subset
#
# Each section header carries a tag:
#   :S = Stable    — expected to match across sessions on the same image tag
#   :V = Variable  — same shape, different values (e.g. timing, free disk)
#   :P = PerSession — identifying; only printed with --unsafe
#
# To compare two sessions:
#   session A:  ./docs/sandbox-recon.sh -o /tmp/run-a.txt
#   session B:  ./docs/sandbox-recon.sh -o /tmp/run-b.txt
#   then:       diff -u /tmp/run-a.txt /tmp/run-b.txt
#
# Read-only. No exploitation, no control-plane fuzzing.

set -u
shopt -s nullglob

# -------- args --------
OUT=/dev/stdout
UNSAFE=0
PHASES="host,boot,isolation,mounts,limits,net_basics,net_ports,net_https,net_tls,net_inbound,net_metadata,identity,toolchain,cpu_mit,egress_ip"

while (( "$#" )); do
  case "$1" in
    -o|--out)      OUT="$2"; shift 2 ;;
    --unsafe)      UNSAFE=1; shift ;;
    --phases)      PHASES="$2"; shift 2 ;;
    -h|--help)     sed -n '2,30p' "$0"; exit 0 ;;
    *)             echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

want()    { [[ ",$PHASES," == *",$1,"* ]]; }
have()    { command -v "$1" >/dev/null 2>&1; }
redact()  { [[ $UNSAFE -eq 1 ]] && cat || sed 's/.*/<redacted; rerun with --unsafe>/'; }
section() { echo; echo "[$1]"; }
kv()      { printf '%-28s = %s\n' "$1" "${2:-}"; }
probe()   { timeout 5 bash -c "$1" 2>/dev/null || echo '<unavailable>'; }

# -------- header --------
exec > "$OUT"

echo "# sandbox-recon @ $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "# unsafe_mode=$UNSAFE  phases=$PHASES"

# -------- host:V (varies) --------
if want host; then
section "host:S"
kv kernel        "$(uname -srm)"
kv os            "$(. /etc/os-release && echo "$PRETTY_NAME")"
kv arch          "$(uname -m)"
kv hostname      "$(uname -n)"   # 'vm' in current image

section "host:V"
kv cpu_count     "$(nproc)"
kv cpu_model     "$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)"
kv mem_total     "$(free -h | awk '/^Mem:/ {print $2}')"
kv swap_total    "$(free -h | awk '/^Swap:/ {print $2}')"
kv disk_total    "$(df -h / | awk 'NR==2 {print $2}')"
kv disk_free     "$(df -h / | awk 'NR==2 {print $4}')"
kv uptime_sec    "$(awk '{print int($1)}' /proc/uptime)"
fi

# -------- boot:S --------
if want boot; then
section "boot:S"
kv pid1_comm     "$(cat /proc/1/comm 2>/dev/null)"
kv pid1_cmdline  "$(tr '\0' ' ' < /proc/1/cmdline 2>/dev/null)"
kv kernel_cmdline "$(cat /proc/cmdline 2>/dev/null)"
kv hypervisor    "$(dmesg 2>/dev/null | awk -F': ' '/Hypervisor detected/ {print $2; exit}')"
kv detect_virt   "$(have systemd-detect-virt && systemd-detect-virt || echo n/a)"
kv dockerenv     "$([[ -e /.dockerenv ]] && echo present || echo absent)"
kv containerenv  "$([[ -e /run/.containerenv ]] && echo present || echo absent)"
kv modules_loaded "$(lsmod 2>/dev/null | wc -l)"
fi

# -------- isolation:S --------
if want isolation; then
section "isolation:S"
kv whoami        "$(id -un):$(id -u)"
kv groups        "$(id -Gn | tr ' ' ',')"
kv seccomp       "$(awk '/^Seccomp:/ {print $2}' /proc/self/status)"
kv seccomp_flt   "$(awk '/^Seccomp_filters:/ {print $2}' /proc/self/status)"
kv no_new_privs  "$(awk '/^NoNewPrivs:/ {print $2}' /proc/self/status)"
kv cap_eff       "$(awk '/^CapEff:/ {print $2}' /proc/self/status)"
kv cap_bnd       "$(awk '/^CapBnd:/ {print $2}' /proc/self/status)"
kv apparmor      "$(cat /proc/self/attr/current 2>/dev/null | tr -d '\0' | xargs)"
kv selinux       "$(getenforce 2>/dev/null || echo disabled)"
kv apparmor_loaded "$(have aa-status && aa-status --enabled 2>/dev/null && echo yes || echo no)"
fi

# -------- mounts:S --------
if want mounts; then
section "mounts:S"
echo "# fstype / mount / options (root-level and harness mounts only)"
awk '$5=="/" || $5 ~ "^/opt/(claude-code|env-runner)" {print $9, $5, $6}' /proc/self/mountinfo \
  | sort -u
kv docker_sock   "$([[ -S /var/run/docker.sock ]] && echo present || echo absent)"
kv opt_listing   "$(ls /opt 2>/dev/null | tr '\n' ' ')"
fi

# -------- limits:V --------
if want limits; then
section "limits:V"
kv cgroup_fstype "$(stat -fc %T /sys/fs/cgroup 2>/dev/null)"
kv memory_max    "$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo n/a)"
kv cpu_max       "$(cat /sys/fs/cgroup/cpu.max 2>/dev/null || echo n/a)"
kv pids_max      "$(cat /sys/fs/cgroup/pids.max 2>/dev/null || echo n/a)"
kv ulimit_nofile "$(ulimit -n)"
kv ulimit_nproc  "$(ulimit -u)"
kv ulimit_core   "$(ulimit -c)"
kv ulimit_stack  "$(ulimit -s)"
fi

# -------- net_basics:S --------
if want net_basics; then
section "net_basics:S"
kv resolv_conf   "$(grep -E '^(nameserver|search|options)' /etc/resolv.conf | xargs)"
kv hosts_file    "$(grep -vE '^\s*(#|$)' /etc/hosts | xargs)"
kv default_route "$(ip route 2>/dev/null | head -1 || echo none)"
kv ipv4_iface    "$(ip -4 -br addr 2>/dev/null | awk '$1!="lo"' | head -1)"
kv ipv6_iface    "$(ip -6 -br addr 2>/dev/null | awk '$1!="lo"' | head -1 || echo disabled)"
kv ping_present  "$(have ping && echo yes || echo no)"
fi

# -------- net_ports:S --------
if want net_ports; then
section "net_ports:S"
for p in 22 25 53 80 443 587 993 3306 5432 6379 8080 8443; do
  if timeout 3 bash -c "exec 3<>/dev/tcp/example.com/$p" 2>/dev/null; then
    kv "tcp_egress_$p" open
  else
    kv "tcp_egress_$p" blocked
  fi
done
# raw-tcp-to-non-web sanity check
if timeout 5 bash -c 'exec 3<>/dev/tcp/8.8.8.8/53' 2>/dev/null; then
  kv tcp_53_to_8888 open
else
  kv tcp_53_to_8888 blocked
fi
fi

# -------- net_https:V --------
if want net_https; then
section "net_https:V"
for h in github.com api.anthropic.com pypi.org registry.npmjs.org example.com cloudflare.com; do
  code=$(curl -sS --max-time 6 -o /dev/null -w '%{http_code}' "https://$h" 2>/dev/null || echo timeout)
  kv "https_$h" "$code"
done
fi

# -------- net_tls:S --------
if want net_tls; then
section "net_tls:S"
for h in github.com example.com pypi.org; do
  issuer=$(echo | timeout 6 openssl s_client -connect "$h:443" -servername "$h" 2>/dev/null \
            | openssl x509 -noout -issuer 2>/dev/null | sed 's/^issuer=//')
  kv "tls_issuer_$h" "${issuer:-<unavailable>}"
done
kv chain_len_github "$(echo | timeout 6 openssl s_client -connect github.com:443 \
                                    -servername github.com -showcerts 2>/dev/null \
                                    | grep -c 'BEGIN CERTIFICATE')"
kv ca_bundle_path   "${NODE_EXTRA_CA_CERTS:-unset}"
kv requests_ca      "${REQUESTS_CA_BUNDLE:-unset}"
kv ssl_cert_file    "${SSL_CERT_FILE:-unset}"
fi

# -------- net_inbound:S --------
if want net_inbound; then
section "net_inbound:S"
for p in 80 8080; do
  if have python3 && timeout 2 python3 -c \
       "import socket; s=socket.socket(); s.setsockopt(1,2,1); s.bind(('0.0.0.0',$p)); s.listen(1)" \
       2>/dev/null; then
    kv "bind_0.0.0.0_$p" ok
  else
    kv "bind_0.0.0.0_$p" denied
  fi
done
kv ss_listening "$(ss -tlnp 2>/dev/null | tail -n +2 | wc -l)"
fi

# -------- net_metadata:S --------
if want net_metadata; then
section "net_metadata:S"
# GCE
gce=$(curl -sS --max-time 3 -o /dev/null -w '%{http_code}' \
        http://169.254.169.254/computeMetadata/v1/ \
        -H 'Metadata-Flavor: Google' 2>/dev/null || echo timeout)
kv gce_metadata "$gce"
# AWS IMDSv2
aws=$(curl -sS --max-time 3 -o /dev/null -w '%{http_code}' \
        http://169.254.169.254/latest/meta-data/ \
        -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null || echo timeout)
kv aws_imds     "$aws"
fi

# -------- identity:P (per-session, sensitive) --------
if want identity; then
section "identity:P"
echo "# names of CLAUDE_/IS_SANDBOX/ANT_ env vars (values redacted unless --unsafe)"
env | grep -E '^(CLAUDE|IS_SANDBOX|ANT_|ANTHROPIC)' | sort | \
  while IFS='=' read -r k v; do
    if [[ $UNSAFE -eq 1 ]]; then
      printf '%-50s = %s\n' "$k" "$v"
    else
      printf '%-50s = <redacted>\n' "$k"
    fi
  done
kv git_remote_origin "$(git config --get remote.origin.url 2>/dev/null | \
                        sed -E 's#://[^@]+@#://<creds>@#' | \
                        ([[ $UNSAFE -eq 1 ]] && cat || sed -E 's#/git/.*$#/git/<owner>/<repo>#'))"
fi

# -------- toolchain:S --------
if want toolchain; then
section "toolchain:S"
for b in python3 node npm bun go rustc cargo gcc make curl wget jq git docker kubectl ssh nc openssl ip ss tcpdump nmap; do
  if have "$b"; then
    kv "have_$b" "$(command -v "$b")"
  else
    kv "have_$b" '<missing>'
  fi
done
kv ver_python  "$(python3 --version 2>&1)"
kv ver_node    "$(node --version 2>&1)"
kv ver_go      "$(go version 2>&1)"
kv ver_gcc     "$(gcc --version 2>&1 | head -1)"
kv ver_git     "$(git --version 2>&1)"
kv suid_count  "$(find /usr/bin /usr/sbin /bin /sbin -perm -4000 -type f 2>/dev/null | wc -l)"
fi

# -------- cpu_mit:V --------
if want cpu_mit; then
section "cpu_mit:V"
for f in /sys/devices/system/cpu/vulnerabilities/*; do
  kv "$(basename "$f")" "$(head -1 "$f" 2>/dev/null)"
done
kv cpu_flag_hypervisor "$(grep -qm1 ' hypervisor ' /proc/cpuinfo && echo present || echo absent)"
kv entropy_avail       "$(cat /proc/sys/kernel/random/entropy_avail 2>/dev/null)"
fi

# -------- egress_ip:P (per-session, GCE NAT pool) --------
if want egress_ip; then
section "egress_ip:P"
ip=$(curl -sS --max-time 5 https://ifconfig.me 2>/dev/null || echo unavailable)
if [[ $UNSAFE -eq 1 ]]; then
  kv egress_ipv4 "$ip"
else
  # show only the /16 — enough to recognise the cloud, not enough to publish
  prefix=$(echo "$ip" | awk -F. '{print $1"."$2".0.0/16"}')
  kv egress_prefix "$prefix"
fi
fi

echo
echo "# end recon"
