# opencode-adapter

The **opencode** runtime for the [Language Operator](https://github.com/language-operator/language-operator),
running as a native Kubernetes workload.

This repository is self-contained — it builds the adapter init image and the
Helm chart that registers the `opencode` `LanguageAgentRuntime`. The main
container runs the upstream `ghcr.io/anomalyco/opencode` image; this repo only
provides the init/adapter that translates the operator's config into opencode's
native format.

## What's here

- **Adapter image** (`ghcr.io/language-operator/opencode-adapter`) — an init
  container that writes `/etc/opencode/opencode.jsonc` (provider + MCP config)
  from the operator's `/etc/agent/config.yaml`.
- **Chart** (`chart/`) — renders the cluster-scoped `opencode`
  `LanguageAgentRuntime`. Published to `oci://ghcr.io/language-operator/charts/opencode`.

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
oauth2-proxy sidecar in front of opencode. There is no built-in password — if the
cluster does not enable auth, opencode is exposed unauthenticated on its ingress.

## Development

```bash
make build      # docker build -t ghcr.io/language-operator/opencode-adapter:latest .
make test       # build, then run the in-image smoke tests (/app/test.sh)
make publish    # build and push the image to ghcr.io

helm lint chart
helm template opencode chart
```

## CI

- `build-image.yaml` — builds and pushes the adapter image to `ghcr.io` on push to `main` and `v*` tags.
- `release-chart.yaml` — packages `chart/` and pushes it to `oci://ghcr.io/language-operator/charts`.
- `test.yaml` — builds the image, runs the smoke tests, and lints/templates the chart on every PR.
