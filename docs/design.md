# Container Images Design

This document describes the design principles behind the S2I OpenStack container
images. For repository structure, build commands, and contributor workflows, see
the [developer guide](developer-guide.md).

The full upstream design document, covering the broader container-images vision
including CI integration, operator workflows, and tested-tag promotion, lives at
[dev-docs/container-images-design.md][upstream-design]. This document focuses on
the Containerfile design principles and build-time concerns specific to this
repository.

[upstream-design]: https://github.com/openstack-k8s-operators/dev-docs/blob/s2i/container-images-design.md

## Design Goals

1. **Source-based builds** -- Build OpenStack services directly from upstream git
   repositories rather than pre-built packages. This allows building from any
   combination of branches, tags, or in-review patches for the main service, its
   plugins, and its dependencies.

2. **Kolla-compatible runtime interface** -- The kolla entrypoint,
   configuration, and user management scripts are available in the base image
   but their usage is optional. Services can use them for compatibility with
   existing openstack-k8s-operators deployments or provide their own entrypoint
   and configuration files in the expected locations.

3. **Flat image hierarchy** -- A single `openstack-base` image, with all service
   images built directly on top. No intermediate per-project layers.

4. **Smart consolidation** -- Services sharing the same Python package and
   similar non-Python dependencies share a single image. Services with
   significantly different system dependencies get separate images.

5. **Multi-stage builds** -- Build tools, compilers, and source code are
   confined to the build stage and discarded. The final image contains only
   runtime dependencies.

6. **Reproducibility** -- Every source repo is pinned to a specific commit hash.
   Upper-constraints are pinned to a specific commit. Dependency lockfiles are
   generated with `pip-compile` and committed. Builds from the same inputs
   produce the same dependency set.

7. **CI integration** -- The repository can be easily integrated into CI
   workflows to validate changes both in the openstack-k8s-operators and in
   third-party jobs for upstream OpenStack repositories.

8. **Full source build support** -- Containerfiles accept a `PIP_NO_BINARY`
   build argument so that all Python dependencies can be compiled from source
   rather than installed from pre-built wheels. This is not the default but
   enables use cases that require building every dependency from source (e.g.,
   for license compliance or platform-specific optimizations). Set
   `PIP_NO_BINARY=:all:` at build time to activate this mode.

## Containerfile Principles

### Base image

The `openstack-base` image is a single-stage build on UBI 10 (`ubi-minimal`). It
installs system packages, Python, pip, the kolla helper scripts, and the common
Python dependencies shared across all services. Every service image inherits from
it via `--build-arg BASE_IMAGE`.

### Service images

Service images use a multi-stage build. All compilation, wheel building, and
source handling happen in the build stage. The runtime stage carries only the
pre-built artifacts and runtime dependencies, keeping the final image free of
compilers, headers, and source code.

### Dependency files

Each image declares its binary (system) and Python dependencies in a set of
pre-defined plain-text files, separated by build-time vs. runtime scope. See the
[developer guide](developer-guide.md#dependency-files) for the full list and
format.

### Source overrides

Patched or replaced dependencies can be placed under `src/overrides/<pkg>/`
without any `sources.txt` entry. The filtered constraints file excludes these
packages so the overridden version takes precedence.

### Configuration files

Config files come from three sources: the upstream source tree (copied during the
build stage), generated artifacts (e.g., `oslo-config-generator` output), and
manually maintained files in `config/` directories. Each file is listed
explicitly in the Containerfile with full source and destination paths -- no
directory-level copies -- so the build fails immediately if a file is missing.

Examples of files to include: sudoers rules, rootwrap configs, api-paste.ini,
default service config, policy files, etc.

Examples of files to exclude: systemd units, logrotate configs, sysv init
scripts, tmpfiles.d entries, etc.

## CI, Validation, and Publication

The repository runs periodic CI jobs that propose PRs updating the pinned
commit hashes in `sources.txt` to the latest upstream commits, and publishes
validated images post-merge to `quay.io/openstack-s2i-containers/`.

The full picture — the GitHub Actions and Zuul jobs that validate changes in
this repository, the daily `update-sources` automation, the post-merge
build-and-push job defined in the rdoproject.org config repository, and the
per-service component jobs — is documented in
[ci-validation-publication.md](ci-validation-publication.md), including the
published tag scheme (`<stream>-latest`, `<stream>-<sha>`,
`sha256-<manifest-digest>`), the OCI labels, and the digest catalog
(`content-set.yaml`).
