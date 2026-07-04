# Dedicated server build helpers. Run from the client/ directory.
#
# Common overrides:
#   make docker IMAGE=ghcr.io/you/trash-server TAG=dev
#   make server GODOT=/path/to/godot

GODOT     ?= godot
IMAGE     ?= trash-server
TAG       ?= local
PLATFORMS ?= linux/amd64,linux/arm64

.DEFAULT_GOAL := help

.PHONY: help import web server server-amd64 server-arm64 docker run docker-multiarch ci clean

help: ## List available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

import: ## Import project assets (generates the .godot cache)
	$(GODOT) --headless --import

web: ## Export the web build (output in build/web/)
	mkdir -p build/web
	$(GODOT) --headless --export-release "Web" build/web/index.html
	# Ship the favicon assets alongside the export (referenced by head_include).
	cp web/favicon.ico web/favicon-16x16.png web/favicon-32x32.png web/apple-touch-icon.png build/web/

server: server-amd64 server-arm64 ## Export the dedicated server for amd64 + arm64

server-amd64: ## Export the amd64 dedicated server binary
	mkdir -p build/server/amd64
	$(GODOT) --headless --export-release "Linux Server" build/server/amd64/trash_server

server-arm64: ## Export the arm64 dedicated server binary
	mkdir -p build/server/arm64
	$(GODOT) --headless --export-release "Linux Server ARM64" build/server/arm64/trash_server

docker: server-amd64 ## Build the server image for the host architecture
	docker build -t $(IMAGE):$(TAG) .

run: docker ## Build then run the server image (Ctrl-C to stop)
	docker run --rm --network=host $(IMAGE):$(TAG)

docker-multiarch: server ## Build + push a multi-arch image (set IMAGE=ghcr.io/owner/name)
	docker buildx build --platform $(PLATFORMS) -t $(IMAGE):$(TAG) --push .

ci: ## Trigger the GitHub Actions Build workflow remotely (needs gh CLI)
	gh workflow run build.yml

clean: ## Remove local build outputs
	rm -rf build/server build/web build/client
