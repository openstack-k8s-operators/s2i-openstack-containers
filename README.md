# S2I OpenStack Containers

Source-to-image container builds for OpenStack services on UBI 10 (ubi-minimal).

Services are built from pinned upstream source using multi-stage Containerfiles.
All Python dependencies are installed via pip from wheels compiled in a build
stage, constrained by a `pip-compile`-generated lockfile. System (RPM)
dependencies are installed via `microdnf`.

## Repository structure

```
build.sh                          # Build orchestrator
Makefile                          # Make targets (generate-service-uids, verify, test)
containers/
  base/                           # Base image (openstack-base)
    Containerfile
    bindeps.txt                   # System packages for base image
    pythondeps.txt                # Python packages for base image
    rpms.repo                     # DNF repo config for RPM lockfile
    sources.txt                   # Pinned upstream sources (upper-constraints)
    scripts/                      # Helper scripts (uid_gid_manage, kolla_start, ...)
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
users/                            # Central UID/GID registry (Go module)
  registry.go                     # Source of truth: constants + Registry map
  registry_test.go                # Validation tests
  cmd/gen-users/                  # Generator tool (outputs to containers/base/scripts/)
```

The generated `zz_generated_users.txt` lives in `containers/base/scripts/`
(next to `uid_gid_manage`) so it gets COPY'd into the container image
automatically.

```
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
| `scripts/*` | `containers/base/scripts/` | Helper scripts (`kolla_start`, `uid_gid_manage`, etc.). Note: `uid_gid_manage` reads user definitions from the generated `zz_generated_users.txt` (same directory) — edit `users/registry.go` to add/change users, not the script itself. |
| `config/*` | `containers/service/` | Config files manually maintained out of upstream repo |
| `users/registry.go` | `users/` | Central UID/GID registry (Go source of truth). After editing, run `make generate-service-uids` to regenerate the users file. |

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

These files are created and updated by tools. They should be committed to
the repository but never edited by hand.

| File | Location | Generated by | Generated from |
|------|----------|-------------|----------------|
| `zz_generated_users.txt` | `containers/base/scripts/` | `make generate-service-uids` | `users/registry.go` |
| `upper-constraints.txt.<stream>` | `containers/<project>/`, `containers/base/` | `build.sh update-sources` | `upper-constraints` entry in `sources.txt` |
| `requirements.lock.<stream>` | `containers/<project>/`, `containers/base/` | `build.sh update-sources` | `pip-compile` against all `requirements.txt` + `pythondeps.txt` + `pythonbuilddeps.txt` |
| `buildrequirements.lock.<stream>` | `containers/<project>/`, `containers/base/` | `build.sh update-sources` | `pybuild-deps compile` against `requirements.lock.<stream>` |
| `rpms.in.yaml` | `containers/<project>/`, `containers/base/` | `build.sh update-sources` | Union of all `bindeps.txt` + `builddeps.txt` across images |

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
skipped; repos are cloned at the existing pinned hashes instead):

```bash
STREAM=master SKIP_HASH_UPDATE=1 ./build.sh update-sources <project-or-all>
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

## Service Users (UID/GID Registry)

The `users/` directory contains the central registry of all OpenStack service
UIDs and GIDs. This is the **single source of truth** — both Go operators and
container image builds consume it.

- **Go operators** import constants directly: `users.KeystoneUID`, `users.ApacheGID`
- **Container images** use the generated `containers/base/scripts/zz_generated_users.txt` via
  the `uid_gid_manage` script during image builds

### Registering a new user

1. Edit `users/registry.go`:

   Add a new UID/GID constant pair to the `const` block (pick the next
   available UID — check existing values to avoid collisions):

   ```go
   MyserviceUID int64 = 42497
   MyserviceGID int64 = 42497
   ```

   Add a Registry entry in the `var Registry` map:

   ```go
   "myservice": {UID: MyserviceUID, GID: MyserviceGID, Home: "/var/lib/myservice"},
   ```

   If the user needs supplemental groups (e.g. `apache` for httpd-fronted
   services), add them:

   ```go
   "myservice": {UID: MyserviceUID, GID: MyserviceGID, Home: "/var/lib/myservice", Groups: []string{"apache"}},
   ```

   Users without a home directory (system/group-only users) omit the `Home` field:

   ```go
   "mygroup": {UID: MyGroupUID, GID: MyGroupGID},
   ```

2. Add the new user to `users/registry_test.go`:

   ```go
   "myservice": MyserviceUID,
   ```

3. Regenerate the users file:

   ```bash
   make generate-service-uids
   ```

4. Verify everything is in sync:

   ```bash
   make verify-service-uids
   make test-users
   ```

5. Commit all changed files (`registry.go`, `registry_test.go`,
   `zz_generated_users.txt`).

The pre-commit hook `verify-service-uids` will catch any forgotten
regeneration — it runs automatically when `users/registry.go` is modified
and fails with a diff if the generated file is stale.

### Using users in Go operators

```go
import "github.com/openstack-k8s-operators/s2i-openstack-containers/users"

// Pod-level SecurityContext
pod.RestrictivePodSecurityContext(users.MyserviceUID, users.ApacheGID)

// Container-level SecurityContext
pod.RestrictiveSecurityContext(users.MyserviceUID)
```

### Using users in container image builds

The `uid_gid_manage` script reads from `zz_generated_users.txt` via python3:

```dockerfile
RUN ./uid_gid_manage myservice
```

This creates the `myservice` user and group with the UID/GID from the
registry, sets up the home directory, and adds any supplemental groups.

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
