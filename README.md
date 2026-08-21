# S2I OpenStack Containers

Source-to-image container builds for OpenStack services on UBI 10
(`ubi-minimal`). Service code is built from pinned upstream Git sources with
Python dependencies constrained by generated lock files.

The repository currently builds:

- `openstack-ansible-test`;
- `openstack-aodh-api`;
- `openstack-base`;
- `openstack-barbican-api`;
- `openstack-cinder-api`;
- `openstack-cinder-backup`;
- `openstack-cinder-scheduler`;
- `openstack-cinder-volume`;
- `openstack-cyborg`;
- `openstack-cyborg-agent`;
- `openstack-designate-api`;
- `openstack-designate-backend-bind9`;
- `openstack-designate-central`;
- `openstack-designate-worker`;
- `openstack-glance-api`;
- `openstack-heat-api`;
- `openstack-heat-engine`;
- `openstack-horizon`;
- `openstack-ironic-neutron-agent`;
- `openstack-keystone`;
- `openstack-barbican-api`;
- `openstack-manila-api`;
- `openstack-manila-scheduler`;
- `openstack-manila-share`;
- `openstack-mariadb`;
- `openstack-memcached`;
- `openstack-neutron-dhcp-agent`;
- `openstack-neutron-metadata-agent-ovn`;
- `openstack-neutron-ovn-agent`;
- `openstack-neutron-server`;
- `openstack-neutron-sriov-agent`;
- `openstack-nova-api`;
- `openstack-octavia-api`;
- `openstack-octavia-worker`;
- `openstack-openstackclient`;
- `openstack-ovn-base`;
- `openstack-ovn-controller`;
- `openstack-ovn-nb-db-server`;
- `openstack-ovn-northd`;
- `openstack-ovn-sb-db-server`;
- `openstack-rabbitmq`;
- `openstack-redis`;
- `openstack-swift-account`;
- `openstack-swift-container`;
- `openstack-swift-object`;
- `openstack-swift-proxy-server`;
- `openstack-tempest`;
- `openstack-watcher-base`;

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

- [`docs/design.md`](docs/design.md) covers the design principles behind the
  container images and Containerfiles.
- [`docs/developer-guide.md`](docs/developer-guide.md) describes repository
  structure, sources, generated files, builds, and maintenance workflows.
- [`docs/TESTING.md`](docs/TESTING.md) provides a concise testing entry point.

## Publication

Konflux is authoritative for hermetic production provenance and publication.
GitHub workflows provide development build and validation coverage. Development
tags published by those workflows do not replace Konflux production artifacts.

## License

See [`LICENSE.txt`](LICENSE.txt).
