#!/bin/sh
# Launch the opencode TUI for the agent. Everything that shapes the agent —
# its instructions (standing context, via the `instructions` config field),
# model, provider, and MCP servers — is read from
# $OPENCODE_CONFIG_DIR/opencode.jsonc, written by the init container
# (seed-config.mjs). The positional project dir opens directly into that
# project, bypassing opencode's project picker.
#
# Resolve the same way server.mjs picks the tmux cwd: explicit OPENCODE_CWD
# override, else AGENT_REPO_DIR (operator-injected when spec.repository clones a
# repo into the workspace), else the /workspace default.
set -eu

workdir="${OPENCODE_CWD:-${AGENT_REPO_DIR:-/workspace}}"

exec opencode "$workdir"
