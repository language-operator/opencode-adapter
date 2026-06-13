#!/bin/sh
set -e

# server.mjs honors PORT (default 8080) and OPENCODE_CWD (default /workspace).
exec node /app/server.mjs
