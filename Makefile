REGISTRY  := ghcr.io/language-operator
IMAGE     := $(REGISTRY)/opencode-adapter
GIT_SHA   := $(shell git rev-parse --short HEAD)
TAG       ?= $(GIT_SHA)

# Helm release coordinates for the local dev deploy.
NAMESPACE ?= language-operator
RELEASE   ?= opencode

.PHONY: build publish test dev uninstall help

build:
	docker build -t $(IMAGE):$(TAG) -t $(IMAGE):latest .

publish: build
	docker push $(IMAGE):$(TAG)
	docker push $(IMAGE):latest

test: build
	docker run --rm --entrypoint sh $(IMAGE):$(TAG) /app/test.sh

# Build, load the adapter image into k3s, and upgrade the runtime release
# referencing the freshly built image (development inner loop).
#
# Requires the language-operator chart (LanguageAgentRuntime CRD) to be installed
# first — e.g. `make dev` in the language-operator repo. The git-sha tag changes
# the LanguageAgentRuntime spec on every build, so the operator reconciles agent
# pods onto the new adapter image; pullPolicy=Never uses the imported copy.
dev: build
	docker save $(IMAGE):$(TAG) | sudo k3s ctr images import -
	@# The opencode LanguageAgentRuntime is cluster-scoped and may already exist,
	@# owned by the umbrella language-operator-runtimes chart. Adopting it into this
	@# release leaves helm's 3-way merge unable to update the image, so delete it
	@# first and let helm recreate it fresh with the locally built adapter image.
	kubectl delete languageagentruntime $(RELEASE) --ignore-not-found --wait
	helm upgrade --install $(RELEASE) chart \
		--namespace $(NAMESPACE) \
		--create-namespace \
		--set adapter.image.repository=$(IMAGE) \
		--set-string adapter.image.tag=$(TAG) \
		--set adapter.image.pullPolicy=Never \
		--wait --timeout 2m

# Uninstall the runtime release.
uninstall:
	helm uninstall $(RELEASE) --namespace $(NAMESPACE) --ignore-not-found

help:
	@echo "Targets:"
	@echo "  build      - Build the adapter image ($(IMAGE):$(TAG) + :latest)"
	@echo "  test       - Build, then run test.sh inside the image"
	@echo "  publish    - Build and push $(TAG) + latest to the registry"
	@echo "  dev        - Build, import into k3s, and upgrade the runtime release (inner loop)"
	@echo "  uninstall  - Uninstall the runtime release"
