# S2I OpenStack Containers

Source-to-image container builds for OpenStack services on UBI 10
(`ubi-minimal`). Service code is built from pinned upstream Git sources with
Python dependencies constrained by generated lock files.

The repository currently builds:

- `openstack-base`;
- `openstack-cyborg`;
- `openstack-cyborg-agent`;
- `openstack-glance-api`;
- `openstack-manila-api`;
- `openstack-manila-scheduler`;
- `openstack-manila-share`;
- `openstack-watcher-base`.

## Quick start

Install the host container tools:

```console
./build.sh install-deps
```

List available image targets:

```console
./build.sh list
```

Build all images from the maintained `master` source pins:

```console
STREAM=master tox -e build
```

Run the current test and lint environments:

```console
tox -e test
tox -e linters
```

## Documentation

- [`docs/developer-guide.md`](docs/developer-guide.md) describes repository
  structure, sources, generated files, builds, and maintenance workflows.
- [`docs/TESTING.md`](docs/TESTING.md) provides a concise testing entry point.

## Publication

Konflux is authoritative for hermetic production provenance and publication.
GitHub workflows provide development build and validation coverage. Development
tags published by those workflows do not replace Konflux production artifacts.

## License

See [`LICENSE.txt`](LICENSE.txt).
