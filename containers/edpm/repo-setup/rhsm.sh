#!/bin/bash

set -eu

# Copy this file outside the repository and edit RHSM_ values before use.
RHSM_USER=unset
RHSM_PASSWORD=unset
RHEL_MAJOR=${RHEL_MAJOR:-9}
RHSM_REPOS=${RHSM_REPOS:-"--enable=rhoso-18.0-for-rhel-${RHEL_MAJOR}-x86_64-rpms \
            --enable=rhceph-8-tools-for-rhel-${RHEL_MAJOR}-x86_64-rpms \
            --enable=fast-datapath-for-rhel-${RHEL_MAJOR}-x86_64-rpms"}
# Only required when Simple Content Access (SCA) is disabled.
RHSM_POOL=""

rm -f /etc/yum.repos.d/*.repo
if [ -L /etc/rhsm-host ]; then
    rm -f /etc/rhsm-host
fi

# Suppress xtrace to avoid leaking credentials to the build log.
set +x
subscription-manager register --username="${RHSM_USER}" --password="${RHSM_PASSWORD}"
set -x
if [ -n "${RHSM_POOL}" ]; then
    subscription-manager attach --pool="${RHSM_POOL}"
fi
subscription-manager repos ${RHSM_REPOS}
