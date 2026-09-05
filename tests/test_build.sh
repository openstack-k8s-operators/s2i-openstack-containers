#!/usr/bin/env bash
# Tests for build.sh build, refs, resolve, and build-parallel actions.
#
# Creates a minimal containers tree with a fake buildah so tests run
# offline and without real container builds.
#
# Usage:
#   bash tests/test_build.sh
#   tox -e test
#
set -uo pipefail

# ── Test runner ──────────────────────────────────────────────────────────

_PASS=0
_FAIL=0

assert() {
  local desc="$1"
  shift
  if "$@"; then
    return 0
  fi
  echo "    ASSERTION FAILED: ${desc}"
  echo "      command: $*"
  return 1
}

assert_file_exists() { assert "file exists: $1" test -f "$1"; }
assert_grep()        { assert "grep '$1' in $2" grep -q "$1" "$2"; }
assert_no_grep()     {
  if grep -q "$1" "$2" 2>/dev/null; then
    echo "    ASSERTION FAILED: '$1' should not appear in $2"
    return 1
  fi
}

run_test() {
  local name="$1"

  _setup_fixture

  local rc=0
  ( set -e; "${name}" ) || rc=$?

  if [[ ${rc} -eq 0 ]]; then
    echo "  PASS  ${name}"
    ((_PASS++))
  else
    echo "  FAIL  ${name}"
    ((_FAIL++))
    if [[ -f "${TEST_DIR}/build.log" ]]; then
      echo "    --- build.log (last 20 lines) ---"
      tail -20 "${TEST_DIR}/build.log" | sed 's/^/    /'
      echo "    ---"
    fi
  fi

  _teardown_fixture
}

# ── Fixture ──────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR=""

_setup_fixture() {
  TEST_DIR="$(mktemp -d)"

  # Symlink build.sh
  ln -s "${SCRIPT_DIR}/build.sh" "${TEST_DIR}/build.sh"

  # Containers tree: base + two images
  for target in base alpha/one beta/two; do
    local image_root="${TEST_DIR}/containers/${target}"
    mkdir -p "${image_root}"
    echo "FROM scratch" > "${image_root}/Containerfile"
    local project="${target%%/*}"
    local project_root="${TEST_DIR}/containers/${project}"
    touch "${project_root}/requirements.lock.master"
    if [[ "${target}" == */* ]]; then
      mkdir -p "${project_root}/src/${project}"
    fi
  done

  # Fake buildah (bash, not python -- no python dependency)
  mkdir -p "${TEST_DIR}/bin"
  cat > "${TEST_DIR}/bin/buildah" <<'FAKE_BUILDAH'
#!/usr/bin/env bash
set -eu
case "$1" in
  bud)
    echo "ARGS $*"
    echo "HTTP_PROXY=${HTTP_PROXY:-}"
    for i in $(seq 2 $#); do
      if [[ "${!i}" == "-f" ]]; then
        next=$((i + 1))
        cf="${!next}"
        dir="$(dirname "${cf}")"
        image="$(basename "${dir}")"
        parent="$(basename "$(dirname "${dir}")")"
        [[ "${parent}" != "containers" ]] && image="${parent}/${image}"
        if [[ "${image}" != "base" ]]; then
          echo "LIVE ${image}"
          sleep 0.5
        fi
        if [[ -n "${FAIL_IMAGE:-}" ]] && [[ "${image}" == *"${FAIL_IMAGE}" ]]; then
          echo "FAIL ${image}" >&2
          exit 9
        fi
        echo "DONE ${image}"
        exit 0
      fi
    done
    exit 2
    ;;
  inspect|push)
    exit 0
    ;;
  *)
    exit 2
    ;;
esac
FAKE_BUILDAH
  chmod +x "${TEST_DIR}/bin/buildah"

  cat > "${TEST_DIR}/bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -eu
echo "CURL $*" >> "${CURL_LOG}"
[[ -z "${FAIL_CACHE_HEALTH:-}" ]]
FAKE_CURL
  chmod +x "${TEST_DIR}/bin/curl"
  export CURL_LOG="${TEST_DIR}/curl.log"

  # Logs directory
  mkdir -p "${TEST_DIR}/logs"
}

_teardown_fixture() {
  [[ -n "${TEST_DIR}" ]] && rm -rf "${TEST_DIR}"
}

_run() {
  local action="$1"
  shift
  (
    cd "${TEST_DIR}"
    export PATH="${TEST_DIR}/bin:${PATH}"
    export STREAM=master
    export REGISTRY=registry.test:5000
    export NAMESPACE=openstack
    export TAG=test
    export PARALLEL=2
    export BUILD_LOGS_DIR="${TEST_DIR}/logs"
    ./build.sh "${action}" "$@"
  )
}

# ── Tests ────────────────────────────────────────────────────────────────

test_explicit_union_preserves_order_and_deduplicates() {
  local output
  output="$(_run refs "beta/two,alpha/one,beta/two" 2>/dev/null)"

  local line_two line_one
  line_two="$(echo "${output}" | grep -n "openstack-two" | head -1 | cut -d: -f1)"
  line_one="$(echo "${output}" | grep -n "openstack-one" | head -1 | cut -d: -f1)"
  assert "two before one" test "${line_two}" -lt "${line_one}"

  local count
  count="$(echo "${output}" | wc -l | tr -d ' ')"
  assert "exactly 2 refs (deduplicated)" test "${count}" -eq 2
}

test_single_target_has_no_base() {
  local output
  output="$(_run refs "alpha/one" 2>/dev/null)"

  local count
  count="$(echo "${output}" | wc -l | tr -d ' ')"
  assert "exactly 1 ref" test "${count}" -eq 1
  assert "contains one" echo "${output}" | grep -qF "openstack-one:test"
}

test_resolve_all_returns_machine_readable_targets() {
  local output
  output="$(_run resolve all 2>/dev/null)"

  local found_base found_alpha found_beta
  found_base="$(echo "${output}" | grep -c "^base$" || true)"
  found_alpha="$(echo "${output}" | grep -c "^alpha/one$" || true)"
  found_beta="$(echo "${output}" | grep -c "^beta/two$" || true)"

  assert "contains base"      test "${found_base}" -ge 1
  assert "contains alpha/one" test "${found_alpha}" -ge 1
  assert "contains beta/two"  test "${found_beta}" -ge 1
}

test_refs_rejects_unknown_target() {
  local rc=0
  local stderr
  stderr="$(_run refs "alpha/one,unknown/image" 2>&1 >/dev/null)" || rc=$?

  assert "non-zero exit" test "${rc}" -ne 0
  local has_error
  has_error="$(echo "${stderr}" | grep -c "Unknown image or project" || true)"
  assert "error message present" test "${has_error}" -ge 1
}

test_build_omits_package_cache_by_default() {
  _run build alpha/one >"${TEST_DIR}/build.log" 2>&1

  assert_no_grep 'pip.conf:/etc/pip.conf' "${TEST_DIR}/build.log"
}

test_build_uses_opt_in_package_caches() {
  LOCAL_PACKAGE_CACHE=true \
    LOCAL_PYPI_INDEX_URL=http://cache.test:3141/index/ \
    LOCAL_PYPI_TRUSTED_HOST=cache.test \
    LOCAL_PYPI_HEALTH_URL=http://cache.test:3141/ \
    LOCAL_RPM_PROXY=http://cache.test:3142 \
    LOCAL_RPM_HEALTH_URL=http://cache.test:3142 \
    _run build alpha/one >"${TEST_DIR}/build.log" 2>&1

  assert_grep 'pip.conf:/etc/pip.conf:ro,z' "${TEST_DIR}/build.log"
  assert_grep 'build-arg HTTP_PROXY=http://cache.test:3142' \
    "${TEST_DIR}/build.log"
  assert_no_grep '^HTTP_PROXY=http://cache.test:3142' "${TEST_DIR}/build.log"
  assert_grep 'index-url = http://cache.test:3141/index/' \
    "${TEST_DIR}/.tmp/local-package-cache/pip.conf"
  assert_grep 'trusted-host = cache.test' \
    "${TEST_DIR}/.tmp/local-package-cache/pip.conf"
  assert_grep 'http://cache.test:3141/' "${CURL_LOG}" &&
    assert_grep 'http://cache.test:3142' "${CURL_LOG}"
}

test_build_fails_when_package_cache_is_unavailable() {
  local rc=0
  LOCAL_PACKAGE_CACHE=true FAIL_CACHE_HEALTH=1 \
    _run build alpha/one >"${TEST_DIR}/build.log" 2>&1 || rc=$?

  assert "non-zero exit" test "${rc}" -ne 0
  assert_grep 'cache is unavailable' "${TEST_DIR}/build.log"
  assert_no_grep '^ARGS bud' "${TEST_DIR}/build.log"
}

test_build_uses_supplied_pip_config() {
  local pip_config="${TEST_DIR}/ci-pip.conf"
  printf '[global]\nindex-url = http://mirror.test/pypi/simple\n' \
    > "${pip_config}"

  BUILD_PIP_CONFIG_FILE="${pip_config}" \
    _run build alpha/one >"${TEST_DIR}/build.log" 2>&1

  assert_grep "${pip_config}:/etc/pip.conf:ro,z" "${TEST_DIR}/build.log"
}

test_build_scopes_supplied_proxy_to_run_steps() {
  BUILD_HTTP_PROXY=http://cache.test:3142 \
    BUILD_HTTPS_PROXY=http://cache.test:3142 \
    BUILD_NO_PROXY=mirror.test \
    _run build alpha/one >"${TEST_DIR}/build.log" 2>&1

  assert_grep 'build-arg HTTP_PROXY=http://cache.test:3142' \
    "${TEST_DIR}/build.log"
  assert_grep 'build-arg HTTPS_PROXY=http://cache.test:3142' \
    "${TEST_DIR}/build.log"
  assert_grep 'build-arg NO_PROXY=mirror.test' "${TEST_DIR}/build.log"
  assert_no_grep '^HTTP_PROXY=http://cache.test:3142' "${TEST_DIR}/build.log"
}

test_build_rejects_local_cache_with_pip_config() {
  local rc=0
  local pip_config="${TEST_DIR}/ci-pip.conf"
  printf '[global]\n' > "${pip_config}"

  LOCAL_PACKAGE_CACHE=true BUILD_PIP_CONFIG_FILE="${pip_config}" \
    _run build alpha/one >"${TEST_DIR}/build.log" 2>&1 || rc=$?

  assert "non-zero exit" test "${rc}" -ne 0
  assert_grep 'cannot be combined' "${TEST_DIR}/build.log"
  assert_no_grep '^ARGS bud' "${TEST_DIR}/build.log"
}

test_parallel_build_produces_logs() {
  _run build-parallel "alpha/one,beta/two" >"${TEST_DIR}/build.log" 2>&1 || true

  assert_file_exists "${TEST_DIR}/logs/alpha_one.log"
  assert_file_exists "${TEST_DIR}/logs/beta_two.log"
}

test_parallel_build_shows_live_output() {
  local output
  output="$(_run build-parallel "alpha/one,beta/two" 2>&1 || true)"

  echo "${output}" > "${TEST_DIR}/build.log"
  assert_grep '\[alpha/one\] LIVE alpha/one' "${TEST_DIR}/build.log"
  assert_grep '\[beta/two\] LIVE beta/two'   "${TEST_DIR}/build.log"
}

test_parallel_failure_propagates() {
  local rc=0
  (
    cd "${TEST_DIR}"
    export PATH="${TEST_DIR}/bin:${PATH}"
    export STREAM=master REGISTRY=registry.test:5000 NAMESPACE=openstack
    export TAG=test PARALLEL=2 BUILD_LOGS_DIR="${TEST_DIR}/logs"
    export FAIL_IMAGE=two
    ./build.sh build-parallel "alpha/one,beta/two"
  ) >"${TEST_DIR}/build.log" 2>&1 || rc=$?

  assert "non-zero exit" test "${rc}" -ne 0
  assert_grep "stopping remaining builds" "${TEST_DIR}/build.log"
}

# ── Run all tests ────────────────────────────────────────────────────────

echo "=== build tests ==="
echo ""

TESTS=(
  test_explicit_union_preserves_order_and_deduplicates
  test_single_target_has_no_base
  test_resolve_all_returns_machine_readable_targets
  test_refs_rejects_unknown_target
  test_build_omits_package_cache_by_default
  test_build_uses_opt_in_package_caches
  test_build_fails_when_package_cache_is_unavailable
  test_build_uses_supplied_pip_config
  test_build_scopes_supplied_proxy_to_run_steps
  test_build_rejects_local_cache_with_pip_config
  test_parallel_build_produces_logs
  test_parallel_build_shows_live_output
  test_parallel_failure_propagates
)

for t in "${TESTS[@]}"; do
  run_test "${t}"
done

echo ""
echo "=== ${_PASS} passed, ${_FAIL} failed, 0 skipped ==="

[[ ${_FAIL} -eq 0 ]]
