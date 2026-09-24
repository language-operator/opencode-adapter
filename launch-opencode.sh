#!/bin/sh
# Config — model, provider, MCP servers, standing instructions — is read from
# $OPENCODE_CONFIG_DIR/opencode.jsonc, written by `coding-runtime seed`. The
# base already starts tmux in the working directory, so `.` opens straight into
# the project and skips opencode's picker.
#
# Sessions live on the workspace PVC, under $XDG_DATA_HOME/opencode, which
# outlives the pod. Sleeping an agent destroys the pod and waking it makes a new
# one, and this exec is the only moment a resume decision can be made — tmux is
# started with `new-session -A`, so on a reconnect to a live pod the launcher is
# never re-run. Without --continue a woken agent always opens blank on a
# conversation the user can still see the history of.
#
# Only pass it once opencode has actually run here. With --continue the TUI
# seeds a placeholder session route and replaces it when it finds a session to
# resume; with nothing to find the placeholder survives, the view fetches a
# session id that does not exist, and the user gets an unexplained error toast
# on a brand-new agent's very first boot.
#
# So the test is for what opencode itself writes, never for the directory (the
# base may have made that), and it is deliberately loose: the database is
# opencode-<channel>.db off the default release channel, and older installs kept
# sessions as JSON under storage/. A stale yes costs only the toast; a stale no
# silently drops the resume and puts the bug back, so prefer the false positive.
set -eu

data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/opencode"
set --
if ls "$data_dir"/opencode*.db >/dev/null 2>&1 || [ -d "$data_dir/storage" ]; then
    set -- --continue
fi

exec opencode . "$@"
