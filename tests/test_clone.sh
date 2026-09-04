#!/usr/bin/env bash
# Tests for shallow pin clones and parallel unique-source pre-clone.
#
# Uses local bare git remotes and a fake buildah so tests run offline.
# Fake buildah snapshots git state from src/ before build.sh's EXIT trap
# removes auto-cloned trees.
#
# Usage:
#   bash tests/test_clone.sh
#   tox -e test
#
set -uo pipefail

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
  exit 1
}

assert_file_exists() { assert "file exists: $1" test -f "$1"; }
assert_grep()        { assert "grep '$1' in $2" grep -q "$1" "$2"; }
assert_no_grep() {
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
      echo "    --- build.log (last 30 lines) ---"
      tail -30 "${TEST_DIR}/build.log" | sed 's/^/    /'
      echo "    ---"
    fi
  fi

  _teardown_fixture
}

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR=""
UPSTREAM_ALPHA=""
UPSTREAM_BETA=""
ALPHA_HASH_OLD=""
ALPHA_HASH_NEW=""
BETA_HASH_OLD=""

_init_work_repo() {
  local dir="$1"
  git init -b master "${dir}" >/dev/null 2>&1
  git -C "${dir}" config user.email "test@test.com"
  git -C "${dir}" config user.name "Test"
}

_setup_fixture() {
  TEST_DIR="$(mktemp -d)"
  local work

  UPSTREAM_ALPHA="${TEST_DIR}/upstream/alpha.git"
  mkdir -p "${TEST_DIR}/upstream"
  work="$(mktemp -d)"
  _init_work_repo "${work}"
  echo "alpha-v1" > "${work}/requirements.txt"
  git -C "${work}" add -A >/dev/null && git -C "${work}" commit -m "v1" >/dev/null 2>&1
  echo "alpha-v2" > "${work}/requirements.txt"
  git -C "${work}" add -A >/dev/null && git -C "${work}" commit -m "v2" >/dev/null 2>&1
  git clone --bare "${work}" "${UPSTREAM_ALPHA}" >/dev/null 2>&1
  rm -rf "${work}"
  ALPHA_HASH_OLD="$(git -C "${UPSTREAM_ALPHA}" rev-parse master~1)"
  ALPHA_HASH_NEW="$(git -C "${UPSTREAM_ALPHA}" rev-parse master)"

  UPSTREAM_BETA="${TEST_DIR}/upstream/beta.git"
  work="$(mktemp -d)"
  _init_work_repo "${work}"
  echo "beta-v1" > "${work}/requirements.txt"
  git -C "${work}" add -A >/dev/null && git -C "${work}" commit -m "v1" >/dev/null 2>&1
  echo "beta-v2" > "${work}/requirements.txt"
  git -C "${work}" add -A >/dev/null && git -C "${work}" commit -m "v2" >/dev/null 2>&1
  git clone --bare "${work}" "${UPSTREAM_BETA}" >/dev/null 2>&1
  rm -rf "${work}"
  BETA_HASH_OLD="$(git -C "${UPSTREAM_BETA}" rev-parse master~1)"

  ln -s "${SCRIPT_DIR}/build.sh" "${TEST_DIR}/build.sh"

  mkdir -p "${TEST_DIR}/containers/base"
  echo "FROM scratch" > "${TEST_DIR}/containers/base/Containerfile"
  touch "${TEST_DIR}/containers/base/requirements.lock.master"

  mkdir -p "${TEST_DIR}/containers/alpha/src"
  mkdir -p "${TEST_DIR}/containers/alpha/one"
  mkdir -p "${TEST_DIR}/containers/alpha/two"
  cat > "${TEST_DIR}/containers/alpha/sources.txt" <<EOF
master alpha ${UPSTREAM_ALPHA} master ${ALPHA_HASH_OLD}
EOF
  echo "FROM scratch" > "${TEST_DIR}/containers/alpha/one/Containerfile"
  echo "FROM scratch" > "${TEST_DIR}/containers/alpha/two/Containerfile"
  touch "${TEST_DIR}/containers/alpha/requirements.lock.master"

  mkdir -p "${TEST_DIR}/containers/beta/src"
  mkdir -p "${TEST_DIR}/containers/beta/one"
  cat > "${TEST_DIR}/containers/beta/sources.txt" <<EOF
master beta ${UPSTREAM_BETA} master ${BETA_HASH_OLD}
EOF
  echo "FROM scratch" > "${TEST_DIR}/containers/beta/one/Containerfile"
  touch "${TEST_DIR}/containers/beta/requirements.lock.master"

  mkdir -p "${TEST_DIR}/bin"
  cat > "${TEST_DIR}/bin/buildah" <<'FAKE_BUILDAH'
#!/usr/bin/env bash
set -eu
case "$1" in
  bud)
    stats="${CLONE_STATS:-}"
    if [[ -n "${stats}" ]]; then
      find containers -type d -path '*/src/*' 2>/dev/null | sort | while read -r repo; do
        [[ "$(basename "$(dirname "${repo}")")" == "src" ]] || continue
        name="$(basename "${repo}")"
        if [[ -d "${repo}/.git" ]] && git -C "${repo}" rev-parse HEAD >/dev/null 2>&1; then
          echo "${name} $(git -C "${repo}" rev-parse HEAD) $(git -C "${repo}" rev-list --count --all)" >> "${stats}"
        fi
        if [[ -f "${repo}/MARKER" ]]; then
          echo "MARKER ${name}" >> "${stats}"
        fi
        if [[ -f "${repo}/requirements.txt" ]]; then
          echo "REQ ${name} $(cat "${repo}/requirements.txt")" >> "${stats}"
        fi
      done
    fi
    exit 0
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
    export PARALLEL="${PARALLEL:-2}"
    export CLONE_STATS="${TEST_DIR}/clone-stats"
    export GIT_CONFIG_NOSYSTEM=1
    unset FULL_CLONE
    ./build.sh "${action}" "$@"
  )
}

test_shallow_pin_checks_out_recorded_hash() {
  _run build "alpha/one" >"${TEST_DIR}/build.log" 2>&1

  assert_file_exists "${TEST_DIR}/clone-stats"
  assert_grep "^alpha ${ALPHA_HASH_OLD} 1$" "${TEST_DIR}/clone-stats"
  assert_grep "REQ alpha alpha-v1" "${TEST_DIR}/clone-stats"
  assert_grep "Cloning ${UPSTREAM_ALPHA} at ${ALPHA_HASH_OLD}" "${TEST_DIR}/build.log"
}

test_full_clone_keeps_history() {
  (
    cd "${TEST_DIR}"
    export PATH="${TEST_DIR}/bin:${PATH}"
    export STREAM=master REGISTRY=registry.test:5000 NAMESPACE=openstack
    export TAG=test PARALLEL=1 CLONE_STATS="${TEST_DIR}/clone-stats"
    export GIT_CONFIG_NOSYSTEM=1
    export FULL_CLONE=1
    ./build.sh build "alpha/one"
  ) >"${TEST_DIR}/build.log" 2>&1

  assert_grep "^alpha ${ALPHA_HASH_OLD} 2$" "${TEST_DIR}/clone-stats"
  assert_no_grep "Shallow fetch failed" "${TEST_DIR}/build.log"
}

test_existing_dest_is_left_in_place() {
  mkdir -p "${TEST_DIR}/containers/alpha/src/alpha"
  echo "local-work" > "${TEST_DIR}/containers/alpha/src/alpha/MARKER"
  echo "local-req" > "${TEST_DIR}/containers/alpha/src/alpha/requirements.txt"

  _run build "alpha/one" >"${TEST_DIR}/build.log" 2>&1

  assert_grep "MARKER alpha" "${TEST_DIR}/clone-stats"
  assert_grep "REQ alpha local-req" "${TEST_DIR}/clone-stats"
  assert_no_grep "Cloning ${UPSTREAM_ALPHA}" "${TEST_DIR}/build.log"
}

test_shared_project_dest_cloned_once() {
  _run build-parallel "alpha/one,alpha/two" >"${TEST_DIR}/build.log" 2>&1

  local clone_lines
  clone_lines="$(grep -c "Cloning ${UPSTREAM_ALPHA} at ${ALPHA_HASH_OLD}" "${TEST_DIR}/build.log" || true)"
  assert "alpha cloned once" test "${clone_lines}" -eq 1
  assert_grep "unique sources" "${TEST_DIR}/build.log"
}

test_parallel_preclone_two_projects() {
  _run build-parallel "alpha/one,beta/one" >"${TEST_DIR}/build.log" 2>&1

  assert_grep "^alpha ${ALPHA_HASH_OLD} 1$" "${TEST_DIR}/clone-stats"
  assert_grep "^beta ${BETA_HASH_OLD} 1$" "${TEST_DIR}/clone-stats"
  assert_grep "Cloning 2 unique sources" "${TEST_DIR}/build.log"
}

test_six_field_sources_still_clones_at_hash() {
  cat > "${TEST_DIR}/containers/alpha/sources.txt" <<EOF
master alpha ${UPSTREAM_ALPHA} master ${ALPHA_HASH_OLD} 16.1.0.dev1
EOF

  _run build "alpha/one" >"${TEST_DIR}/build.log" 2>&1

  assert_grep "^alpha ${ALPHA_HASH_OLD} 1$" "${TEST_DIR}/clone-stats"
  assert_grep "REQ alpha alpha-v1" "${TEST_DIR}/clone-stats"
}

# ── Run all tests ────────────────────────────────────────────────────────

echo "=== clone tests ==="
echo ""

TESTS=(
  test_shallow_pin_checks_out_recorded_hash
  test_full_clone_keeps_history
  test_existing_dest_is_left_in_place
  test_shared_project_dest_cloned_once
  test_parallel_preclone_two_projects
  test_six_field_sources_still_clones_at_hash
)

for t in "${TESTS[@]}"; do
  run_test "${t}"
done

echo ""
echo "=== ${_PASS} passed, ${_FAIL} failed, 0 skipped ==="

[[ ${_FAIL} -eq 0 ]]
