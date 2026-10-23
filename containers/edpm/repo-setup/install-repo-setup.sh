#!/bin/bash

set -eux

# The archive is pinned and checksum-verified for reproducible repository setup.
REPO_SETUP_COMMIT=${REPO_SETUP_COMMIT:-85321f7e0af502d7f06f845886058daf09da34f6}
REPO_SETUP_SHA256=${REPO_SETUP_SHA256:-1050e4ed0472098165c4bde84a9991a6a13171426d16862f6651e28635d1727f}

pushd output
curl -fsSL -o repo-setup.tar.gz \
    "https://github.com/openstack-k8s-operators/repo-setup/archive/${REPO_SETUP_COMMIT}.tar.gz"
echo "${REPO_SETUP_SHA256}  repo-setup.tar.gz" | sha256sum -c -
tar xzf repo-setup.tar.gz
pushd "repo-setup-${REPO_SETUP_COMMIT}"
python3 -m venv ./venv
source ./venv/bin/activate
PBR_VERSION=0.0.0 python3 -m pip install ./
cp venv/bin/repo-setup ../repo-setup
popd
popd
