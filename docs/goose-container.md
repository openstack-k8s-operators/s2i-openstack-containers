# Goose container

This repository builds Goose as the `openstack-goose` operator utility image.
The `openstack-operator` consumes it directly; it is not an
`OpenStackVersion.spec.customContainerImages` service image and must not be
added to `containers/image-mappings.yaml`. It is built from the pinned upstream
source declared in
`containers/goose/sources.txt` and does not use OpenStack Python constraints
or lockfiles.

The image follows the project conventions while preserving the important parts
of the original CentOS Dockerfile:

- Goose CLI is built from source with Rust 1.94.1 directly on UBI 10 minimal.
- The runtime image contains the Goose binary, its shared-library dependencies,
  and pinned, checksum-verified `oc` and `kubectl` clients.
- The image runs as UID 1000 and makes `/home/goose` writable by OpenShift's
  arbitrary UID model through group-zero permissions.

## Build locally

Install the host prerequisites if necessary:

```console
./build.sh install-deps
```

Build Goose:

```console
STREAM=master ./build.sh build goose/goose
```

The resulting image is:

```text
localhost/openstack/openstack-goose:master-latest
```

`build.sh` clones the exact Goose source commit for the build and removes that
temporary checkout when it exits. It also downloads the pinned Rust toolchain
and OpenShift client artifacts listed in `containers/goose/goose/artifacts.txt`.
The Containerfile installs the matching Rust archive locally, so it makes no
compiler download during the image build.

## Prefetch Cargo dependencies

Populate the repository's shared temporary Cargo cache before building:

```console
STREAM=master ./build.sh prefetch-cargo goose/goose
```

The command uses the pinned Goose source and its `Cargo.lock`, storing registry
crates and Git dependencies in `.tmp/cargo-home/goose/goose/`. A normal build
mounts and reuses this cache while still being allowed to download a missing
input.
Require a fully cached Cargo build with:

```console
CARGO_NET_OFFLINE=true STREAM=master ./build.sh build goose/goose
```

`.tmp/` is already ignored by Git. Remove `.tmp/cargo-home/` to discard every
Cargo cache, or refresh this cache whenever the Goose source pin or `Cargo.lock`
changes.

## Test locally

Confirm that the image starts and contains Goose:

```console
podman run --rm localhost/openstack/openstack-goose:master-latest --version
podman run --rm localhost/openstack/openstack-goose:master-latest --help
```

Run an interactive session against a working tree:

```console
podman run --rm -it \
  -v "$PWD:/workspace:Z" \
  -w /workspace \
  -e GOOSE_PROVIDER=openai \
  -e GOOSE_MODEL=<model> \
  -e OPENAI_API_KEY \
  localhost/openstack/openstack-goose:master-latest session
```

Goose provider credentials are intentionally passed at runtime rather than
baked into the image.  Mount a persistent directory at `/home/goose/.config/goose`
if configuration should survive between containers.

## Repository validation

Run the normal repository checks after modifying this target:

```console
tox -e test
tox -e linters
STREAM=master ./build.sh update-lockfiles goose
```

The last command regenerates `containers/goose/rpms.in.yaml`; it correctly
skips Python lockfile generation because Goose is a source-only Rust project.
