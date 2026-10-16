#!/bin/bash

set -eux

REPO_SETUP=${REPO_SETUP:-current-podified}
REPO_SETUP_BRANCH=${REPO_SETUP_BRANCH:-antelope}
REPO_SETUP_DISTRO=${REPO_SETUP_DISTRO:-centos10}
REPO_SETUP_MIRROR=${REPO_SETUP_MIRROR:-https://trunk.rdoproject.org}
REPO_SETUP_EXTRA=${REPO_SETUP_EXTRA:-echo Done}

pushd output
# Do not put quotes around ${REPO_SETUP}, as it may contain multiple positional
# args that need to be seen as separate args
./repo-setup --output-path yum.repos.d -d "${REPO_SETUP_DISTRO}" ${REPO_SETUP}
${REPO_SETUP_EXTRA}
popd
