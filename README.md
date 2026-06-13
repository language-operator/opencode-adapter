# opencode-adapter

The **opencode** runtime for the [Language Operator](https://github.com/language-operator/language-operator),
running as a native Kubernetes workload.

This repository is self-contained — it builds a single combined runtime image and
the Helm chart that registers the `opencode` `LanguageAgentRuntime`. The opencode
TUI runs inside tmux and is fronted by an xterm.js / WebSocket terminal in the
browser, so working with the agent feels like a real terminal session.

## Architecture

The same image plays two roles:

- **Init container** — runs `seed-config.mjs`, which translates the operator's
  `/etc/agent/config.yaml` into opencode's native `/etc/opencode/opencode.jsonc`
  (provider + model + MCP servers). Agent **instructions** are written to
  `instructions.md` and referenced from opencode's `instructions` config field, so
  they load as standing context for every session — no async seeding, no timing.
- **Main container** — runs `server.mjs`, a node-pty + WebSocket bridge. On connect
  it spawns `tmux new-session -A` running `launch-opencode`, which opens the
  opencode TUI bound to `/workspace`. tmux keeps the session alive across browser
  reconnects; the browser side is xterm.js (`index.html`) with clipboard, smart
  copy/paste, and resize.

This mirrors the sibling [`claude-code-adapter`](../claude-code-adapter) — same
terminal bridge, swapping the CLI and launch wrapper.

## Install

Prerequisite: the [`language-operator`](https://github.com/language-operator/language-operator)
chart must be installed first — it provides the `LanguageAgentRuntime` CRD.

```bash
helm install opencode oci://ghcr.io/language-operator/charts/opencode \
  --namespace language-operator
```

Then reference it from a `LanguageAgent`:

```yaml
apiVersion: langop.io/v1alpha1
kind: LanguageAgent
metadata:
  name: my-agent
spec:
  runtime: opencode
```

## Authentication

The runtime sets `auth.enabled: true`, so access is gated entirely by the cluster's
OIDC proxy: when the `LanguageCluster` has auth enabled the operator injects an
oauth2-proxy sidecar in front of the terminal. There is no built-in password — if
the cluster does not enable auth, the terminal is exposed unauthenticated on its
ingress. opencode itself reaches the model gateway via the provider config in
`opencode.jsonc`; no interactive login is needed.

## Development

```bash
make build      # docker build -t ghcr.io/language-operator/opencode-adapter:latest .
make test       # build, then run the in-image smoke tests (/app/test.sh)
make publish    # build and push the image to ghcr.io
make dev        # build, import into k3s, and upgrade the runtime release (inner loop)

helm lint chart
helm template opencode chart
```

## CI

- `build-image.yaml` — builds and pushes the image to `ghcr.io` on push to `main` and `v*` tags.
- `release-chart.yaml` — packages `chart/` and pushes it to `oci://ghcr.io/language-operator/charts`.
- `test.yaml` — builds the image, runs the smoke tests, and lints/templates the chart on every PR.
