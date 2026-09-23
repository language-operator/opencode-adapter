# -----------------------------------------------------------------------------
# opencode adapter.
#
# The OS layer, the web terminal, tini, and the /etc/agent/config.yaml ETL all
# live in coding-runtime. What is left here is the opencode CLI plus the three
# files that describe it to the base: a manifest, an emitter, and a launcher.
#
# The base is pinned by tag *and* digest. Never :latest, and never a `main`
# build — metadata-action stamps those with the version literal `main`, which no
# `requires.codingRuntime` range can satisfy, so every boot would warn about a
# version mismatch that is not real.
# -----------------------------------------------------------------------------
ARG BASE=ghcr.io/language-operator/coding-runtime:0.1.0@sha256:9ed651b2c661d80622b3c5a15b454b4dffe9cae3bbd7643f21b592690afc4cb9
ARG OPENCODE_VERSION=1.18.32

FROM ${BASE}
ARG OPENCODE_VERSION

# opencode CLI (TUI). The npm package fetches the platform-native binary on
# install. Pinned — do not track `latest`, so runtime behaviour is reproducible.
USER root
RUN npm install -g --no-audit --no-fund "opencode-ai@${OPENCODE_VERSION}" \
    && npm cache clean --force

# runtime.json  — what this adapter is: config dir, serving surface, tmux launch.
# emit.mjs      — normalized operator config -> opencode.jsonc.
# launch-opencode — what tmux runs inside the terminal.
COPY runtime.json /etc/coding-runtime/runtime.json
COPY emit.mjs /opt/adapter/emit.mjs
COPY --chmod=755 launch-opencode.sh /usr/local/bin/launch-opencode

# The operator pins the agent container to uid 1000 with no override, and the
# base already has a matching passwd entry. Do not create a user here.
USER node
