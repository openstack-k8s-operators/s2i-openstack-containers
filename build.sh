#!/usr/bin/env bash
# Build and push OpenStack service container images using buildah.
#
# Usage:
#   STREAM=master ./build.sh build all
#   STREAM=hibiscus ./build.sh build watcher
#   STREAM=master ./build.sh build cyborg/cyborg-agent
#   ./build.sh push all
#   ./build.sh list
#
# Streams:
#   A stream defines a set of source repos at specific commits. Streams are
#   defined in sources.txt files with the format:
#     <stream> <name> <repo-url> <branch-to-follow> <pinned-hash>
#
#   Examples:
#     master upper-constraints https://opendev.org/openstack/requirements.git master abc123def456
#     master watcher https://opendev.org/openstack/watcher.git master def789abc012
#     hibiscus upper-constraints https://opendev.org/openstack/requirements.git stable/2024.2 fed321cba654
#     hibiscus watcher https://opendev.org/openstack/watcher.git stable/2024.2 aaa111bbb222
#
#   The <branch-to-follow> field is informational — it records which branch
#   the pinned hash came from. The build always checks out <pinned-hash>.
#
#   sources.txt files can be at three levels:
#     containers/sources.txt                     — global (upper-constraints, shared libs)
#     containers/<project>/sources.txt           — common for all images in the project
#     containers/<project>/<image>/sources.txt   — image-specific extras
#
#   The special name "upper-constraints" is handled differently: instead of
#   cloning the full repo, build.sh fetches just upper-constraints.txt from
#   the repo at the pinned hash and places it in containers/base/.
#
#   The main service package must be listed in sources.txt. Its name is
#   derived from the repo URL (last path component minus .git).
#
# Image naming:
#   Image names are derived as ${IMAGE_PREFIX}-<directory-name>:
#     containers/base/            → openstack-base
#     containers/nova/nova-api/   → openstack-nova-api
#     containers/cyborg/cyborg/   → openstack-cyborg
#   IMAGE_PREFIX defaults to "openstack".
#
# Source management:
#   Sources are cloned into containers/<project>/src/<name>/ based on the
#   stream entries in sources.txt. If the directory already exists, it is
#   used as-is (sources.txt is ignored for that entry). Auto-cloned repos
#   are removed on exit.
#
#   Overrides: place patched dependencies in containers/<project>/src/overrides/<pkg>/
#   These are picked up automatically — no sources.txt entry needed.
#
#   Constraints file:
#     Defined via an "upper-constraints" entry in each project's sources.txt.
#     build.sh fetches the file from the repo at the pinned hash.
#     Each project can have a different constraints file (different streams
#     may track different releases).
#     Alternatively, place it manually at containers/<project>/upper-constraints.txt.
#
#   Lockfile:
#     When update-sources runs, it also generates a pip-compile lockfile at
#     containers/<project>/<CONSTRAINTS_FILE>.<stream> (e.g., requirements.lock.master).
#     build.sh prefers this lockfile over upper-constraints.txt when building.
#     It also generates a build-requirements lockfile at
#     containers/<project>/<BUILD_CONSTRAINTS_FILE>.<stream> (e.g., buildrequirements.lock.master)
#     using pybuild-deps compile against the requirements lockfile.
#
# Environment variables:
#   STREAM            Stream name (required for build)
#   REGISTRY          Container registry (default: localhost)
#   NAMESPACE         Registry namespace (default: openstack)
#   TAG               Image tag(s), comma-separated for multiple (default: latest)
#   IMAGE_PREFIX      Prefix for image names (default: openstack)
#   BASE_IMAGE        Base image for the base container (default: registry.access.redhat.com/ubi10/ubi:latest)
#   CONSTRAINTS_FILE  Constraints/lockfile base name (default: requirements.lock)
#   BUILD_CONSTRAINTS_FILE  Build-requirements lockfile base name (default: buildrequirements.lock)
#   DEFAULT_STREAM    Default stream (default: master). When update-sources runs
#                     for this stream, un-streamed symlinks are created (e.g.,
#                     requirements.lock -> requirements.lock.master)
#   SKIP_HASH_UPDATE  If set, update-sources skips updating pinned hashes in
#                     sources.txt and clones repos at existing pinned hashes
#                     instead. Lockfiles and rpms.in.yaml are still regenerated.
#   PIP_NO_BINARY     If set, passed as --build-arg to buildah so Containerfiles
#                     can set ENV PIP_NO_BINARY. Use ":all:" to force pip to
#                     build all packages from source instead of using wheels.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
CONTAINERS_DIR="${REPO_ROOT}/containers"

# Configurable variables
STREAM="${STREAM:-master}"
REGISTRY="${REGISTRY:-localhost}"
NAMESPACE="${NAMESPACE:-openstack}"
TAG="${TAG:-${STREAM}-latest}"
IMAGE_PREFIX="${IMAGE_PREFIX:-openstack}"
BASE_IMAGE="${BASE_IMAGE:-${REGISTRY}/${NAMESPACE}/${IMAGE_PREFIX}-base:${TAG%%,*}}"
CONSTRAINTS_FILE="${CONSTRAINTS_FILE:-requirements.lock}"
BUILD_CONSTRAINTS_FILE="${BUILD_CONSTRAINTS_FILE:-buildrequirements.lock}"
UPSTREAM_CONSTRAINTS="upper-constraints.txt"
DEFAULT_STREAM="${DEFAULT_STREAM:-master}"
SKIP_HASH_UPDATE="${SKIP_HASH_UPDATE:-}"
PIP_NO_BINARY="${PIP_NO_BINARY:-}"
PARALLEL="${PARALLEL:-$(nproc)}"
SOURCE_REFS_STREAM="${STREAM//\//%2F}"
SOURCE_REFS_MANIFEST="${REPO_ROOT}/.tmp/source-maintenance/frozen-source-refs.${SOURCE_REFS_STREAM}.tsv"

# Discover all buildable images from the directory structure.
discover_images() {
  local images=()

  # base first (if it exists)
  if [[ -f "${CONTAINERS_DIR}/base/Containerfile" ]]; then
    images+=("base")
  fi

  # Then all project/image directories
  for project_dir in "${CONTAINERS_DIR}"/*/; do
    local project=$(basename "${project_dir}")
    [[ "${project}" == "base" ]] && continue

    for image_dir in "${project_dir}"/*/; do
      local image=$(basename "${image_dir}")
      [[ "${image}" == "common" || "${image}" == "src" ]] && continue
      if [[ -f "${image_dir}/Containerfile" ]]; then
        images+=("${project}/${image}")
      fi
    done
  done

  echo "${images[@]}"
}

# Derive the published image name from a directory path
image_name() {
  local dir_name="$1"
  local name
  if [[ "${dir_name}" == */* ]]; then
    name=$(basename "${dir_name}")
  else
    name="${dir_name}"
  fi
  if [[ -n "${IMAGE_PREFIX}" ]]; then
    echo "${IMAGE_PREFIX}-${name}"
  else
    echo "${name}"
  fi
}

# Derive the project name from a directory path
project_name() {
  local dir_name="$1"
  if [[ "${dir_name}" == */* ]]; then
    echo "${dir_name%%/*}"
  fi
}

# Compute the full image tag (first tag, used for display and base image ref)
image_tag() {
  local dir_name="$1"
  local first_tag="${TAG%%,*}"
  echo "${REGISTRY}/${NAMESPACE}/$(image_name "${dir_name}"):${first_tag}"
}

# Generate --tag arguments for all tags (TAG is comma-separated)
image_tag_args() {
  local dir_name="$1"
  local name
  name="$(image_name "${dir_name}")"
  local args=""
  IFS=',' read -ra tags <<< "${TAG}"
  for t in "${tags[@]}"; do
    args="${args} --tag ${REGISTRY}/${NAMESPACE}/${name}:${t}"
  done
  echo "${args}"
}

# Track temporary source and frozen-ref repositories so they can be cleaned.
declare -A _AUTO_CLONED=()
declare -A _FROZEN_REPOSITORIES=()

cleanup_auto() {
  local path
  for path in "${!_AUTO_CLONED[@]}"; do
    echo "--- Removing auto-cloned source: ${path} ---"
    rm -rf "${path}"
  done
  for path in "${_FROZEN_REPOSITORIES[@]}"; do
    rm -rf "${path}"
  done
}
trap cleanup_auto EXIT

# Ensure constraints file exists for a project.
# Looks for an "upper-constraints" entry in the project's sources.txt
# for the current stream and fetches the file at the pinned hash.
ensure_project_constraints() {
  local project="$1"
  local stream="$2"
  local constraints_file="${CONTAINERS_DIR}/${project}/${UPSTREAM_CONSTRAINTS}.${stream}"

  if [[ -f "${constraints_file}" ]]; then
    return
  fi

  # Look for upper-constraints entry in project-level sources.txt
  local project_sources="${CONTAINERS_DIR}/${project}/sources.txt"
  if [[ -f "${project_sources}" ]]; then
    while IFS=' ' read -r entry_stream name url branch pinned_hash; do
      [[ -z "${entry_stream}" || "${entry_stream}" == \#* ]] && continue
      [[ "${entry_stream}" != "${stream}" ]] && continue
      if [[ "${name}" == "upper-constraints" ]]; then
        echo "--- Fetching ${UPSTREAM_CONSTRAINTS}.${stream} for ${project} from ${url} at ${pinned_hash} ---"
        local tmp_repo
        tmp_repo=$(mktemp -d)
        git clone --no-checkout "${url}" "${tmp_repo}" 2>/dev/null
        git -C "${tmp_repo}" checkout "${pinned_hash}" -- upper-constraints.txt
        cp "${tmp_repo}/upper-constraints.txt" "${constraints_file}"
        rm -rf "${tmp_repo}"
        return
      fi
    done < "${project_sources}"
  fi

  echo "ERROR: No constraints file at ${constraints_file}" >&2
  echo "       Add an 'upper-constraints' entry to containers/${project}/sources.txt for stream '${stream}'," >&2
  echo "       or place the file manually." >&2
  return 1
}

# Clone a repo at a specific commit hash if not already present
# Args: <dest_dir> <url> <pinned_hash>
clone_at_hash() {
  local dest="$1"
  local url="$2"
  local pinned_hash="$3"

  if [[ -d "${dest}" ]]; then
    return
  fi

  mkdir -p "$(dirname "${dest}")"
  echo "--- Cloning ${url} at ${pinned_hash} into ${dest} ---"
  git clone "${url}" "${dest}"
  git -C "${dest}" checkout "${pinned_hash}"
  _AUTO_CLONED["${dest}"]=1
}

# Process sources.txt files for a stream.
# Project-level sources → containers/<project>/src/<name>/
# Image-level sources → containers/<project>/<image>/src/<name>/
# sources.txt format: <stream> <name> <repo-url> <branch-to-follow> <pinned-hash>
ensure_sources_for_stream() {
  local dir_name="$1"   # e.g., "watcher/watcher-api"
  local stream="$2"
  local project="${dir_name%%/*}"

  # Project-level sources.txt → containers/<project>/src/<name>/
  local project_sources="${CONTAINERS_DIR}/${project}/sources.txt"
  if [[ -f "${project_sources}" ]]; then
    local project_src_dir="${CONTAINERS_DIR}/${project}/src"
    while IFS=' ' read -r entry_stream name url branch pinned_hash; do
      [[ -z "${entry_stream}" || "${entry_stream}" == \#* ]] && continue
      [[ "${entry_stream}" != "${stream}" ]] && continue
      [[ "${name}" == "upper-constraints" ]] && continue
      clone_at_hash "${project_src_dir}/${name}" "${url}" "${pinned_hash}"
    done < "${project_sources}"
  fi

  # Image-level sources.txt → containers/<project>/<image>/src/<name>/
  local image_sources="${CONTAINERS_DIR}/${dir_name}/sources.txt"
  if [[ -f "${image_sources}" ]]; then
    local image_src_dir="${CONTAINERS_DIR}/${dir_name}/src"
    while IFS=' ' read -r entry_stream name url branch pinned_hash; do
      [[ -z "${entry_stream}" || "${entry_stream}" == \#* ]] && continue
      [[ "${entry_stream}" != "${stream}" ]] && continue
      [[ "${name}" == "upper-constraints" ]] && continue
      clone_at_hash "${image_src_dir}/${name}" "${url}" "${pinned_hash}"
    done < "${image_sources}"
  fi
}

# Build a single image
build_image() {
  local dir_name="$1"
  local full_tag
  full_tag="$(image_tag "${dir_name}")"
  local project
  project="$(project_name "${dir_name}")"

  echo "=== Building ${full_tag} ==="

  # openstack-base image: no service source, build context is its own directory
  if [[ -z "${project}" ]]; then
    local base_constraints="${CONSTRAINTS_FILE}.${STREAM}"
    local base_lock="${CONTAINERS_DIR}/${dir_name}/${base_constraints}"
    if [[ ! -f "${base_lock}" ]]; then
      ensure_project_constraints "${dir_name}" "${STREAM}"
      base_constraints="${UPSTREAM_CONSTRAINTS}.${STREAM}"
    fi
    buildah bud \
      $(image_tag_args "${dir_name}") \
      --build-arg "CONSTRAINTS_FILE=${base_constraints}" \
      --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
      ${PIP_NO_BINARY:+--build-arg "PIP_NO_BINARY=${PIP_NO_BINARY}"} \
      -f "${CONTAINERS_DIR}/${dir_name}/Containerfile" \
      "${CONTAINERS_DIR}/${dir_name}/"
    return
  fi

  # Ensure stream is set for service images
  if [[ -z "${STREAM}" ]]; then
    echo "ERROR: STREAM is required for building service images." >&2
    echo "       Example: STREAM=master ./build.sh build ${dir_name}" >&2
    return 1
  fi

  # Clone sources for this stream
  ensure_sources_for_stream "${dir_name}" "${STREAM}"

  # Verify main source exists
  local sources_dir="${CONTAINERS_DIR}/${project}/src"
  local src="${sources_dir}/${project}"
  if [[ ! -d "${src}" ]]; then
    echo "ERROR: Main source not found at ${src}" >&2
    echo "       Ensure ${project} is listed in sources.txt for stream '${STREAM}'" >&2
    return 1
  fi

  # Prefer lockfile (<CONSTRAINTS_FILE>.<stream>) if available, otherwise fall back to upstream constraints
  local build_constraints="${CONSTRAINTS_FILE}.${STREAM}"
  local lock_file="${CONTAINERS_DIR}/${project}/${build_constraints}"
  if [[ ! -f "${lock_file}" ]]; then
    ensure_project_constraints "${project}" "${STREAM}"
    build_constraints="${UPSTREAM_CONSTRAINTS}.${STREAM}"
  fi

  buildah bud \
    $(image_tag_args "${dir_name}") \
    --build-arg "CONSTRAINTS_FILE=${build_constraints}" \
    --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
    ${PIP_NO_BINARY:+--build-arg "PIP_NO_BINARY=${PIP_NO_BINARY}"} \
    -f "${CONTAINERS_DIR}/${dir_name}/Containerfile" \
    "${CONTAINERS_DIR}/${project}/"
}

# Check that all tags of an image exist locally
verify_image_exists() {
  local dir_name="$1"
  local name
  name="$(image_name "${dir_name}")"
  local missing=()

  IFS=',' read -ra tags <<< "${TAG}"
  for t in "${tags[@]}"; do
    local full_tag="${REGISTRY}/${NAMESPACE}/${name}:${t}"
    if ! buildah inspect "${full_tag}" &>/dev/null; then
      missing+=("${full_tag}")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: The following image tags do not exist locally:" >&2
    for m in "${missing[@]}"; do
      echo "  ${m}" >&2
    done
    return 1
  fi
}

# Push all tags of a single image
push_image() {
  local dir_name="$1"
  local name
  name="$(image_name "${dir_name}")"

  IFS=',' read -ra tags <<< "${TAG}"
  for t in "${tags[@]}"; do
    local full_tag="${REGISTRY}/${NAMESPACE}/${name}:${t}"
    echo "=== Pushing ${full_tag} ==="
    buildah push "${full_tag}"
  done
}

# List all images
list_images() {
  echo "Container images:"
  for dir_name in $(discover_images); do
    local full_tag
    full_tag="$(image_tag "${dir_name}")"
    local project
    project="$(project_name "${dir_name}")"
    if [[ -n "${project}" ]]; then
      echo "  ${dir_name} → ${full_tag}  (project: ${project})"
    else
      echo "  ${dir_name} → ${full_tag}"
    fi
  done
  if [[ -n "${STREAM}" ]]; then
    echo ""
    echo "Stream: ${STREAM}"
  fi
}

# Resolve which images to process (accepts one or more targets)
resolve_targets() {
  local all_images
  all_images=($(discover_images))
  local resolved=()

  for target in "$@"; do
    if [[ "${target}" == "all" ]]; then
      echo "${all_images[@]}"
      return
    fi

    local found=0

    # Exact match
    for dir_name in "${all_images[@]}"; do
      if [[ "${dir_name}" == "${target}" ]]; then
        resolved+=("${target}")
        found=1
        break
      fi
    done
    [[ ${found} -eq 1 ]] && continue

    # Project prefix match
    for dir_name in "${all_images[@]}"; do
      if [[ "${dir_name}" == "${target}/"* ]]; then
        resolved+=("${dir_name}")
        found=1
      fi
    done
    [[ ${found} -eq 1 ]] && continue

    echo "ERROR: Unknown image or project '${target}'" >&2
    echo "Available images:" >&2
    for dir_name in "${all_images[@]}"; do
      echo "  ${dir_name}" >&2
    done
    return 1
  done

  echo "${resolved[@]}"
}

# Resolve an expression without losing failures in command substitutions.
declare -a _RESOLVED_TARGETS=()
resolve_targets_array() {
  local output
  if ! output=$(resolve_targets "$@"); then
    return 1
  fi
  _RESOLVED_TARGETS=(${output})
}

# Collect selected source manifests in deterministic target order. The parallel
# arrays describe the manifest, source checkout directory, and project context.
declare -a _SOURCE_FILES=()
declare -a _SOURCE_DIRS=()
declare -a _SOURCE_PROJECT_DIRS=()
collect_source_scopes() {
  local -a targets
  local img project sources_file
  declare -A seen=()

  resolve_targets_array "$@" || return 1
  targets=("${_RESOLVED_TARGETS[@]}")
  _SOURCE_FILES=()
  _SOURCE_DIRS=()
  _SOURCE_PROJECT_DIRS=()

  for img in "${targets[@]}"; do
    project="$(project_name "${img}")"
    if [[ -z "${project}" ]]; then
      [[ "${img}" == "base" ]] || continue
      sources_file="${CONTAINERS_DIR}/base/sources.txt"
      if [[ -f "${sources_file}" && -z "${seen[${sources_file}]:-}" ]]; then
        seen["${sources_file}"]=1
        _SOURCE_FILES+=("${sources_file}")
        _SOURCE_DIRS+=("${CONTAINERS_DIR}/base/src")
        _SOURCE_PROJECT_DIRS+=("${CONTAINERS_DIR}/base")
      fi
      continue
    fi

    sources_file="${CONTAINERS_DIR}/${project}/sources.txt"
    if [[ -f "${sources_file}" && -z "${seen[${sources_file}]:-}" ]]; then
      seen["${sources_file}"]=1
      _SOURCE_FILES+=("${sources_file}")
      _SOURCE_DIRS+=("${CONTAINERS_DIR}/${project}/src")
      _SOURCE_PROJECT_DIRS+=("${CONTAINERS_DIR}/${project}")
    fi

    sources_file="${CONTAINERS_DIR}/${img}/sources.txt"
    if [[ -f "${sources_file}" && -z "${seen[${sources_file}]:-}" ]]; then
      seen["${sources_file}"]=1
      _SOURCE_FILES+=("${sources_file}")
      _SOURCE_DIRS+=("${CONTAINERS_DIR}/${img}/src")
      _SOURCE_PROJECT_DIRS+=("${CONTAINERS_DIR}/${project}")
    fi
  done
}

source_record_key() {
  printf '%s\x1f%s\x1f%s\x1f%s' "$1" "$2" "$3" "$4"
}

source_ref_key() {
  printf '%s\x1f%s' "$1" "$2"
}

declare -A _FROZEN_COMMITS=()
declare -A _FROZEN_AUTHORITIES=()
declare -A _FROZEN_REF_COMMITS=()

# Fetch one declared ref into a temporary bare repository and retain its exact
# commit for the rest of this process. This prevents a moving branch from
# changing inputs after preflight.
freeze_remote_ref() {
  local url="$1"
  local ref="$2"
  local ref_key repository
  ref_key="$(source_ref_key "${url}" "${ref}")"
  if [[ -n "${_FROZEN_REF_COMMITS[${ref_key}]:-}" ]]; then
    _FREEZE_RESULT="${_FROZEN_REF_COMMITS[${ref_key}]}"
    return
  fi

  repository=$(mktemp -d)
  git -C "${repository}" init --quiet --bare
  if ! git -C "${repository}" fetch --quiet "${url}" "${ref}"; then
    echo "ERROR: Could not freeze ref '${ref}' for ${url}" >&2
    rm -rf "${repository}"
    return 1
  fi
  if ! _FREEZE_RESULT=$(git -C "${repository}" rev-parse --verify 'FETCH_HEAD^{commit}'); then
    echo "ERROR: Ref '${ref}' for ${url} does not resolve to a commit" >&2
    rm -rf "${repository}"
    return 1
  fi
  _FROZEN_REF_COMMITS["${ref_key}"]="${_FREEZE_RESULT}"
  _FROZEN_REPOSITORIES["${ref_key}"]="${repository}"
}

validate_stream_name() {
  local stream="$1"
  local component
  local -a components
  if [[ ! "${stream}" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || \
     [[ "${stream}" == */ || "${stream}" == *//* ]]; then
    echo "ERROR: Unsafe stream name '${stream}'" >&2
    return 1
  fi
  IFS='/' read -ra components <<< "${stream}"
  for component in "${components[@]}"; do
    if [[ "${component}" == "." || "${component}" == ".." ]]; then
      echo "ERROR: Unsafe stream name '${stream}'" >&2
      return 1
    fi
  done
}

# Resolve and record every selected source before the first tracked mutation.
freeze_source_refs() {
  local stream="${!#}"
  local targets_args=("${@:1:$#-1}")
  local manifest_dir manifest_tmp
  local index line entry_stream name url branch pinned_hash extra
  local sources_file src_dir relative_file record_key authority frozen

  validate_stream_name "${stream}" || return 1
  collect_source_scopes "${targets_args[@]}" || return 1
  _FROZEN_COMMITS=()
  _FROZEN_AUTHORITIES=()
  _FROZEN_REF_COMMITS=()
  _FROZEN_REPOSITORIES=()

  manifest_dir="$(dirname "${SOURCE_REFS_MANIFEST}")"
  if [[ "${manifest_dir}" != "${REPO_ROOT}/.tmp/source-maintenance" ]]; then
    echo "ERROR: Frozen source manifest escaped repository temporary state" >&2
    return 1
  fi
  mkdir -p "${manifest_dir}"
  rm -f "${SOURCE_REFS_MANIFEST}"
  manifest_tmp=$(mktemp "${manifest_dir}/.frozen-source-refs.XXXXXX")
  printf 'source_file\tstream\tname\turl\tdeclared_ref\tcommitted_pin\tfrozen_commit\tauthority\n' > "${manifest_tmp}"

  for index in "${!_SOURCE_FILES[@]}"; do
    sources_file="${_SOURCE_FILES[${index}]}"
    src_dir="${_SOURCE_DIRS[${index}]}"
    relative_file="${sources_file#"${REPO_ROOT}/"}"
    while IFS= read -r line; do
      [[ -z "${line}" || "${line}" == \#* ]] && continue
      read -r entry_stream name url branch pinned_hash extra <<< "${line}"
      [[ "${entry_stream}" == "${stream}" ]] || continue
      if [[ -z "${name}" || -z "${url}" || -z "${branch}" || -z "${pinned_hash}" || -n "${extra:-}" ]]; then
        echo "ERROR: Malformed source record in ${relative_file}: ${line}" >&2
        rm -f "${manifest_tmp}"
        return 1
      fi

      record_key="$(source_record_key "${sources_file}" "${name}" "${url}" "${branch}")"
      if [[ "${name}" != "upper-constraints" && -d "${src_dir}/${name}" ]]; then
        local checkout_root
        checkout_root=$(git -C "${src_dir}/${name}" rev-parse --show-toplevel 2>/dev/null || true)
        if [[ -z "${checkout_root}" || "$(realpath -e "${checkout_root}")" != "$(realpath -e "${src_dir}/${name}")" ]] || \
           ! frozen=$(git -C "${src_dir}/${name}" rev-parse --verify 'HEAD^{commit}' 2>/dev/null); then
          echo "ERROR: Pre-existing source is not a Git checkout: ${src_dir}/${name}" >&2
          rm -f "${manifest_tmp}"
          return 1
        fi
        authority="pre-existing-checkout"
      else
        if [[ -n "${SKIP_HASH_UPDATE}" ]]; then
          freeze_remote_ref "${url}" "${pinned_hash}" || {
            rm -f "${manifest_tmp}"
            return 1
          }
          authority="committed-pin"
        else
          freeze_remote_ref "${url}" "${branch}" || {
            rm -f "${manifest_tmp}"
            return 1
          }
          authority="declared-ref"
        fi
        frozen="${_FREEZE_RESULT}"
      fi

      _FROZEN_COMMITS["${record_key}"]="${frozen}"
      _FROZEN_AUTHORITIES["${record_key}"]="${authority}"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${relative_file}" "${entry_stream}" "${name}" "${url}" \
        "${branch}" "${pinned_hash}" "${frozen}" "${authority}" \
        >> "${manifest_tmp}"
    done < "${sources_file}"
  done

  mv "${manifest_tmp}" "${SOURCE_REFS_MANIFEST}"
  echo "--- Frozen source references: ${SOURCE_REFS_MANIFEST} ---"
}

# Materialize one source declaration from its frozen preflight repository and
# update its maintained pin only in advancement mode.
update_sources_file() {
  local sources_file="$1"
  local stream="$2"
  local src_dir="$3"
  local project_dir="$4"
  local tmp_file line entry_stream name url branch pinned_hash extra
  local record_key ref_key frozen authority repository output_tmp
  local updated=0

  tmp_file=$(mktemp)
  while IFS= read -r line; do
    if [[ -z "${line}" || "${line}" == \#* ]]; then
      echo "${line}" >> "${tmp_file}"
      continue
    fi

    read -r entry_stream name url branch pinned_hash extra <<< "${line}"
    if [[ "${entry_stream}" != "${stream}" ]]; then
      echo "${line}" >> "${tmp_file}"
      continue
    fi

    record_key="$(source_record_key "${sources_file}" "${name}" "${url}" "${branch}")"
    frozen="${_FROZEN_COMMITS[${record_key}]:-}"
    authority="${_FROZEN_AUTHORITIES[${record_key}]:-}"
    if [[ -z "${frozen}" || -z "${authority}" ]]; then
      echo "ERROR: Missing frozen source record for ${name} in ${sources_file}" >&2
      rm -f "${tmp_file}"
      return 1
    fi

    if [[ "${authority}" == "pre-existing-checkout" ]]; then
      echo "  ${name}: skipped (pre-existing checkout at ${src_dir}/${name})"
    else
      if [[ "${authority}" == "committed-pin" ]]; then
        ref_key="$(source_ref_key "${url}" "${pinned_hash}")"
      else
        ref_key="$(source_ref_key "${url}" "${branch}")"
      fi
      repository="${_FROZEN_REPOSITORIES[${ref_key}]:-}"
      if [[ -z "${repository}" || ! -d "${repository}" ]]; then
        echo "ERROR: Missing frozen repository for ${name}" >&2
        rm -f "${tmp_file}"
        return 1
      fi

      if [[ "${name}" == "upper-constraints" ]]; then
        output_tmp=$(mktemp "${project_dir}/.${UPSTREAM_CONSTRAINTS}.${stream}.XXXXXX")
        if ! git -C "${repository}" show "${frozen}:upper-constraints.txt" > "${output_tmp}"; then
          rm -f "${output_tmp}" "${tmp_file}"
          return 1
        fi
        mv "${output_tmp}" "${project_dir}/${UPSTREAM_CONSTRAINTS}.${stream}"
      else
        mkdir -p "${src_dir}"
        echo "--- Materializing ${url} at ${frozen} into ${src_dir}/${name} ---"
        git -C "${src_dir}" init --quiet "${name}"
        _AUTO_CLONED["${src_dir}/${name}"]=1
        git -C "${src_dir}/${name}" fetch --quiet "${repository}" "${frozen}"
        git -C "${src_dir}/${name}" checkout --quiet --detach FETCH_HEAD
      fi
    fi

    if [[ -z "${SKIP_HASH_UPDATE}" && "${authority}" != "pre-existing-checkout" && "${frozen}" != "${pinned_hash}" ]]; then
      echo "  ${name}: ${pinned_hash} → ${frozen} (${branch})"
      pinned_hash="${frozen}"
      updated=1
    fi
    echo "${entry_stream} ${name} ${url} ${branch} ${pinned_hash}" >> "${tmp_file}"
  done < "${sources_file}"

  if [[ ${updated} -eq 1 ]]; then
    install -m 644 "${tmp_file}" "${sources_file}"
  else
    echo "  (no pin changes)"
  fi
  rm "${tmp_file}"
}

# Collect Python package names provided via RPMs from bindeps.txt and
# builddeps.txt across a project and its images.  RPM packages for Python
# modules follow the convention python3-<module>.  Returns normalized pip
# package names (lowercase, dots/underscores replaced with hyphens) one per
# line.
collect_rpm_python_packages() {
  local project_dir="$1"
  local -A seen

  for depfile in "${project_dir}"/bindeps.txt "${project_dir}"/builddeps.txt; do
    [[ -f "${depfile}" ]] || continue
    while IFS= read -r line; do
      line="${line%%#*}"
      line="${line// /}"
      [[ -z "${line}" ]] && continue
      if [[ "${line}" == python3-* ]]; then
        local pkg="${line#python3-}"
        pkg=$(echo "${pkg}" | tr '[:upper:]' '[:lower:]' | sed 's/[._]/-/g')
        seen["${pkg}"]=1
      fi
    done < "${depfile}"
  done

  for image_dir in "${project_dir}"/*/; do
    local image
    image=$(basename "${image_dir}")
    [[ "${image}" == "common" || "${image}" == "src" ]] && continue
    [[ ! -f "${image_dir}/Containerfile" ]] && continue

    for depfile in "${image_dir}"/bindeps.txt "${image_dir}"/builddeps.txt; do
      [[ -f "${depfile}" ]] || continue
      while IFS= read -r line; do
        line="${line%%#*}"
        line="${line// /}"
        [[ -z "${line}" ]] && continue
        if [[ "${line}" == python3-* ]]; then
          local pkg="${line#python3-}"
          pkg=$(echo "${pkg}" | tr '[:upper:]' '[:lower:]' | sed 's/[._]/-/g')
          seen["${pkg}"]=1
        fi
      done < "${depfile}"
    done
  done

  printf '%s\n' "${!seen[@]}"
}

# Remove entries for RPM-provided packages from a pip-compile lockfile.
# Args: <lockfile> <space-separated normalized package names>
filter_lockfile_rpm_packages() {
  local lockfile="$1"
  local exclude_str="$2"

  [[ -z "${exclude_str}" ]] && return

  local tmp
  tmp=$(mktemp)
  awk -v excl="${exclude_str}" '
  BEGIN {
    n = split(excl, arr, " ")
    for (i = 1; i <= n; i++) exclude[arr[i]] = 1
  }
  /^[a-zA-Z]/ {
    pkg = $0
    sub(/[>=<\[;].*/, "", pkg)
    gsub(/^[ \t]+|[ \t]+$/, "", pkg)
    norm = tolower(pkg)
    gsub(/[._]/, "-", norm)
    if (norm in exclude) { skip = 1; next }
    skip = 0; print; next
  }
  /^[ \t]/ { if (!skip) print; next }
  { skip = 0; print }
  ' "${lockfile}" > "${tmp}"
  install -m 644 "${tmp}" "${lockfile}"
  rm "${tmp}"
}

# Remove generator-runtime and package-index details from a lock file.
normalize_generated_lock() {
  local lockfile="$1"
  local tmp
  tmp=$(mktemp)

  awk '
  !seen_package && /^--(index-url|extra-index-url|trusted-host)[[:space:]]/ {
    next
  }
  !seen_package && (/^#/ || /^$/) { next }
  !/^#/ { seen_package = 1 }
  { print }
  ' "${lockfile}" > "${tmp}"
  install -m 644 "${tmp}" "${lockfile}"
  rm "${tmp}"
}

# Generate a single requirements.lock for a project by running pip-compile
# against requirements.txt from all source packages (project + all images)
# plus pythondeps.txt and pythonbuilddeps.txt from every image,
# constrained by upper-constraints.txt.
# The resulting lockfile pins every transitive dependency and replaces
# upper-constraints.txt as the constraints file used during container builds.
generate_requirements_lock() {
  local project="$1"   # e.g., "watcher"
  local stream="$2"    # e.g., "master"
  local project_dir="${CONTAINERS_DIR}/${project}"
  local constraints_file="${project_dir}/${UPSTREAM_CONSTRAINTS}.${stream}"

  if [[ ! -f "${constraints_file}" ]]; then
    echo "WARNING: No constraints file at ${constraints_file}, skipping lock for ${project}" >&2
    return
  fi

  # Collect input files using relative paths (from project_dir) so that
  # pip-compile doesn't embed full filesystem paths in the output.
  local input_files=()

  for req in "${project_dir}"/src/*/requirements.txt; do
    [[ -f "${req}" ]] && input_files+=("${req#"${project_dir}"/}")
  done

  # Collect dep files at the project level (used by base container)
  for depfile in pythondeps.txt pythonbuilddeps.txt; do
    if [[ -f "${project_dir}/${depfile}" ]]; then
      input_files+=("${depfile}")
    fi
  done

  # Collect requirements.txt and dep files from all images in the project
  for image_dir in "${project_dir}"/*/; do
    local image=$(basename "${image_dir}")
    [[ "${image}" == "common" || "${image}" == "src" ]] && continue
    [[ ! -f "${image_dir}/Containerfile" ]] && continue

    for req in "${image_dir}"/src/*/requirements.txt; do
      [[ -f "${req}" ]] && input_files+=("${req#"${project_dir}"/}")
    done

    for depfile in pythondeps.txt pythonbuilddeps.txt; do
      if [[ -f "${image_dir}/${depfile}" ]]; then
        input_files+=("${image}/${depfile}")
      fi
    done
  done

  if [[ ${#input_files[@]} -eq 0 ]]; then
    echo "WARNING: No requirements.txt found in source packages, skipping lock for ${project}" >&2
    return
  fi

  local lock_file="${CONSTRAINTS_FILE}.${stream}"

  echo "--- Generating ${project_dir}/${lock_file} ---"
  (cd "${project_dir}" && \
    pip-compile --allow-unsafe --no-annotate --strip-extras \
      -c "${UPSTREAM_CONSTRAINTS}.${stream}" \
      -o "${lock_file}" \
      "${input_files[@]}" && \
    normalize_generated_lock "${lock_file}")

  local rpm_pkgs
  rpm_pkgs=$(collect_rpm_python_packages "${project_dir}")
  if [[ -n "${rpm_pkgs}" ]]; then
    local exclude_str
    exclude_str=$(echo "${rpm_pkgs}" | tr '\n' ' ')
    echo "--- Filtering RPM-provided packages from ${lock_file}: ${exclude_str}---"
    filter_lockfile_rpm_packages "${project_dir}/${lock_file}" "${exclude_str}"
  fi
}

# Generate requirements.lock for each project in the target scope.
# Expects sources to be already cloned and constraints fetched
# (done by update_sources). Cloned repos are cleaned up on exit.
generate_locks_for_targets() {
  local stream="${!#}"
  local targets_args=("${@:1:$#-1}")

  if ! command -v pip-compile &>/dev/null; then
    echo "ERROR: pip-compile not found. Install it with: pip install pip-tools" >&2
    return 1
  fi

  local targets
  targets=($(resolve_targets "${targets_args[@]}"))

  declare -A _lock_projects_seen
  for img in "${targets[@]}"; do
    local project
    project="$(project_name "${img}")"
    if [[ -z "${project}" ]]; then
      [[ "${img}" != "base" ]] && continue
      project="base"
    fi
    [[ -n "${_lock_projects_seen[$project]:-}" ]] && continue
    _lock_projects_seen["${project}"]=1

    generate_requirements_lock "${project}" "${stream}"
  done
}

# Generate a buildrequirements.lock for a project by running pybuild-deps
# compile against the requirements.lock produced by generate_requirements_lock.
generate_buildrequirements_lock() {
  local project="$1"
  local stream="$2"
  local project_dir="${CONTAINERS_DIR}/${project}"
  local lock_file="${project_dir}/${CONSTRAINTS_FILE}.${stream}"
  local build_lock_file="${BUILD_CONSTRAINTS_FILE}.${stream}"

  if [[ ! -f "${lock_file}" ]]; then
    echo "WARNING: No ${lock_file} found, skipping build lock for ${project}" >&2
    return
  fi

  echo "--- Generating ${project_dir}/${build_lock_file} ---"
  (cd "${project_dir}" && \
    pybuild-deps compile \
      --no-annotate \
      -o "${build_lock_file}" \
      "${CONSTRAINTS_FILE}.${stream}" && \
    normalize_generated_lock "${build_lock_file}")
}

# Generate buildrequirements.lock for each project in the target scope.
generate_buildlocks_for_targets() {
  local stream="${!#}"
  local targets_args=("${@:1:$#-1}")

  if ! command -v pybuild-deps &>/dev/null; then
    echo "ERROR: pybuild-deps not found. Install it with: pip install pybuild-deps" >&2
    return 1
  fi

  local targets
  targets=($(resolve_targets "${targets_args[@]}"))

  declare -A _buildlock_projects_seen
  for img in "${targets[@]}"; do
    local project
    project="$(project_name "${img}")"
    if [[ -z "${project}" ]]; then
      [[ "${img}" != "base" ]] && continue
      project="base"
    fi
    [[ -n "${_buildlock_projects_seen[$project]:-}" ]] && continue
    _buildlock_projects_seen["${project}"]=1

    generate_buildrequirements_lock "${project}" "${stream}"
  done
}

# Generate rpms.in.yaml for a project by collecting all packages from
# bindeps.txt and builddeps.txt across every image in the project.
generate_rpms_in_yaml() {
  local project="$1"
  local project_dir="${CONTAINERS_DIR}/${project}"
  local output="${project_dir}/rpms.in.yaml"

  local -A pkgs_seen

  # Collect dep files at the project level (used by base container)
  for depfile in bindeps.txt builddeps.txt; do
    [[ -f "${project_dir}/${depfile}" ]] || continue
    while IFS= read -r line; do
      line="${line%%#*}"
      line="${line// /}"
      [[ -z "${line}" ]] && continue
      pkgs_seen["${line}"]=1
    done < "${project_dir}/${depfile}"
  done

  # Collect dep files from all images in the project
  for image_dir in "${project_dir}"/*/; do
    local image=$(basename "${image_dir}")
    [[ "${image}" == "common" || "${image}" == "src" ]] && continue
    [[ ! -f "${image_dir}/Containerfile" ]] && continue

    for depfile in bindeps.txt builddeps.txt; do
      [[ -f "${image_dir}/${depfile}" ]] || continue
      while IFS= read -r line; do
        line="${line%%#*}"
        line="${line// /}"
        [[ -z "${line}" ]] && continue
        pkgs_seen["${line}"]=1
      done < "${image_dir}/${depfile}"
    done
  done

  if [[ ${#pkgs_seen[@]} -eq 0 ]]; then
    echo "WARNING: No packages found for ${project}, skipping rpms.in.yaml" >&2
    return
  fi

  local sorted_pkgs
  sorted_pkgs=$(printf '%s\n' "${!pkgs_seen[@]}" | sort)

  echo "--- Generating ${output} ---"
  {
    cat <<'HEADER'
contentOrigin:
  repofiles:
    - ./rpms.repo
context:
  bare: true

#
# To update rpms.lock.yaml:
#    rpm-lockfile-prototype rpms.in.yaml
#

arches:
  - x86_64
  - aarch64

packages:
HEADER
    while IFS= read -r pkg; do
      echo "  - ${pkg}"
    done <<< "${sorted_pkgs}"
  } > "${output}"
}

# Generate rpms.in.yaml for each project in the target scope.
generate_rpms_in_for_targets() {
  local targets
  targets=($(resolve_targets "$@"))

  declare -A _rpms_projects_seen
  for img in "${targets[@]}"; do
    local project
    project="$(project_name "${img}")"
    if [[ -z "${project}" ]]; then
      [[ "${img}" != "base" ]] && continue
      project="base"
    fi
    [[ -n "${_rpms_projects_seen[$project]:-}" ]] && continue
    _rpms_projects_seen["${project}"]=1

    generate_rpms_in_yaml "${project}"
  done
}

# Ensure sources and constraints exist for targets without updating hashes.
# Clones repos at the pinned hashes already recorded in sources.txt and
# fetches upper-constraints.txt at those same hashes.
ensure_sources_for_targets() {
  local stream="${!#}"
  local targets_args=("${@:1:$#-1}")

  if [[ -z "${stream}" ]]; then
    echo "ERROR: STREAM is required for update-sources." >&2
    return 1
  fi

  local targets
  targets=($(resolve_targets "${targets_args[@]}"))

  declare -A _ensure_projects_seen

  for img in "${targets[@]}"; do
    local project
    project="$(project_name "${img}")"

    if [[ -z "${project}" ]]; then
      if [[ "${img}" == "base" ]] && [[ -z "${_ensure_projects_seen[base]:-}" ]]; then
        _ensure_projects_seen["base"]=1
        ensure_project_constraints "base" "${stream}"
      fi
      continue
    fi

    ensure_sources_for_stream "${img}" "${stream}"

    if [[ -z "${_ensure_projects_seen[$project]:-}" ]]; then
      _ensure_projects_seen["${project}"]=1
      ensure_project_constraints "${project}" "${stream}"
    fi
  done
}

# Materialize all preflight-frozen sources and update maintained pins only when
# SKIP_HASH_UPDATE is unset.
update_sources() {
  local stream="${!#}"
  local index sources_file

  if [[ -z "${stream}" ]]; then
    echo "ERROR: STREAM is required for update-sources." >&2
    echo "       Example: STREAM=master ./build.sh update-sources watcher" >&2
    return 1
  fi
  if [[ ${#_SOURCE_FILES[@]} -eq 0 ]]; then
    echo "ERROR: Source preflight did not collect any manifests" >&2
    return 1
  fi

  for index in "${!_SOURCE_FILES[@]}"; do
    sources_file="${_SOURCE_FILES[${index}]}"
    echo "--- Updating ${sources_file} (stream: ${stream}) ---"
    if ! update_sources_file "${sources_file}" "${stream}" \
          "${_SOURCE_DIRS[${index}]}" \
          "${_SOURCE_PROJECT_DIRS[${index}]}"; then
      echo "ERROR: Failed to update ${sources_file}" >&2
      return 1
    fi
  done
}

# Main
ACTION="${1:-}"
shift || true
if [[ $# -gt 0 ]]; then
  TARGETS=("$@")
else
  TARGETS=("all")
fi

case "${ACTION}" in
  build)
    for img in $(resolve_targets "${TARGETS[@]}"); do
      build_image "${img}"
    done
    ;;
  build-parallel)
    _bp_targets=($(resolve_targets "${TARGETS[@]}"))

    # Build base first (all service images depend on it)
    for _bp_img in "${_bp_targets[@]}"; do
      [[ -n "$(project_name "${_bp_img}")" ]] && continue
      build_image "${_bp_img}"
    done

    # Pre-clone sources so parallel builds don't race on the same directories
    for _bp_img in "${_bp_targets[@]}"; do
      [[ -z "$(project_name "${_bp_img}")" ]] && continue
      ensure_sources_for_stream "${_bp_img}" "${STREAM}"
    done

    # Build service images in parallel (max PARALLEL at a time)
    if [[ -n "${BUILD_LOGS_DIR:-}" ]]; then
      _bp_logdir="${BUILD_LOGS_DIR}"
      mkdir -p "${_bp_logdir}"
    else
      _bp_logdir=$(mktemp -d)
    fi
    _bp_service_imgs=()
    for _bp_img in "${_bp_targets[@]}"; do
      [[ -z "$(project_name "${_bp_img}")" ]] && continue
      _bp_service_imgs+=("${_bp_img}")
    done

    if [[ ${#_bp_service_imgs[@]} -gt 0 ]]; then
      echo "--- Building ${#_bp_service_imgs[@]} images (max ${PARALLEL} parallel) ---"
      declare -A _bp_pids=()
      _bp_fail=0
      _bp_running=0

      for _bp_img in "${_bp_service_imgs[@]}"; do
        # Wait for a slot if at the limit
        while [[ ${_bp_running} -ge ${PARALLEL} ]]; do
          if ! wait -n; then
            _bp_fail=1
            break 2
          fi
          ((_bp_running--)) || true
        done

        _bp_log="${_bp_logdir}/${_bp_img//\//_}.log"
        build_image "${_bp_img}" > "${_bp_log}" 2>&1 &
        _bp_pids[$!]="${_bp_img}"
        ((_bp_running++)) || true
      done

      # Wait for remaining builds
      if [[ ${_bp_fail} -eq 0 ]]; then
        while [[ ${_bp_running} -gt 0 ]]; do
          if ! wait -n; then
            _bp_fail=1
            break
          fi
          ((_bp_running--)) || true
        done
      fi

      # Show logs for all builds
      for _bp_log in "${_bp_logdir}"/*.log; do
        _bp_name=$(basename "${_bp_log}" .log)
        echo "=== ${_bp_name} ==="
        cat "${_bp_log}"
        echo ""
      done

      if [[ ${_bp_fail} -eq 1 ]]; then
        echo "ERROR: A build failed, killing remaining builds" >&2
        for _bp_pid in "${!_bp_pids[@]}"; do
          kill "${_bp_pid}" 2>/dev/null || true
        done
        wait 2>/dev/null || true
        [[ -z "${BUILD_LOGS_DIR:-}" ]] && rm -rf "${_bp_logdir}"
        exit 1
      fi

      [[ -z "${BUILD_LOGS_DIR:-}" ]] && rm -rf "${_bp_logdir}"
      echo "=== All builds completed successfully ==="
    fi
    ;;
  push)
    _push_targets=($(resolve_targets "${TARGETS[@]}"))

    # Verify all images and tags exist before pushing any
    echo "--- Verifying all images exist locally ---"
    for img in "${_push_targets[@]}"; do
      verify_image_exists "${img}"
    done

    # All verified — push
    for img in "${_push_targets[@]}"; do
      push_image "${img}"
    done
    ;;
  update-sources)
    if [[ -n "${SKIP_HASH_UPDATE}" ]]; then
      echo "=== Skipping hash update (SKIP_HASH_UPDATE is set) ==="
    fi
    freeze_source_refs "${TARGETS[@]}" "${STREAM}"
    update_sources "${TARGETS[@]}" "${STREAM}"

    # Generate lockfiles and metadata
    echo ""
    echo "=== Generating rpms.in.yaml files ==="
    generate_rpms_in_for_targets "${TARGETS[@]}"

    echo ""
    echo "=== Generating requirements.lock files ==="
    generate_locks_for_targets "${TARGETS[@]}" "${STREAM}"

    echo ""
    echo "=== Generating buildrequirements.lock files ==="
    generate_buildlocks_for_targets "${TARGETS[@]}" "${STREAM}"

    # Create un-streamed symlinks for the default stream
    if [[ "${STREAM}" == "${DEFAULT_STREAM}" ]]; then
      echo ""
      echo "=== Creating default stream symlinks (${DEFAULT_STREAM}) ==="
      _symlink_targets=($(resolve_targets "${TARGETS[@]}"))
      declare -A _symlink_seen
      for _s_img in "${_symlink_targets[@]}"; do
        _s_project="$(project_name "${_s_img}")"
        if [[ -z "${_s_project}" ]]; then
          [[ "${_s_img}" != "base" ]] && continue
          _s_project="base"
        fi
        [[ -n "${_symlink_seen[$_s_project]:-}" ]] && continue
        _symlink_seen["${_s_project}"]=1

        _s_pdir="${CONTAINERS_DIR}/${_s_project}"
        for _s_suffix in "${UPSTREAM_CONSTRAINTS}" "${CONSTRAINTS_FILE}" "${BUILD_CONSTRAINTS_FILE}"; do
          _s_streamed="${_s_pdir}/${_s_suffix}.${DEFAULT_STREAM}"
          if [[ -f "${_s_streamed}" ]]; then
            ln -sf "${_s_suffix}.${DEFAULT_STREAM}" "${_s_pdir}/${_s_suffix}"
            echo "  ${_s_pdir}/${_s_suffix} -> ${_s_suffix}.${DEFAULT_STREAM}"
          fi
        done
      done
    fi
    ;;
  install-deps)
    SYSTEM_DEPS=(git buildah podman)
    echo "=== Installing system dependencies ==="
    echo "Packages: ${SYSTEM_DEPS[*]}"
    if command -v dnf &>/dev/null; then
      sudo dnf install -y "${SYSTEM_DEPS[@]}"
    elif command -v microdnf &>/dev/null; then
      sudo microdnf install -y "${SYSTEM_DEPS[@]}"
    elif command -v apt-get &>/dev/null; then
      sudo apt-get install -y "${SYSTEM_DEPS[@]}"
    else
      echo "ERROR: No supported package manager found (dnf, microdnf, yum, apt-get)" >&2
      exit 1
    fi

    echo ""
    echo "=== Done ==="
    ;;
  list)
    list_images
    ;;
  *)
    echo "Usage: STREAM=<name> $0 {build|build-parallel|push|update-sources|install-deps|list} [target ...]"
    echo ""
    echo "Images (discovered from containers/):"
    for dir_name in $(discover_images); do
      echo "  ${dir_name} → $(image_name "${dir_name}")"
    done
    echo ""
    echo "sources.txt format:"
    echo "  <stream> <name> <repo-url> <branch-to-follow> <pinned-hash>"
    echo ""
    echo "Environment variables:"
    echo "  STREAM            Stream name (required for build)"
    echo "  REGISTRY          Container registry (default: localhost)"
    echo "  NAMESPACE         Registry namespace (default: openstack)"
    echo "  TAG               Image tag(s), comma-separated (default: latest)"
    echo "  IMAGE_PREFIX      Prefix for image names (default: openstack)"
    echo "  BASE_IMAGE        Base image for the base container"
    echo "  CONSTRAINTS_FILE  Constraints/lockfile base name (default: requirements.lock)"
    echo "  BUILD_CONSTRAINTS_FILE  Build-requirements lockfile base name (default: buildrequirements.lock)"
    echo "  DEFAULT_STREAM    Default stream for un-streamed symlinks (default: master)"
    echo "  PARALLEL          Max concurrent builds for build-parallel (default: nproc)"
    echo "  BUILD_LOGS_DIR    Persist build-parallel logs to this directory"
    echo "  SKIP_HASH_UPDATE  Skip updating pinned hashes; regenerate locks only"
    echo "  PIP_NO_BINARY     Pass PIP_NO_BINARY to container build (e.g., ':all:')"
    echo ""
    echo "Source directories: containers/<project>/src/<name>/"
    echo "Overrides:          containers/<project>/src/overrides/<pkg>/"
    exit 1
    ;;
esac
