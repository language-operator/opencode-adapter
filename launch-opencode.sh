#!/bin/sh
# Launch the opencode TUI for the agent. Everything that shapes the agent —
# its instructions (standing context, via the `instructions` config field),
# model, provider, and MCP servers — is read from
# $OPENCODE_CONFIG_DIR/opencode.jsonc, written by the init container
# (seed-config.mjs). The positional /workspace opens directly into the
# workspace project, bypassing opencode's project picker.
set -eu

exec opencode /workspace
