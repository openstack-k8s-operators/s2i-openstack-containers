# S2I OpenStack Containers Developer Guide

This guide documents the repository's current build, source-maintenance, and
contributor workflows. For a concise project introduction, see the root
[`README.md`](../README.md). For a short testing entry point, see
[`TESTING.md`](TESTING.md). For CI, validation, and publication — the
GitHub Actions and Zuul jobs, the daily `update-sources` automation, the
post-merge build-and-push job, and the component jobs — see
[`ci-validation-publication.md`](ci-validation-publication.md). To build an
image that includes an unmerged OpenDev change, see
[`testing-opendev-patches.md`](testing-opendev-patches.md). For dropping
unwanted upstream dependencies, see
[`excluding-requirements.md`](excluding-requirements.md). To wire a live
deploy+test job on an operator repository, see
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
Pin clones fetch only the recorded commit (`git fetch --depth 1`). Unique
destinations are cloned in parallel, capped by `PARALLEL` (the same limit
as `build-parallel`). Set `FULL_CLONE` to fetch full history instead. If
a server rejects a SHA want, the clone falls back to full history.

`update-sources` resolves branch tips with `git ls-remote` instead of
cloning to discover the SHA. If the pin already matches the tip, the hash
in `sources.txt` is left unchanged. Missing service checkouts are still
cloned at that SHA so lock generation can read the tree. Those checkouts
use full git history so PBR can see tags when recording the version field.
`upper-constraints.txt` is fetched as a single file (blobless fetch, then a
shallow pin, then a full clone fallback) and is never cloned into `src/`.

The sixth `sources.txt` field (package version) is ignored by clone and
fetch paths. `update-sources` still records it so container builds can set
`PBR_VERSION` on shallow pin clones that have no git history for `git describe`.

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
for image-specific sources) before running `build.sh build`. Set
`PBR_VERSION_FROM_GIT=true` for these development builds so PBR calculates a
version from the local checkout instead of using the version recorded in
`sources.txt`. This works both locally and in CI workflows -- for example, a
Zuul or GitHub Actions job can clone a patch under review into `src/` and build
containers that include the unmerged change.

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
<stream> <name> <repo-url> <branch-to-follow> <pinned-hash> <version>
```

Example:

```
master upper-constraints https://opendev.org/openstack/requirements.git master 4bb8ff9ad664e832d78139e23f5933cca6054d35 -
master watcher https://opendev.org/openstack/watcher.git master 4abcf29a3ec323a6df3f567d7485b320354af4f4 16.1.0.dev100
stable upper-constraints https://opendev.org/openstack/requirements.git stable/2026.1 c4c55d5279d824dc261a43ac51b56146ccc4dd4f -
stable watcher https://opendev.org/openstack/watcher.git stable/2026.1 ba7b161dc24a6f2f1f7b7a2a529b8d93c65fee6c 16.0.1.dev4
```

`update-sources` calculates the Python package version at the same commit as
the pin, making the hash/version pair atomic. Non-Python sources and the
special `upper-constraints` entry use `-` as their version.

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
  Exact version pins (`pkg==version`) override `upper-constraints.txt`
  during lockfile generation, same as `pythondeps.txt`.
- **`bindeps.txt`** -- System packages installed in the final runtime image.
- **`pythondeps.txt`** -- Extra Python packages installed via pip in the
  final image (database drivers, caching backends, CLI clients). Entries
  with an exact version pin (`pkg==version`) override the corresponding
  entry in `upper-constraints.txt` during lockfile generation -- the
  pinned package is removed from the constraints file before `pip-compile`
  runs so the version from `pythondeps.txt` takes priority.

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
- `pbr` and `packaging` -- calculate and validate versions for pinned sources

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

1. Create `containers/<project>/sources.txt` with entries for each stream. Add
   an `upper-constraints` entry only when the image has Python dependencies;
   source-only utility images can pin their own source without one.
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

The `edpm/edpm-bootc` image is a bootc based OS image. It does not inherit from
`openstack-base`, but it reuses that image's repository configuration (copied in
from the `BASE_IMAGE` stage), so no extra repo setup is required. Its
Containerfile defaults to the CentOS Stream 10 bootc base. Use `BUILD_FLAGS` to
select another base, for example:

```bash
BUILD_FLAGS='--build-arg EDPM_BASE_IMAGE=registry.redhat.io/rhel10/rhel-bootc:latest' \
  ./build.sh build edpm/edpm-bootc
```

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

## CI, validation, and publication

Changes to this repository are validated by GitHub Actions workflows and by
Zuul jobs: the content provider builds all images from the PR's pins, a
consumer smoke check pulls and inspects them, and a full CRC/EDPM deployment
validation deploys them and runs tempest. Operator repositories contribute
per-service component jobs through project templates, a daily
`update-sources` automation proposes pin bumps, and merged images are
published by a post-merge Zuul job defined in the rdoproject.org config
repository.

The full job inventory (purpose, trigger, and definition location for each
job), the content-provider internals (mirrors, caching, image selection,
returned data), the publication model, and the speculative-build machinery
are documented in
[`ci-validation-publication.md`](ci-validation-publication.md).

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
   - Builds wheels from source with the version recorded in `sources.txt`.
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
| `BUILD_FLAGS` | *(unset)* | Additional whitespace-separated options passed to every `buildah bud` invocation, such as `--build-arg`, `--secret`, and `--volume` |
| `BUILD_FLAGS_FILE` | *(unset)* | File containing one buildah argument per line; use for option values containing spaces |
| `CONSTRAINTS_FILE` | `requirements.lock` | Lockfile base name used during builds |
| `BUILD_CONSTRAINTS_FILE` | `buildrequirements.lock` | Build-requirements lockfile base name |
| `DEFAULT_STREAM` | `master` | Stream for which un-suffixed symlinks are created |
| `PARALLEL` | `nproc` | Max concurrent builds for `build-parallel` and unique source clones |
| `BUILD_LOGS_DIR` | *(tmpdir, deleted)* | Directory to persist `build-parallel` logs |
| `SKIP_HASH_UPDATE` | *(unset)* | If set, `update-sources` skips updating pinned hashes and clones repos at existing pins; lockfiles are still regenerated |
| `FULL_CLONE` | *(unset)* | If set, pin clones fetch full git history instead of `--depth 1` |
| `REQUIREMENTS_SRC` | *(unset)* | Directory containing `upper-constraints.txt`. When set, `sync-locks` copies that file instead of fetching the stream branch tip |
| `PIP_NO_BINARY` | *(unset)* | If set, passed as `--build-arg` to the container build so pip builds packages from source (e.g., `:all:`) |
| `PBR_VERSION_FROM_GIT` | `false` | If true, let PBR calculate source versions from Git instead of using `sources.txt`; intended for development checkouts |

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

When a patch is submitted against an upstream OpenStack project, the CI
pipeline can automatically build fresh container images incorporating that
patch. This is called a **speculative build**.

Auto-detection (`s2i_ci_images: auto`), Zuul source staging, relocking with
`sync-locks`, and the OpenDev `s2i-speculative-build` template are documented
in
[`ci-validation-publication.md`](ci-validation-publication.md#speculative-builds-of-opendev-changes).
The local `sync-locks` command itself is described in
[Relocking staged sources](#relocking-staged-sources-speculative-ci) above.
To wire a live deploy+test job for a service on an operator repository,
follow [`operator-onboarding.md`](operator-onboarding.md).
