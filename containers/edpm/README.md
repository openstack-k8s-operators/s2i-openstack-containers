# EDPM bootc host image

`edpm/edpm-bootc` builds the bootc-based operating system image used for EDPM
bare-metal nodes. It is a pure RPM image and intentionally does not inherit
from `openstack-base`.

Build and push it using the normal repository commands:

```bash
./build.sh build edpm/edpm-bootc
REGISTRY=quay.io NAMESPACE=myorg ./build.sh push edpm/edpm-bootc
```

The default base is CentOS Stream 10 bootc, with repo-setup using the `ceph`
and `deps` repositories. Use `BUILD_FLAGS` to override the base image and
repo-setup settings; for example, to select CentOS Stream 9:

```bash
BUILD_FLAGS='--build-arg EDPM_BASE_IMAGE=quay.io/centos-bootc/centos-bootc:stream10 \
  --build-arg REPO_SETUP_DISTRO=centos9' \
  ./build.sh build edpm/edpm-bootc
```

For other repositories, set `REPO_SETUP`, `REPO_SETUP_BRANCH`, and
`REPO_SETUP_DISTRO` with `BUILD_FLAGS`. The build also supports
`REPO_SETUP_EXTRA` and trusted-certificate volume options. Use
`BUILD_FLAGS_FILE` when a build argument contains spaces, such as
`REPO_SETUP_EXTRA`:

```text
--build-arg
REPO_SETUP_EXTRA=rhos-release ceph-6.0 -r 9.4 -t yum.repos.d
```

Save those two lines to a file and pass it as
`BUILD_FLAGS_FILE=/path/to/build-flags`. RHSM registration can be supplied without embedding
credentials in an image layer by copying `repo-setup/rhsm.sh`, editing the
copy, and passing it as a build secret:

```bash
cp containers/edpm/repo-setup/rhsm.sh /tmp/rhsm-custom.sh
# Edit RHSM_USER and RHSM_PASSWORD in /tmp/rhsm-custom.sh.
BUILD_FLAGS='--secret id=rhsm,src=/tmp/rhsm-custom.sh \
  --build-arg EDPM_BASE_IMAGE=registry.redhat.io/rhel9/rhel-bootc:latest' \
  ./build.sh build edpm/edpm-bootc
```

The published image name follows this repository's naming convention:
`openstack-edpm-bootc`.
