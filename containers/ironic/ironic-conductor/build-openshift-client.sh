#!/bin/bash
#
# Build the OpenShift client (oc) from the pinned upstream source tree and
# install it. The runtime stage adds kubectl as a symlink to oc; kubectl is
# not a separate program because oc selects its command set from argv[0]
# (see cmd/oc/oc.go).
#
# The release version is recorded in the image-level sources.txt and is
# maintained by hand for non-Python sources.
#
# Usage: build-openshift-client.sh [<source-dir> [<sources-file> [<stream>]]]
set -euo pipefail

src="${1:-/src/oc}"
sources_file="${2:-/source-versions/ironic-conductor.txt}"
stream="${3:-master}"

if [[ ! -f "${sources_file}" ]]; then
  echo "ERROR: sources file not found: ${sources_file}" >&2
  exit 1
fi

version="$(awk -v stream="${stream}" \
  '$1 == stream && $2 == "oc" { print $6; exit }' "${sources_file}")"
if [[ -z "${version}" || "${version}" == "-" ]]; then
  echo "ERROR: no version recorded for the 'oc' source in ${sources_file}" \
    "(stream ${stream})" >&2
  exit 1
fi

cd "${src}"

# Dependencies are vendored, and GOTOOLCHAIN=local/GOPROXY=off make any
# attempt to reach the network (or silently pick a newer toolchain) fail
# instead of succeeding.
env GOTOOLCHAIN=local GOFLAGS=-mod=vendor GOPROXY=off CGO_ENABLED=1 \
  make oc \
    OS_GIT_VERSION="${version}"

install -m 0755 oc /usr/local/bin/oc
