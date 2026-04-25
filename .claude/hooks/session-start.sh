#!/bin/sh
# SessionStart hook for the claude-docs repo itself.
#
# Sole job: make sure the vendor/ submodules are initialized so any Claude
# session attached here can read the bundled Anthropic docs without going
# over the network. Idempotent.
#
# To skip: CLAUDE_DOCS_SKIP_SUBMODULES=1 claude

set -eu

if [ "${CLAUDE_DOCS_SKIP_SUBMODULES:-0}" = "1" ]; then
    echo "[claude-docs] submodule init skipped"
    exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-.}"

if [ ! -f .gitmodules ]; then
    echo "[claude-docs] no .gitmodules — nothing to init"
    exit 0
fi

# Already initialized? Cheap check: at least one submodule path has content.
if [ -f vendor/claude-code-docs/README.md ] && [ -f vendor/claude-wiki/INDEX.md ]; then
    echo "[claude-docs] vendored docs present"
    exit 0
fi

echo "[claude-docs] initializing vendor/ submodules"
git submodule update --init --recursive --depth 1 --quiet 2>/dev/null \
    || echo "[claude-docs] WARN: submodule init failed — vendor/ unavailable this session"

echo "[claude-docs] ready"
