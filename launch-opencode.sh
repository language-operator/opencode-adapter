#!/bin/sh
# Config — model, provider, MCP servers, standing instructions — is read from
# $OPENCODE_CONFIG_DIR/opencode.jsonc, written by `coding-runtime seed`. The
# base already starts tmux in the working directory, so `.` opens straight into
# the project and skips opencode's picker.
set -eu
exec opencode .
