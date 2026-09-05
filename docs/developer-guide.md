# S2I OpenStack Containers Developer Guide

This guide documents the repository's current build, source-maintenance, and
contributor workflows. For a concise project introduction, see the root
[`README.md`](../README.md). For a short testing entry point, see
[`TESTING.md`](TESTING.md). For dropping unwanted upstream dependencies, see
[`excluding-requirements.md`](excluding-requirements.md). To wire a live
deploy+tempest job on an operator repository, see
[`operator-onboarding.md`](operator-onboarding.md).

Source-to-image container builds for OpenStack services on UBI 10 (ubi-minimal).

Services are built from pinned upstream source using multi-stage Containerfiles.
All Python dependencies are installed via pip from wheels compiled in a build
stage, constrained by a `pip-compile`-generated lockfile. System (RPM)
dependencies are installed via `microdnf`.

## Repository structure

```
build.sh                          # Build orchestrator
containers/
  base/                           # Base image (openstack-base)
    Containerfile
    bindeps.txt                   # System packages for base image
    pythondeps.txt                # Python packages for base image
    rpms.repo                     # DNF repo config for RPM lockfile
    sources.txt                   # Pinned upstream sources (upper-constraints)
    scripts/                      # Kolla helper scripts (uid_gid_manage, kolla_start, ...)
  <project>/                      # e.g., watcher
    sources.txt                   # Pinned sources for this project (service repo + upper-constraints)
    src/                          # Cloned sources (auto-managed, .gitkeep only in git)
    rpms.in.yaml                  # [generated] RPM packages for rpm-lockfile-prototype - used downstream
    requirements.lock.<stream>    # [generated] pip-compile lockfile
    buildrequirements.lock.<stream> # [generated] pybuild-deps build lockfile
    upper-constraints.txt.<stream># [generated] upstream constraints snapshot
    <image>/                      # e.g., watcher, watcher-api
      Containerfile
      bindeps.txt                 # Runtime system packages
      builddeps.txt               # Build-stage system packages
      pythondeps.txt              # Extra Python packages (oslo.db[mysql], etc.)
      pythonbuilddeps.txt         # Build-stage Python packages (pbr, etc.)
      src/                        # Image-specific sources (if any)
```

## Source management

Source code for each service is cloned into `src/` directories and made
available to the Containerfile build context. `build.sh` supports two
levels of `sources.txt` and `src/` directories:

- **Project level** (`containers/<project>/sources.txt` and
  `containers/<project>/src/`) -- Sources shared by all images in the
  project. This is where the main service repo lives (e.g., `watcher`).
- **Image level** (`containers/<project>/<image>/sources.txt` and
  `containers/<project>/<image>/src/`) -- Sources specific to a single
  image. Use this when one image needs an extra dependency that other
  images in the same project don't need.

During a build, the Containerfile merges both levels into `/src/` inside
the container:

```dockerfile
COPY src/ /src/           # project-level sources
COPY <image>/src/ /src/   # image-level sources (merged on top)
```

The build context is set to `containers/<project>/`, so both directories
are reachable.

### Automatic cloning and cleanup

When running `build` or `update-sources`, `build.sh` reads `sources.txt`
at both levels and clones any repo that doesn't already exist in `src/`.
These auto-cloned repos are tracked and **removed automatically on exit**
(via an EXIT trap), so `src/` directories stay clean in the repo (only a
`.gitkeep` is committed).

Git source caching is optional and is separate from the package caches
described below. Enable it for local source operations with:

```bash
SOURCE_CACHE=true STREAM=master tox -ebuild -- nova
```

When enabled, repository objects are retained as bare repositories under
`.tmp/source_cache/<host>/<organization>/<repository>.git`. Branch and tag refs
are refreshed once per repository in each `build.sh` invocation, then a fast
local clone is materialized at the exact pinned commit. The disposable clone is
removed on exit while the bare cache remains for later invocations. Set
`SOURCE_CACHE_DIR` to override the cache location. Source caching defaults to
`false`; direct temporary clones retain the previous behavior when disabled.

To discard all cached Git objects and make the next cached source operation
fetch them again, remove the cache directory:

```bash
rm -rf .tmp/source_cache
```

If a checkout already exists in `src/` (e.g., a local development clone),
`build.sh` uses it as-is and does **not** remove it on exit. This lets you
work on a local branch without `build.sh` overwriting it.

This mechanism can be used to build containers with any arbitrary content,
including unmerged commits. Place or symlink the desired source under
`containers/<project>/src/<name>/` (or `containers/<project>/<image>/src/<name>/`
for image-specific sources) before running `build.sh build`. The pinned hash in
`sources.txt` is ignored for that package. This works both locally and in CI
workflows -- for example, a Zuul or GitHub Actions job can clone a patch under
review into `src/` and build containers that include the unmerged change.

### Source overrides

To patch or replace a transitive dependency, place the modified source in
`containers/<project>/src/overrides/<pkg>/`. The build stage picks up
everything under `src/overrides/` automatically -- no `sources.txt` entry
is needed. The filtered constraints file excludes source-built packages so
the overridden version takes precedence over PyPI.

### Excluding upstream requirements

To drop a dependency that an upstream service lists in its `requirements.txt`
but that we do not want in our images (e.g. `awscurl` and its heavy transitive
tree), add the package name to `containers/<project>/excluded-requirements.txt`
and re-run `update-sources`. See
[`excluding-requirements.md`](excluding-requirements.md) for the full workflow.

## Manually maintained files

These files are created and updated by hand. `build.sh` reads them but
never overwrites them.

| File | Location | Purpose |
|------|----------|---------|
| `Containerfile` | `containers/base/`, `containers/<project>/<image>/` | Multi-stage build definition |
| `sources.txt` | `containers/base/`, `containers/<project>/` | Pinned source repos and branches per stream |
| `bindeps.txt` | base and each image | Runtime RPM packages (installed via `microdnf`) |
| `builddeps.txt` | each image | Build-stage RPM packages (compilers, `-devel` headers) |
| `pythondeps.txt` | base and each image | Extra pip packages beyond the service's `requirements.txt` |
| `pythonbuilddeps.txt` | each image | Build-stage pip packages (e.g., `pbr`) |
| `rpms.repo` | `containers/base/` | DNF repo configuration for RPM lockfile |
| `scripts/*` | `containers/base/scripts/` | Kolla helper scripts (`kolla_start`, `uid_gid_manage`, etc.) |
| `config/*` | `containers/service/` | Config files manually maintained out of upstream repo |

## Streams

A **stream** is a coherent set of source repos at specific commits. Typical
streams are `master` (tracking upstream HEAD) and `stable` (tracking a
stable branch like `stable/2026.1`). Different projects in the same stream
may follow different branches.

Each stream gets its own set of generated files (lockfile, constraints).
Multiple streams can coexist in the same repo -- they are distinguished
by the `.<stream>` suffix on generated files.

### sources.txt format

Each line defines a source repo pinned to a specific commit, grouped by stream:

```
<stream> <name> <repo-url> <branch-to-follow> <pinned-hash>
```

Example:

```
master upper-constraints https://opendev.org/openstack/requirements.git master 4bb8ff9ad664e832d78139e23f5933cca6054d35
master watcher https://opendev.org/openstack/watcher.git master 4abcf29a3ec323a6df3f567d7485b320354af4f4
stable upper-constraints https://opendev.org/openstack/requirements.git stable/2026.1 c4c55d5279d824dc261a43ac51b56146ccc4dd4f
stable watcher https://opendev.org/openstack/watcher.git stable/2026.1 ba7b161dc24a6f2f1f7b7a2a529b8d93c65fee6c
```

The special name `upper-constraints` tells `build.sh` to fetch
`upper-constraints.txt` from the repo instead of cloning the full repo
into `src/`. The upper-constraints.txt file will be used as constraints
file via a lock file automatically created using pip-compile.

### Dependency files

Each image directory has four dependency files, all plain text with one
entry per line (blank lines and `#` comments are ignored):

- **`builddeps.txt`** -- System packages needed during the build stage only
  (compilers, header files). Not present in the final image.
- **`pythonbuilddeps.txt`** -- Python packages needed during the build stage.
- **`bindeps.txt`** -- System packages installed in the final runtime image.
- **`pythondeps.txt`** -- Extra Python packages installed via pip in the
  final image (database drivers, caching backends, CLI clients).

Entries in `bindeps.txt` and `builddeps.txt` can use either a plain package
name (e.g. `python3-cryptography`) or a full NVR
(name-version-release, e.g. `python3-cryptography-43.0.0-4.el10`) to pin a
specific RPM version. When a `python3-*` entry uses a full NVR, the
version-release suffix is automatically stripped to derive the pip package
name for lockfile filtering.

The base image (`containers/base/`) also has `bindeps.txt` and `pythondeps.txt`
for packages shared across all service images.

## Auto-generated files

These files are created by `build.sh update-sources` and refreshed by
`build.sh update-lockfiles`. Speculative CI refreshes lockfiles (not
`rpms.in.yaml`) with `build.sh sync-locks` without rewriting `sources.txt`.
They should be committed to the repository but never edited by hand.

| File | Location | Generated from |
|------|----------|----------------|
| `upper-constraints.txt.<stream>` | `containers/<project>/`, `containers/base/` | Fetched from the `upper-constraints` entry in `sources.txt` |
| `requirements.lock.<stream>` | `containers/<project>/`, `containers/base/` | `pip-compile` against all `requirements.txt` + `pythondeps.txt` + `pythonbuilddeps.txt`, constrained by `upper-constraints.txt.<stream>` |
| `buildrequirements.lock.<stream>` | `containers/<project>/`, `containers/base/` | `pybuild-deps compile` against `requirements.lock.<stream>` |
| `rpms.in.yaml` | `containers/<project>/`, `containers/base/` | Union of all `bindeps.txt` + `builddeps.txt` across images in the project |

When the stream being updated matches `DEFAULT_STREAM` (default: `master`),
un-suffixed symlinks are also created:

```
requirements.lock -> requirements.lock.master
buildrequirements.lock -> buildrequirements.lock.master
upper-constraints.txt -> upper-constraints.txt.master
```

These symlinks allow Containerfiles to use `ARG CONSTRAINTS_FILE=requirements.lock`
without needing to know which stream is active.

**Important:** Whenever you modify `pythondeps.txt`, `pythonbuilddeps.txt`,
`bindeps.txt`, or `builddeps.txt`, you must re-run
`build.sh update-lockfiles` (or `tox -e update-lockfiles`) to regenerate the
lockfiles and `rpms.in.yaml`. If you modify `sources.txt`, use
`build.sh update-sources` instead (it also regenerates lockfiles).
Failing to do so will cause builds to use stale dependency pins.

## Prerequisites

### System packages

- `git` -- cloning source repos
- `buildah` -- building container images
- `podman` -- running and inspecting built images

Install all at once:

```bash
./build.sh install-deps
```

This runs `sudo dnf install` (or the appropriate package manager) for the
system packages and `pip install pip-tools` for the Python dependencies.

### Python packages

- `pip-tools` -- provides `pip-compile`, used by `update-sources` and
  `sync-locks` to generate lockfiles
- `pybuild-deps` -- used by `update-sources` and `sync-locks` to generate
  build-requirements lockfiles

If using tox (recommended), Python dependencies are installed automatically
in the tox virtualenv.

## Workflow

### Using tox

Tox manages a virtualenv with the required Python dependencies and passes
through all relevant environment variables (`STREAM`, `REGISTRY`, `TAG`, etc.):

```bash
# Update sources for all projects
STREAM=master tox -eupdate-sources

# Regenerate lockfiles after modifying dependency files
STREAM=master tox -eupdate-lockfiles
STREAM=master tox -eupdate-lockfiles -- cinder

# Relock staged/current src trees without advancing pins
STREAM=master tox -esync-locks -- heat

# Build all images
STREAM=master tox -ebuild
STREAM=master tox -ebuild -- manila

# Run any build.sh command via the generic 'custom' target
STREAM=master tox -ecustom -- update-sources watcher
STREAM=stable tox -ecustom -- build watcher/watcher-base
tox -ecustom -- list
```

### Optional local package caches

A developer-only Compose stack under `tools/local-package-cache/` provides
[Proxpi](https://github.com/EpicWink/proxpi) for Python downloads and
Squid for plain-HTTP RPM repository traffic. Package caching is disabled
by default and affects only local `build` and `build-parallel` actions when
`LOCAL_PACKAGE_CACHE=true`. Normal builds and Konflux builds remain unchanged.
The cache-service lifecycle is intentionally separate from `build.sh`.

`podman compose` requires a Compose provider. On CentOS Stream, install and
verify `podman-compose` with:

```bash
sudo dnf install podman-compose
podman compose version
```

Start the services, verify them, and opt a build into package caching:

```bash
LOCAL_CACHE_BIND_ADDRESS=0.0.0.0 \
  podman compose -f tools/local-package-cache/compose.yaml up -d
podman compose -f tools/local-package-cache/compose.yaml ps
LOCAL_PACKAGE_CACHE=true STREAM=master tox -ebuild -- glance
```

Compose creates and manages the named Proxpi and Squid volumes declared
in `compose.yaml`; do not create those volumes manually. They persist downloaded
content across container replacement and ordinary `down`/`up` cycles.

Build containers reach the published ports through
`host.containers.internal`. Rootless containers generally cannot reach services
bound only to host loopback, so the example publishes on all host interfaces.
Binding to `0.0.0.0` can expose unauthenticated cache services to the local
network; use host firewall rules or set `LOCAL_CACHE_BIND_ADDRESS` to a more
specific reachable host address when possible. The Compose file defaults to
`127.0.0.1` for safety when no address is specified.

The build fails before invoking Buildah when `LOCAL_PACKAGE_CACHE=true` and
either service is unavailable. Endpoint overrides are available through
`LOCAL_PYPI_INDEX_URL`, `LOCAL_PYPI_TRUSTED_HOST`, `LOCAL_RPM_PROXY`,
`LOCAL_PYPI_HEALTH_URL`, and `LOCAL_RPM_HEALTH_URL`.

Stop the services while retaining downloaded packages:

```bash
podman compose -f tools/local-package-cache/compose.yaml down
```

Delete the services and their package-cache volumes for a cold package fetch:

```bash
podman compose -f tools/local-package-cache/compose.yaml down -v
```

This proof of concept caches external downloads only. It does not cache wheels
built from the OpenStack source checkouts. HTTPS repositories normally pass
through without TLS interception. Squid fetches the HTTPS origin behind
`mirror.stream.centos.org` itself so the existing HTTP repository URLs remain
cacheable.

### Initial setup

1. Create `containers/<project>/sources.txt` with entries for each stream.
2. Create image directories under `containers/<project>/<image>/` with
   a `Containerfile` and the four dependency files.
3. Run `update-sources` to generate lockfiles and constraints.

### Updating sources (pinning to latest upstream)

```bash
STREAM=master ./build.sh update-sources <project-or-all>
```

This will:
1. Clone each source repo at the branch tip to resolve the latest commit hash.
2. Update `sources.txt` with the new pinned hashes.
3. Fetch `upper-constraints.txt` from the requirements repo.
4. Generate `rpms.in.yaml` from all `bindeps.txt` + `builddeps.txt` files.
5. Run `pip-compile` to generate `requirements.lock.<stream>`.
6. Run `pybuild-deps compile` to generate `buildrequirements.lock.<stream>`.
7. Create default-stream symlinks if `STREAM == DEFAULT_STREAM`.

Auto-cloned repos in `src/` are cleaned up automatically on exit.
Pre-existing checkouts in `src/` are used as-is and not removed.

To regenerate lockfiles without updating pinned hashes (steps 1--3 are
skipped), see the **Updating lockfiles** section below.

Python environment markers are evaluated by the generator interpreter, so
other Python minor versions can produce a different dependency set. The tox
environment rejects non-3.12 interpreters and pins the generator tool versions.
Generated lock headers, resolver annotations, and package-index directives are
removed because they describe the generation environment rather than the
resolved dependency set.

### Updating lockfiles (after modifying dependency files)

**When to use:** After you add, remove, or change any entry in
`pythondeps.txt`, `pythonbuilddeps.txt`, `bindeps.txt`, or `builddeps.txt`,
run `update-lockfiles` to regenerate the lockfiles and `rpms.in.yaml`.
Unlike `update-sources`, this command does **not** clone any upstream repos
and does **not** modify `sources.txt` -- it only refreshes the generated
files using the existing constraints and lockfile as inputs.

```bash
STREAM=master ./build.sh update-lockfiles <project-or-all>
```

Or via tox:

```bash
STREAM=master uvx --python 3.12 tox -eupdate-lockfiles
STREAM=master uvx --python 3.12 tox -eupdate-lockfiles -- watcher
```

This will:
1. Generate `rpms.in.yaml` from all `bindeps.txt` + `builddeps.txt` files.
2. Regenerate `requirements.lock.<stream>` using the existing lockfile plus
   any `pythondeps.txt` / `pythonbuilddeps.txt` files, constrained by
   `upper-constraints.txt.<stream>`.
3. Regenerate `buildrequirements.lock.<stream>` via `pybuild-deps compile`.
4. Create default-stream symlinks if `STREAM == DEFAULT_STREAM`.

**Requirements:** The project must have been through `update-sources` at
least once so that `upper-constraints.txt.<stream>` and
`requirements.lock.<stream>` already exist.

For pure RPM projects (no `sources.txt` -- see below), `update-lockfiles`
only regenerates `rpms.in.yaml` and skips lockfile generation.

### Relocking staged sources (speculative CI)

**When to use:** After Zuul stages patched checkouts into `src/`, regenerate
lockfiles so the image build resolves against the staged `requirements.txt`
and current upper-constraints. Unlike `update-sources`, this does **not**
advance unstaged sibling pins or rewrite `sources.txt`. Unlike
`update-lockfiles`, it compiles from `src/*/requirements.txt` rather than
from the existing lockfile.

```bash
STREAM=master ./build.sh sync-locks <project-or-all>
REQUIREMENTS_SRC=/path/to/requirements STREAM=master ./build.sh sync-locks heat
```

Or via tox:

```bash
STREAM=master uvx --python 3.12 tox -esync-locks -- heat
```

This will:
1. Refresh `upper-constraints.txt.<stream>` from `REQUIREMENTS_SRC` or the
   stream branch tip.
2. Clone any missing sources at the committed pin; leave existing `src/`
   trees in place.
3. Generate `requirements.lock.<stream>` from current source requirements
   plus `pythondeps.txt` / `pythonbuilddeps.txt`.
4. Generate `buildrequirements.lock.<stream>` via `pybuild-deps compile`.
5. Create default-stream symlinks if `STREAM == DEFAULT_STREAM`.

### Pure RPM projects

Projects that have no `sources.txt` are treated as pure RPM-based images.
They have no Python source repos, no upper-constraints, and no lockfiles.
Both `update-sources` and `update-lockfiles` will still generate
`rpms.in.yaml` from their `bindeps.txt` and `builddeps.txt` files, but
skip all lockfile-related steps. Builds for these projects skip source
cloning and constraints entirely.

### Building images

```bash
# Build all images for a stream
STREAM=master ./build.sh build all

# Build a single project (all its images)
STREAM=master ./build.sh build watcher

# Build a specific image
STREAM=master ./build.sh build watcher/watcher-api
```

Build order: the base image is always built first when targeting `all`.
Service images use the base image via `--build-arg BASE_IMAGE`.

### Pushing images

```bash
STREAM=master REGISTRY=quay.io NAMESPACE=myorg ./build.sh push all
```

All image tags are verified to exist locally before any push begins.

### Listing images

```bash
./build.sh list
```

## Zuul content provider

The `s2i-openstack-container-content-provider` job runs on the
CentOS Stream 10 nodeset host named `builder`. All host preparation, registry
validation, builds, publication, result generation, and cleanup target that
host explicitly. The Zuul executor controls Ansible but does not perform those
mutations.

The provider copies the RDO base job's `/etc/pip.conf` into a job-local file
and mounts it into Buildah so Python downloads use the provider mirror. It also
can run an ephemeral Squid container directly with Podman. Squid caches direct
upstream HTTP traffic or can sit in front of the provider's CentOS mirror. The
cache is published on the disposable builder and Buildah RUN steps reach it through
`host.containers.internal`. Proxy values are passed as build arguments so
host-side base-image pulls are not routed through the package cache. The cache
intentionally listens without authentication on all interfaces of the
disposable CI builder. Plain-HTTP CentOS Stream requests can be remapped to the
provider's CentOS mirror. Otherwise, Squid rewrites plain-HTTP CentOS requests
to the upstream HTTPS origin before fetching them, without intercepting client
TLS. The job does not consume host RPM repository files or require
`podman-compose`. Post-run cleanup
removes the cache container, its volumes, and generated configuration.
Persistent source caching is explicitly disabled
because Zuul already stages speculative source trees and the builder is
disposable.

`s2i_ci_use_provider_pip_mirror` controls whether the parent-provided
`pip.conf` is mounted, `s2i_ci_enable_rpm_cache` controls the RPM proxy, and
`s2i_ci_rpm_cache_use_provider_mirror` controls its optional CentOS Stream
backend remap. Disabling Squid leaves RPM repository access unchanged;
the provider mirror still applies to Python downloads when its pip option is
enabled. The content-provider currently disables the RPM backend remap because
the Vexxhost mirror does not carry the CentOS Stream 10 SIG repositories used
by these images. Squid therefore caches their original repository URLs.
Collapsed forwarding combines concurrent requests for the same object, and
`repomd.xml` remains fresh for the two-hour job despite DNF cache-bypass
headers. Squid access and error logs are staged under
`zuul-output/logs/squid/` for troubleshooting.

In this repository the provider defaults to `all`, so every maintained image
is built from its exact `sources.txt` pins. A child job can set `s2i_ci_images`
to an explicit list of image targets; the provider resolves the selection
through `build.sh` and publishes only that set. The caller is responsible
for including `base` in the list if service images depend on it.

To compose the provider in an operator repository, define
`<service>-s2i-content-provider` that parents this job, add the
container repository to `required-projects`, and override `s2i_ci_images`
with that service's image targets. The matching deploy job is
`<service>-s2i-tempest` (see
[`operator-onboarding.md`](operator-onboarding.md)). Zuul places those
projects in the shared buildset workspace. Speculative source staging
is described in [Speculative builds](#speculative-builds-zuul-integration).

### This repository's github-check pipeline

This repo's own check pipeline is not the operator graph. Molecule runs
on its own. The image jobs are:

```
s2i-openstack-container-content-provider
        (pauses; buildset registry stays up)
        |
        +-- s2i-openstack-container-consumer-smoke
        |     fresh CentOS node: pull, inspect, resolve deployment keys
        |
        v
s2i-openstack-deploy-validation  (non-voting CRC/EDPM + tempest)
  depends on the content provider AND consumer-smoke
```

`s2i-openstack-deploy-validation` lists **both** dependencies on
purpose:

- The content provider, so `zuul_return` artifacts stay in scope and
  the paused registry is not torn down in `post.yaml` while CRC still
  needs it.
- Consumer-smoke, so a malformed return, an unreachable registry, an
  unpullable image, or a deployment key that does not resolve skips the
  CRC/EDPM nodeset. Smoke is a few minutes; deploy-validation is not.

Do not drop the content-provider line and depend only on smoke. Do not
set smoke as the `parent:` of `s2i-openstack-deploy-validation`; they
are different job families. Use Zuul `dependencies`.

Operator `github-check` pipelines follow
[`operator-onboarding.md`](operator-onboarding.md) instead of copying
this graph.

### Image deployment metadata

The repository-level `containers/image-mappings.yaml` associates exact build
targets with OpenStackVersion custom-image fields. Unlisted targets have no
deployment mapping but are still built and returned. The consolidated
`watcher/watcher-base` image declares:

```yaml
openstack_version:
  custom_container_images:
    watcher/watcher-base:
      - watcherAPIImage
      - watcherApplierImage
      - watcherDecisionEngineImage
```

All three keys resolve to the same exact `openstack-watcher-base` reference.
The image contains the API, applier, and decision-engine entry points and the
union of their runtime dependencies. Watcher is intentionally not split into
process-specific images.

Unlisted targets are still built. They are absent from the central mapping
on purpose:

- `base` is not a service image.
- `cyborg/*` is not wired into the default control plane yet.
- `tempest` and `ansible-test` are test images, not control-plane services.
- `cinder/cinder-volume` and `manila/manila-share` must be set as
  `cinderVolumeImages` / `manilaShareImages` backend maps, which this
  scalar mapping format cannot express.
- s2i does not build `nova-compute`, `nova-conductor`, `nova-scheduler`,
  `nova-novncproxy`, or placement. Those OpenStackVersion fields stay on
  operator defaults.

A child job may provide `s2i_ci_image_mappings` as a mapping from a selected
image target to a replacement list of keys. Replacement is per image rather
than additive. The provider records whether each effective list came from
tracked or inventory metadata and rejects malformed values, unknown or unbuilt
image targets, empty key strings, duplicate keys, and a key assigned to more
than one image.

### Registry and returned data

The provider starts or inherits a Zuul buildset registry, validates push and
pull with a dedicated UBI tag, builds and pushes the selected image set, and
pulls every exact result back. Credentials and certificate data remain in
Zuul secret data. Returned public diagnostics use the buildset registry's
reachable host or IP and port, never the builder-local registry alias.

`s2i_ci_content.images` contains every exact successful reference, including
base and other unmapped images. The partial
`s2i_content_provider_os_custom_container_images` map contains only effective
keys joined to exact successful references. The legacy global OS registry URL
remains the neutral `null` sentinel, while its namespace/tag and gating-repo
fields remain empty or false because this selective provider does not publish a
complete OpenStack image namespace. `s2i_cifmw_build_images_output`
remains an empty mapping and is not repurposed for service images.

All returned variables use the `s2i_content_provider_` or `s2i_cifmw_` prefix
to avoid colliding with the standard `openstack-k8s-operators-content-provider`
when both run as parents of the same consumer job.

Intended references are written before build mutation. Post-run cleanup
removes only those exact Podman pullback and Buildah build tags, verifies exact
absence, and removes a buildset registry only when its ownership marker is
valid.
Per-image parallel logs and registry/result manifests are retained under
`zuul-output/logs/container-build/`.

The provider pauses while dependent jobs run. In this repository,
`s2i-openstack-container-consumer-smoke` is the cheap contract check
(pull, inspect, deployment-key resolution on a fresh node) and
`s2i-openstack-deploy-validation` is the live CRC/EDPM consumer. Both
must remain **direct** dependents of the provider so the registry stays
paused until they finish. Operator consumption is documented in
[`operator-onboarding.md`](operator-onboarding.md).

## Build architecture

### Base image (`openstack-base`)

Single-stage build on `ubi10/ubi-minimal`. Installs system packages, Python,
pip, kolla helper scripts, and common Python dependencies. All service
images inherit from this.

### Service images

Two-stage build:

1. **Build stage** (FROM base AS build):
   - Installs build-time system and Python dependencies.
   - Copies source repos from the build context (`src/`).
   - Builds wheels from source with `pip wheel --no-deps`.
   - Generates a filtered constraints file (excludes source-built packages).
   - Records a build manifest (`source-built-packages.txt`) with
     package name, commit hash, and version.
   - Runs oslo-config-generator for config files (service-specific).

2. **Runtime stage** (FROM base):
   - Creates the service user via `uid_gid_manage`.
   - Installs runtime system packages from `bindeps.txt`.
   - Installs wheels from the build stage plus extra Python deps from
     `pythondeps.txt`, constrained by the filtered constraints file.
   - Sets up directories, config files, and permissions.

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `STREAM` | `master` | Stream name (selects which `sources.txt` entries to use) |
| `REGISTRY` | `localhost` | Container registry |
| `NAMESPACE` | `openstack` | Registry namespace |
| `TAG` | `${STREAM}-latest` | Image tag(s), comma-separated for multiple |
| `IMAGE_PREFIX` | `openstack` | Prefix for image names (e.g., `openstack-watcher`) |
| `BASE_IMAGE` | `${REGISTRY}/${NAMESPACE}/${IMAGE_PREFIX}-base:${TAG}` | Base image for service builds |
| `CONSTRAINTS_FILE` | `requirements.lock` | Lockfile base name used during builds |
| `BUILD_CONSTRAINTS_FILE` | `buildrequirements.lock` | Build-requirements lockfile base name |
| `DEFAULT_STREAM` | `master` | Stream for which un-suffixed symlinks are created |
| `PARALLEL` | `nproc` | Max concurrent builds for `build-parallel` |
| `BUILD_LOGS_DIR` | *(tmpdir, deleted)* | Directory to persist `build-parallel` logs |
| `SKIP_HASH_UPDATE` | *(unset)* | If set, `update-sources` skips updating pinned hashes and clones repos at existing pins; lockfiles are still regenerated |
| `REQUIREMENTS_SRC` | *(unset)* | Directory containing `upper-constraints.txt`. When set, `sync-locks` copies that file instead of fetching the stream branch tip |
| `PIP_NO_BINARY` | *(unset)* | If set, passed as `--build-arg` to the container build so pip builds packages from source (e.g., `:all:`) |

## CI path filtering

Workflows use GitHub's native [`on.<event>.paths`](https://docs.github.com/en/actions/using-workflows/workflow-syntax-for-github-actions#onpushpull_requestpull_request_targetpathspaths-ignore)
filters so unrelated jobs are skipped entirely. Skipped workflows count as
passing for required branch protection when the workflow file exists on the
default branch. Linters always run. Manual `workflow_dispatch` runs everything.

| Changed paths | Linters | Unit tests | update-sources | Build / push |
|---------------|---------|------------|----------------|--------------|
| Docs only (`*.md`, `LICENSE*`) | run | skip | skip | skip |
| `containers/<service>/` | run | skip | run | **all** images |
| `build.sh` | run | run | run | **all** images |
| `tox.ini` | run | run | skip | **all** images |
| `tests/`, `hack/` | run | run | skip | skip |

When build or push runs, **all** images are built together so every container
for a commit shares the same `master-<sha>` tag and consistent OS packages.

## Adding a new service

1. Create the project directory structure:

   ```
   containers/<project>/
     sources.txt
     src/.gitkeep
     <image>/
       Containerfile
       bindeps.txt
       builddeps.txt
       pythondeps.txt
       pythonbuilddeps.txt
       src/.gitkeep
   ```

2. Populate `sources.txt` with `upper-constraints` and service repo entries
   for each stream.

3. Write the `Containerfile` following the multi-stage pattern (see
   `containers/watcher/watcher/Containerfile` as an example).

4. Fill in the dependency files for the image.

5. Update the README with the images being built.

6. Update containers/image-mappings.yaml to map the image to an Image var in
   [openstackversions.spec.customContainerImages](https://github.com/openstack-k8s-operators/openstack-operator/blob/main/api/bases/core.openstack.org_openstackversions.yaml)

7. Run update-sources and build:

   ```bash
   STREAM=master ./build.sh update-sources <project>
   STREAM=master ./build.sh build <project>
   ```

8. To validate the images on a live operator deployment, follow
   [`operator-onboarding.md`](operator-onboarding.md).

## Speculative builds (Zuul integration)

When a patch is submitted against an upstream OpenStack project (e.g.,
`openstack/tempest`), the CI pipeline can automatically build fresh
container images incorporating that patch. This is called a **speculative
build**.

### Auto-detection

The content provider job accepts `s2i_ci_images: auto` to automatically
determine which images need rebuilding based on the triggering project:

```yaml
# In a Zuul job definition
vars:
  s2i_ci_images: auto
```

Under the hood, auto-detection:

1. Inspects `zuul['items']` to find the projects in the speculative change
   queue.
2. Runs `build.sh auto-detect` with each change's Zuul `project.name`
   (e.g. `openstack/tempest`). Auto-detect also accepts a full git URL
   or a Zuul canonical name (`opendev.org/openstack/tempest`).
3. Replaces `s2i_ci_images` with the de-duplicated list of affected
   image targets.

You can test auto-detection locally:

```bash
# Which images would be rebuilt for a tempest patch?
PARALLEL=1 ./build.sh auto-detect openstack/tempest master

# Full URL form also works
PARALLEL=1 ./build.sh auto-detect https://opendev.org/openstack/neutron.git

# Zuul canonical names match the same images
PARALLEL=1 ./build.sh auto-detect opendev.org/openstack/tempest master
```

### Source staging

After auto-detection resolves the image list, the pipeline stages Zuul's
source checkouts into the container build contexts. This replaces the
pinned source with the patched version so the built image includes the
speculative change.

The staging playbook (`shared/stage-zuul-sources.yaml`) delegates all
`sources.txt` parsing to `build.sh list-sources`, keeping build.sh as the
single source of truth for the source manifest format.

`list-sources` emits project paths as they appear in `sources.txt`
(`openstack/tempest`). Zuul's `zuul.projects` is keyed by canonical
names (`opendev.org/openstack/tempest`). The staging playbook maps both
forms so speculative checkouts are copied into `src/` instead of
building from the pinned git hash.

Staging alone is not enough: committed `requirements.lock.<stream>` still
pins the last `update-sources` run. After any sources are staged, the
content provider runs `tox -e sync-locks` for those projects. That
command:

- Refreshes `upper-constraints.txt.<stream>` from the stream branch tip,
  or from a Zuul `openstack/requirements` checkout when one is in the
  buildset (`REQUIREMENTS_SRC`, for example a `Depends-On` constraints
  bump).
- Leaves staged `src/` trees in place and clones any missing sibling
  repos at the **committed pin**, not the branch tip.
- Regenerates `requirements.lock.<stream>` and
  `buildrequirements.lock.<stream>` from the current `src/*/requirements.txt`
  trees plus `pythondeps.txt`.
- Does **not** rewrite hashes in `sources.txt` and does **not** regenerate
  `rpms.in.yaml`.

Do not use `update-sources` here. It would advance unstaged sibling pins
to branch tip and rewrite `sources.txt`.

### Querying source dependencies

`build.sh list-sources` prints pipe-delimited records for all source
dependencies of an image target:

```bash
PARALLEL=1 ./build.sh list-sources tempest/tempest master
# Output: name|canonical_project|url|dest_dir
# tempest|openstack/tempest|https://opendev.org/openstack/tempest.git|/.../containers/tempest/src/tempest
# barbican-tempest-plugin|openstack/barbican-tempest-plugin|https://...
```

This is used by the Ansible playbooks but is also useful for debugging
which upstream repos feed into a given image.

### Adding speculative deploy+test validation for a service

Once the content provider can build images for a service, wire a live
deploy+tempest job on the operator repository. Follow
[`operator-onboarding.md`](operator-onboarding.md).

That playbook covers job naming (`<service>-s2i-content-provider`,
`<service>-s2i-tempest`), dual-registry trust, `edpm_prepare` injection,
and the OpenDev `s2i-speculative-build` template. Do not parent
`s2i-speculative-deploy-test-base` on operator `github-check`.
