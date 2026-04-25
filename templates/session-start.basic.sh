#!/bin/sh
# SessionStart hook — basic bootstrap template.
#
# Drop this into your repo at .claude/hooks/session-start.sh (chmod +x) and
# pair it with templates/settings.json copied to .claude/settings.json.
#
# Why this exists: iOS-created Claude Code environments do NOT expose a Setup
# Script field, and each cloud session boots a fresh microVM with nothing
# cached. So any apt/pip dependencies your project needs have to be
# (re)installed at session start. Idempotent — skips work if a tool is already
# present, so re-runs are cheap.
#
# To skip the install (e.g., on a local Linux dev box that already has the
# tools, or to debug):
#   PROJECT_SKIP_BOOTSTRAP=1 claude
# Or open the Unrestricted environment on claude.ai/code (desktop) and paste
# the install commands into the Setup Script field — then this hook becomes
# a no-op confirmation step.
#
# Replace "PROJECT" below with your project's short name.

set -eu

PROJECT="project"  # TODO: rename to your project (e.g. "myapp")

# Skip on demand.
if [ "${PROJECT_SKIP_BOOTSTRAP:-0}" = "1" ]; then
    echo "[$PROJECT] bootstrap skipped (PROJECT_SKIP_BOOTSTRAP=1)"
    exit 0
fi

# Cloud-session detection. CLAUDE_CODE_REMOTE=true on iOS / web sandbox.
IN_CLOUD="${CLAUDE_CODE_REMOTE:-false}"

# ---------------------------------------------------------------------------
# TODO: list your project's dependencies here.
# ---------------------------------------------------------------------------
# Each line below checks for a tool and adds it to the install queue if
# missing. Delete what you don't need; add what you do.

need_apt=""
need_pip=""
need_npm=""

# --- system packages (apt) ---
# Examples:
# command -v ffmpeg     >/dev/null 2>&1 || need_apt="$need_apt ffmpeg"
# command -v jq         >/dev/null 2>&1 || need_apt="$need_apt jq"
# command -v tesseract  >/dev/null 2>&1 || need_apt="$need_apt tesseract-ocr"

# --- python packages (pip) ---
# Examples:
# python3 -c "import yt_dlp"          >/dev/null 2>&1 || need_pip="$need_pip yt-dlp"
# python3 -c "import faster_whisper"  >/dev/null 2>&1 || need_pip="$need_pip faster-whisper"
# python3 -c "import requests"        >/dev/null 2>&1 || need_pip="$need_pip requests"
#
# Or, if you have a requirements file in the repo:
# [ -f requirements.txt ] && pip install --quiet -r requirements.txt

# --- node packages (npm, global) ---
# Examples:
# command -v vercel  >/dev/null 2>&1 || need_npm="$need_npm vercel"
# command -v wrangler >/dev/null 2>&1 || need_npm="$need_npm wrangler"
#
# Or for project-local install:
# [ -f package.json ] && [ ! -d node_modules ] && npm install --silent

# ---------------------------------------------------------------------------

if [ -z "$need_apt" ] && [ -z "$need_pip" ] && [ -z "$need_npm" ]; then
    echo "[$PROJECT] tools present"
    exit 0
fi

# On a local Linux box without root, don't try to apt install — just warn.
if [ "$IN_CLOUD" != "true" ] && [ "$(id -u)" != "0" ]; then
    [ -n "$need_apt" ] && echo "[$PROJECT] missing (apt):$need_apt — install manually"
    [ -n "$need_pip" ] && echo "[$PROJECT] missing (pip):$need_pip — install manually"
    [ -n "$need_npm" ] && echo "[$PROJECT] missing (npm):$need_npm — install manually"
    exit 0
fi

if [ -n "$need_apt" ]; then
    echo "[$PROJECT] installing apt:$need_apt"
    apt-get update -qq >/dev/null 2>&1 || true
    # shellcheck disable=SC2086
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $need_apt >/dev/null
fi

if [ -n "$need_pip" ]; then
    echo "[$PROJECT] installing pip:$need_pip"
    # shellcheck disable=SC2086
    pip install --quiet $need_pip
fi

if [ -n "$need_npm" ]; then
    echo "[$PROJECT] installing npm:$need_npm"
    # shellcheck disable=SC2086
    npm install -g --silent $need_npm
fi

echo "[$PROJECT] bootstrap complete"
