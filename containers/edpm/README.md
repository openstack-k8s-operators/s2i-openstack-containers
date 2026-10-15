# EDPM bootc host image

`edpm/edpm-bootc` builds the bootc-based operating system image used for EDPM
bare-metal nodes. It is a pure RPM image and intentionally does not inherit
from `openstack-base`.

Build and push it using the normal repository commands:

```bash
./build.sh build edpm/edpm-bootc
REGISTRY=quay.io NAMESPACE=myorg ./build.sh push edpm/edpm-bootc
```

The image reuses the repository configuration from the `openstack-base` image
(copied in from the `BASE_IMAGE` stage), so no additional repo setup is
required. The default bootc base is CentOS Stream 10. Use `BUILD_FLAGS` to
override the base image; for example, to build on the RHEL bootc base:

```bash
BUILD_FLAGS='--build-arg EDPM_BASE_IMAGE=registry.redhat.io/rhel10/rhel-bootc:latest' \
  ./build.sh build edpm/edpm-bootc
```

The Containerfile also accepts the `USER_PACKAGES` (extra RPMs to install),
`ENABLE_UNITS` (systemd units to enable), and `FIPS` build arguments.

Package repository configuration is copied from the `BASE_IMAGE` image.

The published image name follows this repository's naming convention:
`openstack-edpm-bootc`.
