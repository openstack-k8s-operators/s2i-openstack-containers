STREAM   ?= master
TARGET   ?=
REGISTRY ?= localhost
BASE_IMAGE = $(REGISTRY)/openstack/openstack-base:$(STREAM)-latest

.PHONY: help check-deps ensure-base base build build-all lint

help:
	@echo "Usage: make <target> [STREAM=master] [TARGET=<project/image>]"
	@echo ""
	@echo "Build targets:"
	@echo "  base          Build the base container image"
	@echo "  build         Build a specific image  (requires TARGET=<project/image>)"
	@echo "  build-all     Build all container images"
	@echo ""
	@echo "Lint targets:"
	@echo "  lint          Run pre-commit on all files"
	@echo ""
	@echo "Utility targets:"
	@echo "  check-deps    Verify all required tools are installed"
	@echo "  ensure-base   Build base image if not present locally"
	@echo ""
	@echo "Examples:"
	@echo "  make build TARGET=tempest/tempest"
	@echo "  make build TARGET=cyborg/cyborg STREAM=hibiscus"
	@echo "  make build-all"

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------

check-deps:
	@ok=true; \
	check() { \
	    if ! command -v "$$1" >/dev/null 2>&1; then \
	        echo "  MISSING  $$1  —  $$2"; \
	        ok=false; \
	    else \
	        echo "  OK       $$1"; \
	    fi; \
	}; \
	echo "Checking required tools..."; \
	check buildah      "sudo dnf install buildah"; \
	check pre-commit   "pip install pre-commit"; \
	check git          "sudo dnf install git"; \
	check python3      "sudo dnf install python3"; \
	check pip3         "sudo dnf install python3-pip"; \
	check pip-compile  "pip install pip-tools"; \
	check pybuild-deps "pip install pybuild-deps"; \
	if [ "$$ok" = "false" ]; then \
	    echo ""; \
	    echo "Install missing tools and re-run 'make check-deps'."; \
	    exit 1; \
	fi; \
	echo "All dependencies satisfied."

# ---------------------------------------------------------------------------
# Base image
# ---------------------------------------------------------------------------

ensure-base: check-deps
	@if ! buildah images -q $(BASE_IMAGE) | grep -q .; then \
	    echo "Base image $(BASE_IMAGE) not found — building it now..."; \
	    STREAM=$(STREAM) REGISTRY=$(REGISTRY) ./build.sh build base; \
	else \
	    echo "Base image $(BASE_IMAGE) exists."; \
	fi

base: check-deps
	STREAM=$(STREAM) REGISTRY=$(REGISTRY) ./build.sh build base

# ---------------------------------------------------------------------------
# Container builds
# ---------------------------------------------------------------------------

build: ensure-base
	@if [ -z "$(TARGET)" ]; then \
	    echo "ERROR: TARGET is required. Example: make build TARGET=tempest/tempest"; \
	    exit 1; \
	fi
	STREAM=$(STREAM) REGISTRY=$(REGISTRY) ./build.sh build $(TARGET)

build-all: ensure-base
	STREAM=$(STREAM) REGISTRY=$(REGISTRY) ./build.sh build all

# ---------------------------------------------------------------------------
# Linting
# ---------------------------------------------------------------------------

lint: check-deps
	pre-commit run --all-files
