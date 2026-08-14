# S2I OpenStack Containers Developer Guide

This guide documents the repository's current build, source-maintenance, and
contributor workflows. For a concise project introduction, see the root
[`README.md`](../README.md). For a short testing entry point, see
[`TESTING.md`](TESTING.md).

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
    rpms.in.yaml                  # [generated] RPM packages for rpm-lockfile-prototype
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

If a checkout already exists in `src/` (e.g., a local development clone),
`build.sh` uses it as-is and does **not** remove it on exit. This lets you
work on a local branch without `build.sh` overwriting it.

### Source overrides

To patch or replace a transitive dependency, place the modified source in
`containers/<project>/src/overrides/<pkg>/`. The build stage picks up
everything under `src/overrides/` automatically -- no `sources.txt` entry
is needed. The filtered constraints file excludes source-built packages so
the overridden version takes precedence over PyPI.

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

The base image (`containers/base/`) also has `bindeps.txt` and `pythondeps.txt`
for packages shared across all service images.

## Auto-generated files

These files are created and updated by `build.sh update-sources`. They
should be committed to the repository but never edited by hand.

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

**Important:** Whenever you modify `sources.txt`, `pythondeps.txt`,
`pythonbuilddeps.txt`, `bindeps.txt`, or `builddeps.txt`, you must re-run
`build.sh update-sources` (or `tox -e update-sources`) to regenerate the
lockfile, constraints, and `rpms.in.yaml`. Failing to do so will cause
builds to use stale dependency pins.

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

- `pip-tools` -- provides `pip-compile`, used by `update-sources` to
  generate lockfiles
- `pybuild-deps` -- used by `update-sources` to generate build-requirements
  lockfiles

If using tox (recommended), Python dependencies are installed automatically
in the tox virtualenv.

## Workflow

### Using tox

Tox manages a virtualenv with the required Python dependencies and passes
through all relevant environment variables (`STREAM`, `REGISTRY`, `TAG`, etc.):

```bash
# Update sources for all projects
STREAM=master tox -eupdate-sources

# Build all images
STREAM=master tox -ebuild

# Run any build.sh command via the generic 'custom' target
STREAM=master tox -ecustom -- update-sources watcher
STREAM=stable tox -ecustom -- build watcher/watcher-api
tox -ecustom -- list
```

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
1. Resolve every selected branch or tag to one exact commit before mutation.
2. Update `sources.txt` with the frozen commits.
3. Fetch `upper-constraints.txt` from the same frozen input set.
4. Generate `rpms.in.yaml` from all `bindeps.txt` + `builddeps.txt` files.
5. Run `pip-compile` to generate `requirements.lock.<stream>`.
6. Run `pybuild-deps compile` to generate `buildrequirements.lock.<stream>`.
7. Create default-stream symlinks if `STREAM == DEFAULT_STREAM`.

The preflight record is written to
`.tmp/source-maintenance/frozen-source-refs.<stream>.tsv`. It records each
source manifest, declared ref, committed pin, frozen commit, and authority.
Advancing runs use `declared-ref`; pinned runs use `committed-pin`; intentional
Git checkouts already under `src/` use `pre-existing-checkout`. A slash in a
stream name is encoded as `%2F`, and unsafe stream names are rejected before
filesystem mutation.

All selected records must pass preflight before a tracked source manifest is
changed. The fetched repositories are retained for the complete run so a moving
branch cannot provide different content after preflight. Auto-created source
checkouts are cleaned up on exit. Pre-existing checkouts are used as-is and are
not removed.

To regenerate lockfiles without updating pinned hashes (steps 1--3 are
skipped; repos are cloned at the existing pinned hashes instead), use the
canonical Python 3.12 environment:

```bash
STREAM=master uvx --python 3.12 tox -e update-lockfiles -- <project-or-all>
```

Python environment markers are evaluated by the generator interpreter, so
other Python minor versions can produce a different dependency set. The tox
environment rejects non-3.12 interpreters and pins the generator tool versions.
Generated lock headers, resolver annotations, and package-index directives are
removed because they describe the generation environment rather than the
resolved dependency set.

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

5. Run update-sources and build:

   ```bash
   STREAM=master ./build.sh update-sources <project>
   STREAM=master ./build.sh build <project>
   ```
