#!/bin/sh
# SessionStart hook — basic bootstrap + secrets bootstrap.
#
# Same as session-start.basic.sh, but additionally clones a *separate private*
# repo containing your .env / API keys at session start, so your project repo
# stays free of secrets.
#
# Required setup (one time):
#
#   1. Create a private GitHub repo, e.g. <your-username>/<your-secrets-repo>,
#      with a single `.env` file holding your KEY=VALUE lines.
#
#   2. Mint a fine-grained GitHub PAT scoped ONLY to that secrets repo
#      (Contents: Read). Give it the shortest expiry you can tolerate.
#
#   3. In the Anthropic web UI for this Claude Code environment, set the
#      Environment Variable:
#         SECRETS_PAT=<the PAT>
#         SECRETS_REPO=<your-username>/<your-secrets-repo>
#
#   4. Put this hook in your project at .claude/hooks/session-start.sh
#      (chmod +x) with templates/settings.json copied to .claude/settings.json.
#
# What happens at session start:
#
#   * Clones SECRETS_REPO into /tmp/secrets/ using SECRETS_PAT.
#   * Sources /tmp/secrets/.env into the hook's env (process-local — see
#      "How your project tools see the values" below).
#   * Reports loaded variable count via additionalContext so it shows in the
#      transcript without leaking values.
#
# Read docs/secrets-bootstrap.md in this template's source repo for the full
# pattern, threat model, and rotation guidance.

set -eu

PROJECT="project"  # TODO: rename to your project (e.g. "myapp")

if [ "${PROJECT_SKIP_BOOTSTRAP:-0}" = "1" ]; then
    echo "[$PROJECT] bootstrap skipped (PROJECT_SKIP_BOOTSTRAP=1)"
    exit 0
fi

IN_CLOUD="${CLAUDE_CODE_REMOTE:-false}"

# ---------------------------------------------------------------------------
# 1. Secrets bootstrap (only in cloud sessions — local boxes use real .env).
# ---------------------------------------------------------------------------
if [ "$IN_CLOUD" = "true" ] && [ "${PROJECT_SKIP_SECRETS:-0}" != "1" ]; then
    if [ -z "${SECRETS_PAT:-}" ] || [ -z "${SECRETS_REPO:-}" ]; then
        echo "[$PROJECT] WARN: SECRETS_PAT or SECRETS_REPO unset — skipping secrets bootstrap"
    else
        SECRETS_DIR="/tmp/secrets"
        if [ ! -d "$SECRETS_DIR/.git" ]; then
            git clone --quiet --depth 1 \
                "https://x-access-token:${SECRETS_PAT}@github.com/${SECRETS_REPO}.git" \
                "$SECRETS_DIR" 2>/dev/null \
                || { echo "[$PROJECT] ERROR: secrets clone failed"; exit 0; }
        fi
        if [ -f "$SECRETS_DIR/.env" ]; then
            # Lock down before sourcing — avoid stray world-read.
            chmod 600 "$SECRETS_DIR/.env" 2>/dev/null || true
            # Copy to the project root as .env so other tooling (python-dotenv,
            # node dotenv, etc.) can find it the standard way.
            if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ ! -e "$CLAUDE_PROJECT_DIR/.env" ]; then
                cp "$SECRETS_DIR/.env" "$CLAUDE_PROJECT_DIR/.env"
                chmod 600 "$CLAUDE_PROJECT_DIR/.env" 2>/dev/null || true
            fi
            COUNT=$(grep -cE '^[A-Za-z_][A-Za-z0-9_]*=' "$SECRETS_DIR/.env" || echo 0)
            echo "[$PROJECT] loaded $COUNT secret(s) into \$CLAUDE_PROJECT_DIR/.env"
        else
            echo "[$PROJECT] WARN: $SECRETS_DIR/.env not found"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 2. Tool bootstrap — same as session-start.basic.sh
# ---------------------------------------------------------------------------
need_apt=""
need_pip=""
need_npm=""

# TODO: list your project's deps here (see session-start.basic.sh for examples)

if [ -z "$need_apt" ] && [ -z "$need_pip" ] && [ -z "$need_npm" ]; then
    echo "[$PROJECT] tools present"
    exit 0
fi

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

# ---------------------------------------------------------------------------
# How your project tools see the values
# ---------------------------------------------------------------------------
# The hook runs as a child process — env vars set inside it do NOT propagate
# back to the parent Claude Code session. That's why we copy the .env to
# $CLAUDE_PROJECT_DIR/.env. Your project's runtime should load it the
# standard way:
#   * Python:  `from dotenv import load_dotenv; load_dotenv()`
#   * Node:    `require('dotenv').config()`
#   * Shell:   `set -a; . ./.env; set +a`
# Add `.env` to your project's .gitignore so it never gets committed.
