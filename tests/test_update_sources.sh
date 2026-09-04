#!/usr/bin/env bash
# Tests for build.sh update-sources functionality.
#
# Uses local bare git repos as fake remotes so tests run offline and fast.
# pip-compile and pybuild-deps must be on PATH for lockfile tests.
#
# Usage:
#   PATH=".tox/update-sources/bin:$PATH" bash tests/test_update_sources.sh
#   tox -e test
#
set -uo pipefail

# ── Test runner ──────────────────────────────────────────────────────────

_PASS=0
_FAIL=0
_SKIP=0

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
assert_symlink()     { assert "symlink exists: $1" test -L "$1"; }
assert_no_symlink()  { assert "no symlink: $1" test ! -L "$1"; }
assert_grep()        { assert "grep '$1' in $2" grep -q "$1" "$2"; }
assert_no_grep() {
  if grep -q "$1" "$2" 2>/dev/null; then
    echo "    ASSERTION FAILED: '$1' should not appear in $2"
    return 1
  fi
}

assert_link_target() {
  local link="$1" expected="$2"
  local actual
  actual="$(readlink "$1")"
  assert "symlink $1 -> $2 (actual: ${actual})" test "${actual}" = "${expected}"
}

assert_field() {
  local file="$1" stream="$2" name="$3" field="$4" expected="$5"
  local actual
  actual=$(awk -v s="${stream}" -v n="${name}" '$1==s && $2==n {print $'${field}'}' "${file}")
  assert "sources.txt ${name} field ${field} == ${expected} (actual: ${actual})" \
    test "${actual}" = "${expected}"
}

run_test() {
  local name="$1"

  _setup_fixture

  local rc=0
  # Run in subshell with set -e so first failed assertion stops the test
  ( set -e; "${name}" ) || rc=$?

  if [[ ${rc} -eq 0 ]]; then
    echo "  PASS  ${name}"
    ((_PASS++))
  elif [[ ${rc} -eq 99 ]]; then
    echo "  SKIP  ${name}"
    ((_SKIP++))
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

skip_test() {
  echo "    skipping: $1"
  return 99
}

# ── Fixture ──────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR=""
UPSTREAM_REQ=""
UPSTREAM_SVC=""
UPSTREAM_SVC2=""
UPSTREAM_SVC3=""
REQ_HASH_OLD=""
REQ_HASH_NEW=""
SVC_HASH_OLD=""
SVC_HASH_NEW=""
SVC2_HASH_OLD=""
SVC2_HASH_NEW=""
SVC3_HASH_OLD=""
SVC3_HASH_NEW=""

_init_work_repo() {
  local dir="$1"
  git init -b master "${dir}" >/dev/null 2>&1
  git -C "${dir}" config user.email "test@test.com"
  git -C "${dir}" config user.name "Test"
}

_setup_fixture() {
  TEST_DIR="$(mktemp -d)"
  local work

  # ── Upstream requirements repo (2 commits) ──
  UPSTREAM_REQ="${TEST_DIR}/upstream/requirements.git"
  mkdir -p "${TEST_DIR}/upstream"
  work="$(mktemp -d)"
  _init_work_repo "${work}"

  echo "six==1.17.0" > "${work}/upper-constraints.txt"
  git -C "${work}" add -A >/dev/null && git -C "${work}" commit -m "v1" >/dev/null 2>&1

  printf 'six==1.17.0\npbr==7.0.3\n' > "${work}/upper-constraints.txt"
  git -C "${work}" add -A >/dev/null && git -C "${work}" commit -m "v2" >/dev/null 2>&1

  git clone --bare "${work}" "${UPSTREAM_REQ}" >/dev/null 2>&1
  rm -rf "${work}"

  REQ_HASH_OLD="$(git -C "${UPSTREAM_REQ}" rev-parse master~1)"
  REQ_HASH_NEW="$(git -C "${UPSTREAM_REQ}" rev-parse master)"

  # ── Upstream PBR service repo (2 commits) ──
  UPSTREAM_SVC="${TEST_DIR}/upstream/test-svc.git"
  work="$(mktemp -d)"
  _init_work_repo "${work}"

  echo "six" > "${work}/requirements.txt"
  cat > "${work}/pyproject.toml" <<'TOML'
[build-system]
requires = ["pbr>=6.0.0"]
build-backend = "pbr.build"
TOML
  cat > "${work}/setup.cfg" <<'CFG'
[metadata]
name = test-svc
summary = Test service
CFG
  git -C "${work}" add -A >/dev/null && git -C "${work}" commit -m "v1" >/dev/null 2>&1
  git -C "${work}" tag 1.0.0

  printf 'six\npbr\n' > "${work}/requirements.txt"
  git -C "${work}" add -A >/dev/null && git -C "${work}" commit -m "v2" >/dev/null 2>&1

  git clone --bare "${work}" "${UPSTREAM_SVC}" >/dev/null 2>&1
  rm -rf "${work}"

  SVC_HASH_OLD="$(git -C "${UPSTREAM_SVC}" rev-parse master~1)"
  SVC_HASH_NEW="$(git -C "${UPSTREAM_SVC}" rev-parse master)"

  # ── Upstream service 2 repo (2 commits) ──
  UPSTREAM_SVC2="${TEST_DIR}/upstream/test-svc2.git"
  work="$(mktemp -d)"
  _init_work_repo "${work}"

  echo "six" > "${work}/requirements.txt"
  git -C "${work}" add -A >/dev/null && git -C "${work}" commit -m "v1" >/dev/null 2>&1

  printf 'six\npbr\n' > "${work}/requirements.txt"
  git -C "${work}" add -A >/dev/null && git -C "${work}" commit -m "v2" >/dev/null 2>&1

  git clone --bare "${work}" "${UPSTREAM_SVC2}" >/dev/null 2>&1
  rm -rf "${work}"

  SVC2_HASH_OLD="$(git -C "${UPSTREAM_SVC2}" rev-parse master~1)"
  SVC2_HASH_NEW="$(git -C "${UPSTREAM_SVC2}" rev-parse master)"

  # ── Upstream service 3 repo (2 commits) ──
  UPSTREAM_SVC3="${TEST_DIR}/upstream/test-svc3.git"
  work="$(mktemp -d)"
  _init_work_repo "${work}"

  echo "six" > "${work}/requirements.txt"
  git -C "${work}" add -A >/dev/null && git -C "${work}" commit -m "v1" >/dev/null 2>&1

  printf 'six\npbr\n' > "${work}/requirements.txt"
  git -C "${work}" add -A >/dev/null && git -C "${work}" commit -m "v2" >/dev/null 2>&1

  git clone --bare "${work}" "${UPSTREAM_SVC3}" >/dev/null 2>&1
  rm -rf "${work}"

  SVC3_HASH_OLD="$(git -C "${UPSTREAM_SVC3}" rev-parse master~1)"
  SVC3_HASH_NEW="$(git -C "${UPSTREAM_SVC3}" rev-parse master)"

  # ── Symlink build.sh and its source-version helper ──
  ln -s "${SCRIPT_DIR}/build.sh" "${TEST_DIR}/build.sh"
  mkdir -p "${TEST_DIR}/tools"
  ln -s "${SCRIPT_DIR}/tools/source_version.py" \
    "${TEST_DIR}/tools/source_version.py"

  # ── Containers tree ──
  mkdir -p "${TEST_DIR}/containers/test-svc/src"
  mkdir -p "${TEST_DIR}/containers/test-svc/test-svc/src"

  cat > "${TEST_DIR}/containers/test-svc/sources.txt" <<EOF
master upper-constraints ${UPSTREAM_REQ} master ${REQ_HASH_OLD}
master test-svc ${UPSTREAM_SVC} master ${SVC_HASH_OLD}
EOF

  echo "FROM scratch" > "${TEST_DIR}/containers/test-svc/test-svc/Containerfile"
  echo "python3"      > "${TEST_DIR}/containers/test-svc/test-svc/bindeps.txt"
  echo "gcc"          > "${TEST_DIR}/containers/test-svc/test-svc/builddeps.txt"
  touch                 "${TEST_DIR}/containers/test-svc/test-svc/pythondeps.txt"
  touch                 "${TEST_DIR}/containers/test-svc/test-svc/pythonbuilddeps.txt"

  # ── Second project containers tree ──
  mkdir -p "${TEST_DIR}/containers/test-svc2/src"
  mkdir -p "${TEST_DIR}/containers/test-svc2/test-svc2/src"

  cat > "${TEST_DIR}/containers/test-svc2/sources.txt" <<EOF
master upper-constraints ${UPSTREAM_REQ} master ${REQ_HASH_OLD}
master test-svc2 ${UPSTREAM_SVC2} master ${SVC2_HASH_OLD}
EOF

  echo "FROM scratch" > "${TEST_DIR}/containers/test-svc2/test-svc2/Containerfile"
  echo "python3"      > "${TEST_DIR}/containers/test-svc2/test-svc2/bindeps.txt"
  echo "gcc"          > "${TEST_DIR}/containers/test-svc2/test-svc2/builddeps.txt"
  touch                 "${TEST_DIR}/containers/test-svc2/test-svc2/pythondeps.txt"
  touch                 "${TEST_DIR}/containers/test-svc2/test-svc2/pythonbuilddeps.txt"

  # ── Third project containers tree ──
  mkdir -p "${TEST_DIR}/containers/test-svc3/src"
  mkdir -p "${TEST_DIR}/containers/test-svc3/test-svc3/src"

  cat > "${TEST_DIR}/containers/test-svc3/sources.txt" <<EOF
master upper-constraints ${UPSTREAM_REQ} master ${REQ_HASH_OLD}
master test-svc3 ${UPSTREAM_SVC3} master ${SVC3_HASH_OLD}
EOF

  echo "FROM scratch" > "${TEST_DIR}/containers/test-svc3/test-svc3/Containerfile"
  echo "python3"      > "${TEST_DIR}/containers/test-svc3/test-svc3/bindeps.txt"
  echo "gcc"          > "${TEST_DIR}/containers/test-svc3/test-svc3/builddeps.txt"
  touch                 "${TEST_DIR}/containers/test-svc3/test-svc3/pythondeps.txt"
  touch                 "${TEST_DIR}/containers/test-svc3/test-svc3/pythonbuilddeps.txt"

  # ── Pure RPM project (no sources.txt) ──
  mkdir -p "${TEST_DIR}/containers/test-rpmsvc/test-rpmsvc"

  echo "FROM scratch"   > "${TEST_DIR}/containers/test-rpmsvc/test-rpmsvc/Containerfile"
  echo "httpd"          > "${TEST_DIR}/containers/test-rpmsvc/test-rpmsvc/bindeps.txt"
  echo "gcc-c++"        > "${TEST_DIR}/containers/test-rpmsvc/test-rpmsvc/builddeps.txt"
}

_teardown_fixture() {
  [[ -n "${TEST_DIR}" ]] && rm -rf "${TEST_DIR}"
}

# Helper: run build.sh inside TEST_DIR with env vars passed as arguments.
# Usage: _run_build STREAM=master [SKIP_HASH_UPDATE=1 ...]
_run_build() {
  (cd "${TEST_DIR}" && env "$@" ./build.sh update-sources test-svc) >"${TEST_DIR}/build.log" 2>&1
}

# Helper: run build.sh with arbitrary action and targets.
# Usage: _run_cmd <env_var=val ...> -- <action> [targets...]
_run_cmd() {
  local env_args=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    env_args+=("$1")
    shift
  done
  [[ "$1" == "--" ]] && shift
  (cd "${TEST_DIR}" && env "${env_args[@]}" ./build.sh "$@") >"${TEST_DIR}/build.log" 2>&1
}

# ── Tests ────────────────────────────────────────────────────────────────

test_updates_hashes_to_branch_tip() {
  _run_build STREAM=master

  local src="${TEST_DIR}/containers/test-svc/sources.txt"
  assert_field "${src}" master upper-constraints 5 "${REQ_HASH_NEW}"
  assert_field "${src}" master upper-constraints 6 "-"
  assert_field "${src}" master test-svc 5 "${SVC_HASH_NEW}"
  assert_field "${src}" master test-svc 6 "1.0.1.dev1"
}

test_skip_hash_update_records_pinned_version() {
  _run_build STREAM=master SKIP_HASH_UPDATE=1

  local src="${TEST_DIR}/containers/test-svc/sources.txt"
  assert_field "${src}" master test-svc 5 "${SVC_HASH_OLD}"
  assert_field "${src}" master test-svc 6 "1.0.0"
}

test_version_failure_leaves_sources_unchanged() {
  local src="${TEST_DIR}/containers/test-svc/sources.txt"
  local before
  before=$(cat "${src}")
  local fake_bin="${TEST_DIR}/fake-bin"
  local real_python
  real_python=$(command -v python3)
  mkdir -p "${fake_bin}"
  cat > "${fake_bin}/python3" <<EOF
#!/usr/bin/env bash
if [[ "\${3:-}" == "test-svc" ]]; then
  exit 42
fi
exec "${real_python}" "\$@"
EOF
  chmod +x "${fake_bin}/python3"

  if _run_build STREAM=master PATH="${fake_bin}:${PATH}"; then
    echo "    ASSERTION FAILED: expected version calculation failure"
    return 1
  fi
  assert "sources.txt unchanged" test "$(cat "${src}")" = "${before}"
}

test_fetches_upper_constraints() {
  _run_build STREAM=master

  local uc="${TEST_DIR}/containers/test-svc/upper-constraints.txt.master"
  assert_file_exists "${uc}"
  assert_grep "six==1.17.0" "${uc}"
  assert_grep "pbr==7.0.3" "${uc}"
}

test_generates_rpms_in_yaml() {
  _run_build STREAM=master

  local rpms="${TEST_DIR}/containers/test-svc/rpms.in.yaml"
  assert_file_exists "${rpms}"
  assert_grep "python3" "${rpms}"
  assert_grep "gcc" "${rpms}"
}

test_generates_requirements_lock() {
  command -v pip-compile >/dev/null 2>&1 || skip_test "pip-compile not on PATH"

  _run_build STREAM=master

  local lock="${TEST_DIR}/containers/test-svc/requirements.lock.master"
  assert_file_exists "${lock}"
  assert_grep "six" "${lock}"
}

test_generates_buildrequirements_lock() {
  command -v pip-compile >/dev/null 2>&1 || skip_test "pip-compile not on PATH"
  command -v pybuild-deps >/dev/null 2>&1 || skip_test "pybuild-deps not on PATH"

  _run_build STREAM=master

  assert_file_exists "${TEST_DIR}/containers/test-svc/buildrequirements.lock.master"
}

test_creates_default_stream_symlinks() {
  command -v pip-compile >/dev/null 2>&1 || skip_test "pip-compile not on PATH"
  command -v pybuild-deps >/dev/null 2>&1 || skip_test "pybuild-deps not on PATH"

  _run_build STREAM=master DEFAULT_STREAM=master

  local d="${TEST_DIR}/containers/test-svc"
  assert_symlink "${d}/upper-constraints.txt"
  assert_symlink "${d}/requirements.lock"
  assert_symlink "${d}/buildrequirements.lock"
  assert_link_target "${d}/requirements.lock" "requirements.lock.master"
  assert_link_target "${d}/buildrequirements.lock" "buildrequirements.lock.master"
  assert_link_target "${d}/upper-constraints.txt" "upper-constraints.txt.master"
}

test_skips_symlinks_for_non_default_stream() {
  command -v pip-compile >/dev/null 2>&1 || skip_test "pip-compile not on PATH"
  command -v pybuild-deps >/dev/null 2>&1 || skip_test "pybuild-deps not on PATH"

  _run_build STREAM=master DEFAULT_STREAM=other

  local d="${TEST_DIR}/containers/test-svc"
  assert_no_symlink "${d}/requirements.lock"
  assert_no_symlink "${d}/buildrequirements.lock"
  assert_no_symlink "${d}/upper-constraints.txt"
}

test_skip_hash_update_preserves_hashes() {
  command -v pip-compile >/dev/null 2>&1 || skip_test "pip-compile not on PATH"

  _run_build STREAM=master SKIP_HASH_UPDATE=1

  local src="${TEST_DIR}/containers/test-svc/sources.txt"
  assert_field "${src}" master upper-constraints 5 "${REQ_HASH_OLD}"
  assert_field "${src}" master test-svc 5 "${SVC_HASH_OLD}"

  assert_file_exists "${TEST_DIR}/containers/test-svc/requirements.lock.master"
}

test_skip_hash_update_fetches_constraints_at_pinned_hash() {
  _run_build STREAM=master SKIP_HASH_UPDATE=1

  local uc="${TEST_DIR}/containers/test-svc/upper-constraints.txt.master"
  assert_file_exists "${uc}"
  assert_grep "six==1.17.0" "${uc}"
  assert_no_grep "pbr" "${uc}"
}

test_hash_in_branch_field_upper_constraints() {
  cat > "${TEST_DIR}/containers/test-svc/sources.txt" <<EOF
master upper-constraints ${UPSTREAM_REQ} ${REQ_HASH_OLD} ${REQ_HASH_NEW}
master test-svc ${UPSTREAM_SVC} master ${SVC_HASH_OLD}
EOF

  _run_build STREAM=master

  assert_field "${TEST_DIR}/containers/test-svc/sources.txt" master upper-constraints 5 "${REQ_HASH_OLD}"

  local uc="${TEST_DIR}/containers/test-svc/upper-constraints.txt.master"
  assert_file_exists "${uc}"
  assert_grep "six==1.17.0" "${uc}"
  assert_no_grep "pbr" "${uc}"
}

test_hash_in_branch_field_regular_repo() {
  command -v pip-compile >/dev/null 2>&1 || skip_test "pip-compile not on PATH"

  cat > "${TEST_DIR}/containers/test-svc/sources.txt" <<EOF
master upper-constraints ${UPSTREAM_REQ} master ${REQ_HASH_OLD}
master test-svc ${UPSTREAM_SVC} ${SVC_HASH_OLD} ${SVC_HASH_NEW}
EOF

  _run_build STREAM=master

  assert_field "${TEST_DIR}/containers/test-svc/sources.txt" master test-svc 5 "${SVC_HASH_OLD}"
  assert_file_exists "${TEST_DIR}/containers/test-svc/requirements.lock.master"
}

test_lockfile_excludes_rpm_python_packages() {
  command -v pip-compile >/dev/null 2>&1 || skip_test "pip-compile not on PATH"

  printf 'python3\npython3-six\n' > "${TEST_DIR}/containers/test-svc/test-svc/bindeps.txt"

  _run_build STREAM=master

  local lock="${TEST_DIR}/containers/test-svc/requirements.lock.master"
  assert_file_exists "${lock}"
  assert_no_grep "^six==" "${lock}"
  assert_grep "Filtering RPM-provided packages" "${TEST_DIR}/build.log"
}

test_lockfile_excludes_rpm_python_packages_nvr() {
  command -v pip-compile >/dev/null 2>&1 || skip_test "pip-compile not on PATH"

  printf 'python3\npython3-six-1.17.0-1.el10\n' > "${TEST_DIR}/containers/test-svc/test-svc/bindeps.txt"

  _run_build STREAM=master

  local lock="${TEST_DIR}/containers/test-svc/requirements.lock.master"
  assert_file_exists "${lock}"
  assert_no_grep "^six==" "${lock}"
  assert_grep "Filtering RPM-provided packages" "${TEST_DIR}/build.log"
}

test_preexisting_checkout_is_preserved() {
  local src_dir="${TEST_DIR}/containers/test-svc/src/test-svc"
  mkdir -p "${src_dir}"
  echo "local-dev" > "${src_dir}/MARKER"
  echo "six" > "${src_dir}/requirements.txt"

  _run_build STREAM=master

  assert_file_exists "${src_dir}/MARKER"
  assert_grep "local-dev" "${src_dir}/MARKER"
  assert_field "${TEST_DIR}/containers/test-svc/sources.txt" master test-svc 5 "${SVC_HASH_OLD}"
}

# ── Multi-target tests ──────────────────────────────────────────────────

test_list_discovers_all_projects() {
  _run_cmd STREAM=master -- list
  assert_grep "test-svc/test-svc" "${TEST_DIR}/build.log"
  assert_grep "test-svc2/test-svc2" "${TEST_DIR}/build.log"
}

test_update_sources_multiple_targets() {
  _run_cmd STREAM=master -- update-sources test-svc test-svc2

  local src1="${TEST_DIR}/containers/test-svc/sources.txt"
  local src2="${TEST_DIR}/containers/test-svc2/sources.txt"
  local src3="${TEST_DIR}/containers/test-svc3/sources.txt"
  assert_field "${src1}" master test-svc 5 "${SVC_HASH_NEW}"
  assert_field "${src2}" master test-svc2 5 "${SVC2_HASH_NEW}"
  assert_field "${src3}" master test-svc3 5 "${SVC3_HASH_OLD}"
}

test_update_sources_multiple_targets_fetches_constraints() {
  _run_cmd STREAM=master -- update-sources test-svc test-svc2

  assert_file_exists "${TEST_DIR}/containers/test-svc/upper-constraints.txt.master"
  assert_file_exists "${TEST_DIR}/containers/test-svc2/upper-constraints.txt.master"
  assert "no constraints for test-svc3" test ! -f "${TEST_DIR}/containers/test-svc3/upper-constraints.txt.master"
}

test_update_sources_multiple_targets_generates_lockfiles() {
  command -v pip-compile >/dev/null 2>&1 || skip_test "pip-compile not on PATH"

  _run_cmd STREAM=master -- update-sources test-svc test-svc2

  assert_file_exists "${TEST_DIR}/containers/test-svc/requirements.lock.master"
  assert_file_exists "${TEST_DIR}/containers/test-svc2/requirements.lock.master"
  assert "no lockfile for test-svc3" test ! -f "${TEST_DIR}/containers/test-svc3/requirements.lock.master"
}

test_update_sources_multiple_targets_generates_rpms_in() {
  _run_cmd STREAM=master -- update-sources test-svc test-svc2

  assert_file_exists "${TEST_DIR}/containers/test-svc/rpms.in.yaml"
  assert_file_exists "${TEST_DIR}/containers/test-svc2/rpms.in.yaml"
  assert "no rpms.in.yaml for test-svc3" test ! -f "${TEST_DIR}/containers/test-svc3/rpms.in.yaml"
}

test_update_sources_single_target_does_not_affect_other() {
  _run_cmd STREAM=master -- update-sources test-svc

  local src2="${TEST_DIR}/containers/test-svc2/sources.txt"
  assert_field "${src2}" master test-svc2 5 "${SVC2_HASH_OLD}"
}

test_update_sources_all_updates_everything() {
  _run_cmd STREAM=master -- update-sources all

  local src1="${TEST_DIR}/containers/test-svc/sources.txt"
  local src2="${TEST_DIR}/containers/test-svc2/sources.txt"
  local src3="${TEST_DIR}/containers/test-svc3/sources.txt"
  assert_field "${src1}" master test-svc 5 "${SVC_HASH_NEW}"
  assert_field "${src2}" master test-svc2 5 "${SVC2_HASH_NEW}"
  assert_field "${src3}" master test-svc3 5 "${SVC3_HASH_NEW}"
}

test_update_sources_unknown_target_fails() {
  if _run_cmd STREAM=master -- update-sources nonexistent 2>/dev/null; then
    echo "    ASSERTION FAILED: expected failure for unknown target"
    return 1
  fi
  assert_grep "ERROR: Unknown image or project" "${TEST_DIR}/build.log"
}

test_update_sources_multiple_targets_symlinks() {
  command -v pip-compile >/dev/null 2>&1 || skip_test "pip-compile not on PATH"
  command -v pybuild-deps >/dev/null 2>&1 || skip_test "pybuild-deps not on PATH"

  _run_cmd STREAM=master DEFAULT_STREAM=master -- update-sources test-svc test-svc2

  for proj in test-svc test-svc2; do
    local d="${TEST_DIR}/containers/${proj}"
    assert_symlink "${d}/requirements.lock"
    assert_link_target "${d}/requirements.lock" "requirements.lock.master"
  done
}

# ── update-lockfiles tests ──────────────────────────────────────────────

test_update_lockfiles_regenerates_lockfile() {
  command -v pip-compile >/dev/null 2>&1 || skip_test "pip-compile not on PATH"

  _run_build STREAM=master
  local lock="${TEST_DIR}/containers/test-svc/requirements.lock.master"
  assert_file_exists "${lock}"
  local before
  before=$(cat "${lock}")

  _run_cmd STREAM=master -- update-lockfiles test-svc
  assert_file_exists "${lock}"
}

test_update_lockfiles_fails_without_constraints() {
  command -v pip-compile >/dev/null 2>&1 || skip_test "pip-compile not on PATH"

  if _run_cmd STREAM=master -- update-lockfiles test-svc 2>/dev/null; then
    echo "    ASSERTION FAILED: expected failure without constraints"
    return 1
  fi
  assert_grep "Run 'update-sources' first" "${TEST_DIR}/build.log"
}

test_update_lockfiles_fails_without_lockfile() {
  command -v pip-compile >/dev/null 2>&1 || skip_test "pip-compile not on PATH"

  # Create constraints but not the lockfile
  _run_build STREAM=master
  rm "${TEST_DIR}/containers/test-svc/requirements.lock.master"

  if _run_cmd STREAM=master -- update-lockfiles test-svc 2>/dev/null; then
    echo "    ASSERTION FAILED: expected failure without lockfile"
    return 1
  fi
  assert_grep "Run 'update-sources' first" "${TEST_DIR}/build.log"
}

test_update_lockfiles_includes_pythondeps() {
  command -v pip-compile >/dev/null 2>&1 || skip_test "pip-compile not on PATH"

  _run_build STREAM=master

  echo "pbr" > "${TEST_DIR}/containers/test-svc/test-svc/pythondeps.txt"

  _run_cmd STREAM=master -- update-lockfiles test-svc

  local lock="${TEST_DIR}/containers/test-svc/requirements.lock.master"
  assert_file_exists "${lock}"
  assert_grep "pbr" "${lock}"
}

test_update_lockfiles_generates_buildrequirements() {
  command -v pip-compile >/dev/null 2>&1 || skip_test "pip-compile not on PATH"
  command -v pybuild-deps >/dev/null 2>&1 || skip_test "pybuild-deps not on PATH"

  _run_build STREAM=master

  rm "${TEST_DIR}/containers/test-svc/buildrequirements.lock.master"

  _run_cmd STREAM=master -- update-lockfiles test-svc

  assert_file_exists "${TEST_DIR}/containers/test-svc/buildrequirements.lock.master"
}

test_update_lockfiles_filters_rpm_packages() {
  command -v pip-compile >/dev/null 2>&1 || skip_test "pip-compile not on PATH"

  _run_build STREAM=master

  printf 'python3\npython3-six\n' > "${TEST_DIR}/containers/test-svc/test-svc/bindeps.txt"

  _run_cmd STREAM=master -- update-lockfiles test-svc

  local lock="${TEST_DIR}/containers/test-svc/requirements.lock.master"
  assert_file_exists "${lock}"
  assert_no_grep "^six==" "${lock}"
}

test_update_lockfiles_filters_rpm_packages_nvr() {
  command -v pip-compile >/dev/null 2>&1 || skip_test "pip-compile not on PATH"

  _run_build STREAM=master

  printf 'python3\npython3-six-1.17.0-1.el10\n' > "${TEST_DIR}/containers/test-svc/test-svc/bindeps.txt"

  _run_cmd STREAM=master -- update-lockfiles test-svc

  local lock="${TEST_DIR}/containers/test-svc/requirements.lock.master"
  assert_file_exists "${lock}"
  assert_no_grep "^six==" "${lock}"
}

test_update_lockfiles_does_not_modify_sources() {
  command -v pip-compile >/dev/null 2>&1 || skip_test "pip-compile not on PATH"

  _run_build STREAM=master

  local src="${TEST_DIR}/containers/test-svc/sources.txt"
  local before
  before=$(cat "${src}")

  _run_cmd STREAM=master -- update-lockfiles test-svc

  local after
  after=$(cat "${src}")
  assert "sources.txt unchanged" test "${before}" = "${after}"
}

test_update_lockfiles_multiple_targets() {
  command -v pip-compile >/dev/null 2>&1 || skip_test "pip-compile not on PATH"

  _run_cmd STREAM=master -- update-sources test-svc test-svc2

  rm "${TEST_DIR}/containers/test-svc/rpms.in.yaml"
  rm "${TEST_DIR}/containers/test-svc2/rpms.in.yaml"

  _run_cmd STREAM=master -- update-lockfiles test-svc test-svc2

  assert_file_exists "${TEST_DIR}/containers/test-svc/rpms.in.yaml"
  assert_file_exists "${TEST_DIR}/containers/test-svc2/rpms.in.yaml"
  assert "no rpms.in.yaml for test-svc3" test ! -f "${TEST_DIR}/containers/test-svc3/rpms.in.yaml"
}

test_update_lockfiles_creates_symlinks() {
  command -v pip-compile >/dev/null 2>&1 || skip_test "pip-compile not on PATH"
  command -v pybuild-deps >/dev/null 2>&1 || skip_test "pybuild-deps not on PATH"

  _run_build STREAM=master DEFAULT_STREAM=master

  local d="${TEST_DIR}/containers/test-svc"
  rm -f "${d}/requirements.lock" "${d}/buildrequirements.lock"

  _run_cmd STREAM=master DEFAULT_STREAM=master -- update-lockfiles test-svc

  assert_symlink "${d}/requirements.lock"
  assert_link_target "${d}/requirements.lock" "requirements.lock.master"
  assert_symlink "${d}/buildrequirements.lock"
  assert_link_target "${d}/buildrequirements.lock" "buildrequirements.lock.master"
}

test_update_lockfiles_generates_rpms_in() {
  command -v pip-compile >/dev/null 2>&1 || skip_test "pip-compile not on PATH"

  _run_build STREAM=master

  rm "${TEST_DIR}/containers/test-svc/rpms.in.yaml"

  _run_cmd STREAM=master -- update-lockfiles test-svc

  assert_file_exists "${TEST_DIR}/containers/test-svc/rpms.in.yaml"
  assert_grep "python3" "${TEST_DIR}/containers/test-svc/rpms.in.yaml"
  assert_grep "gcc" "${TEST_DIR}/containers/test-svc/rpms.in.yaml"
}

# ── Pure RPM project tests ──────────────────────────────────────────────

test_update_sources_pure_rpm_generates_rpms_in() {
  _run_cmd STREAM=master -- update-sources test-rpmsvc

  local rpms="${TEST_DIR}/containers/test-rpmsvc/rpms.in.yaml"
  assert_file_exists "${rpms}"
  assert_grep "httpd" "${rpms}"
  assert_grep "gcc-c++" "${rpms}"
}

test_update_sources_pure_rpm_skips_lockfiles() {
  _run_cmd STREAM=master -- update-sources test-rpmsvc

  assert "no lockfile for pure RPM project" \
    test ! -f "${TEST_DIR}/containers/test-rpmsvc/requirements.lock.master"
  assert "no build lockfile for pure RPM project" \
    test ! -f "${TEST_DIR}/containers/test-rpmsvc/buildrequirements.lock.master"
  assert_grep "pure RPM project" "${TEST_DIR}/build.log"
}

test_update_lockfiles_pure_rpm_generates_rpms_in() {
  _run_cmd STREAM=master -- update-lockfiles test-rpmsvc

  local rpms="${TEST_DIR}/containers/test-rpmsvc/rpms.in.yaml"
  assert_file_exists "${rpms}"
  assert_grep "httpd" "${rpms}"
  assert_grep "gcc-c++" "${rpms}"
}

test_update_lockfiles_pure_rpm_skips_lockfiles() {
  _run_cmd STREAM=master -- update-lockfiles test-rpmsvc

  assert "no lockfile for pure RPM project" \
    test ! -f "${TEST_DIR}/containers/test-rpmsvc/requirements.lock.master"
  assert "no build lockfile for pure RPM project" \
    test ! -f "${TEST_DIR}/containers/test-rpmsvc/buildrequirements.lock.master"
  assert_grep "pure RPM project" "${TEST_DIR}/build.log"
}

test_update_sources_all_includes_pure_rpm() {
  _run_cmd STREAM=master -- update-sources all

  assert_file_exists "${TEST_DIR}/containers/test-rpmsvc/rpms.in.yaml"
  assert_grep "httpd" "${TEST_DIR}/containers/test-rpmsvc/rpms.in.yaml"
  assert "no lockfile for pure RPM project" \
    test ! -f "${TEST_DIR}/containers/test-rpmsvc/requirements.lock.master"
}

# ── Requirement-exclusion tests ──────────────────────────────────────────

# update-sources strips excluded requirements from the cloned source tree so the
# excluded package is absent from the generated lockfile.
test_update_sources_applies_exclusions() {
  command -v pip-compile >/dev/null 2>&1 || skip_test "pip-compile not on PATH"

  printf '# drop pbr for this test\npbr\n' \
    > "${TEST_DIR}/containers/test-svc/excluded-requirements.txt"

  _run_build STREAM=master

  # Auto-cloned source trees are removed when build.sh exits, so validate the
  # exclusion through the generated lockfile that consumes the edited tree.
  local lock="${TEST_DIR}/containers/test-svc/requirements.lock.master"
  assert_file_exists "${lock}"
  assert_grep 'six' "${lock}"
  assert_no_grep '^pbr' "${lock}"
}

# ── sync-locks tests ─────────────────────────────────────────────────────

test_sync_locks_preserves_source_pins() {
  command -v pip-compile >/dev/null 2>&1 || skip_test "pip-compile not on PATH"

  # pybuild-deps may fail on the six-only pin; pins are rewritten before that.
  _run_cmd STREAM=master -- sync-locks test-svc || true

  local src="${TEST_DIR}/containers/test-svc/sources.txt"
  assert_field "${src}" master upper-constraints 5 "${REQ_HASH_OLD}"
  assert_field "${src}" master test-svc 5 "${SVC_HASH_OLD}"
}

test_sync_locks_refreshes_constraints_at_branch_tip() {
  command -v pip-compile >/dev/null 2>&1 || skip_test "pip-compile not on PATH"

  _run_cmd STREAM=master -- sync-locks test-svc || true

  local uc="${TEST_DIR}/containers/test-svc/upper-constraints.txt.master"
  assert_file_exists "${uc}"
  assert_grep "six==1.17.0" "${uc}"
  assert_grep "pbr==7.0.3" "${uc}"
  assert_field "${TEST_DIR}/containers/test-svc/sources.txt" \
    master upper-constraints 5 "${REQ_HASH_OLD}"
}

test_sync_locks_clones_missing_at_pinned_hash() {
  command -v pip-compile >/dev/null 2>&1 || skip_test "pip-compile not on PATH"

  _run_cmd STREAM=master -- sync-locks test-svc || true

  local lock="${TEST_DIR}/containers/test-svc/requirements.lock.master"
  assert_file_exists "${lock}"
  assert_grep "six" "${lock}"
  # Old pin's requirements.txt is "six" only. Cloning at branch tip would
  # pull in pbr; compiling against the pin must not.
  assert_no_grep "^pbr" "${lock}"
}

test_sync_locks_preserves_preexisting_checkout() {
  command -v pip-compile >/dev/null 2>&1 || skip_test "pip-compile not on PATH"
  command -v pybuild-deps >/dev/null 2>&1 || skip_test "pybuild-deps not on PATH"

  local src_dir="${TEST_DIR}/containers/test-svc/src/test-svc"
  mkdir -p "${src_dir}"
  echo "local-dev" > "${src_dir}/MARKER"
  printf 'six\npbr\n' > "${src_dir}/requirements.txt"

  _run_cmd STREAM=master -- sync-locks test-svc

  assert_file_exists "${src_dir}/MARKER"
  assert_grep "local-dev" "${src_dir}/MARKER"
  assert_field "${TEST_DIR}/containers/test-svc/sources.txt" \
    master test-svc 5 "${SVC_HASH_OLD}"

  local lock="${TEST_DIR}/containers/test-svc/requirements.lock.master"
  assert_file_exists "${lock}"
  assert_grep "six" "${lock}"
  assert_grep "pbr" "${lock}"
}

test_sync_locks_uses_REQUIREMENTS_SRC() {
  command -v pip-compile >/dev/null 2>&1 || skip_test "pip-compile not on PATH"

  mkdir -p "${TEST_DIR}/reqs"
  printf 'six==1.17.0\ncustom-pkg==9.9.9\n' \
    > "${TEST_DIR}/reqs/upper-constraints.txt"

  _run_cmd STREAM=master REQUIREMENTS_SRC="${TEST_DIR}/reqs" -- sync-locks test-svc || true

  local uc="${TEST_DIR}/containers/test-svc/upper-constraints.txt.master"
  assert_file_exists "${uc}"
  assert_grep "custom-pkg==9.9.9" "${uc}"
  assert_no_grep "pbr" "${uc}"
  assert_field "${TEST_DIR}/containers/test-svc/sources.txt" \
    master upper-constraints 5 "${REQ_HASH_OLD}"
}

test_sync_locks_does_not_generate_rpms_in() {
  command -v pip-compile >/dev/null 2>&1 || skip_test "pip-compile not on PATH"

  _run_cmd STREAM=master -- sync-locks test-svc || true

  assert "no rpms.in.yaml for sync-locks" \
    test ! -f "${TEST_DIR}/containers/test-svc/rpms.in.yaml"
}

test_sync_locks_creates_default_stream_symlinks() {
  command -v pip-compile >/dev/null 2>&1 || skip_test "pip-compile not on PATH"
  command -v pybuild-deps >/dev/null 2>&1 || skip_test "pybuild-deps not on PATH"

  # six-only pin locks make pybuild-deps 0.5.0 crash; stage a richer tree.
  local src_dir="${TEST_DIR}/containers/test-svc/src/test-svc"
  mkdir -p "${src_dir}"
  printf 'six\npbr\n' > "${src_dir}/requirements.txt"

  _run_cmd STREAM=master DEFAULT_STREAM=master -- sync-locks test-svc

  local d="${TEST_DIR}/containers/test-svc"
  assert_symlink "${d}/upper-constraints.txt"
  assert_symlink "${d}/requirements.lock"
  assert_symlink "${d}/buildrequirements.lock"
  assert_link_target "${d}/requirements.lock" "requirements.lock.master"
  assert_link_target "${d}/upper-constraints.txt" "upper-constraints.txt.master"
}

test_sync_locks_single_target_does_not_affect_other() {
  command -v pip-compile >/dev/null 2>&1 || skip_test "pip-compile not on PATH"

  _run_cmd STREAM=master -- sync-locks test-svc || true

  assert_file_exists "${TEST_DIR}/containers/test-svc/upper-constraints.txt.master"
  assert "no constraints for test-svc2" \
    test ! -f "${TEST_DIR}/containers/test-svc2/upper-constraints.txt.master"
  assert_field "${TEST_DIR}/containers/test-svc2/sources.txt" \
    master test-svc2 5 "${SVC2_HASH_OLD}"
}

test_sync_locks_unknown_target_fails() {
  if _run_cmd STREAM=master -- sync-locks nonexistent 2>/dev/null; then
    echo "    ASSERTION FAILED: expected failure for unknown target"
    return 1
  fi
  assert_grep "ERROR: Unknown image or project" "${TEST_DIR}/build.log"
}

# ── Run all tests ────────────────────────────────────────────────────────

echo "=== update-sources tests ==="
echo ""

TESTS=(
  test_updates_hashes_to_branch_tip
  test_skip_hash_update_records_pinned_version
  test_version_failure_leaves_sources_unchanged
  test_fetches_upper_constraints
  test_generates_rpms_in_yaml
  test_generates_requirements_lock
  test_generates_buildrequirements_lock
  test_creates_default_stream_symlinks
  test_skips_symlinks_for_non_default_stream
  test_skip_hash_update_preserves_hashes
  test_skip_hash_update_fetches_constraints_at_pinned_hash
  test_hash_in_branch_field_upper_constraints
  test_hash_in_branch_field_regular_repo
  test_lockfile_excludes_rpm_python_packages
  test_lockfile_excludes_rpm_python_packages_nvr
  test_preexisting_checkout_is_preserved
  test_list_discovers_all_projects
  test_update_sources_multiple_targets
  test_update_sources_multiple_targets_fetches_constraints
  test_update_sources_multiple_targets_generates_lockfiles
  test_update_sources_multiple_targets_generates_rpms_in
  test_update_sources_single_target_does_not_affect_other
  test_update_sources_all_updates_everything
  test_update_sources_unknown_target_fails
  test_update_sources_multiple_targets_symlinks
  test_update_lockfiles_regenerates_lockfile
  test_update_lockfiles_fails_without_constraints
  test_update_lockfiles_fails_without_lockfile
  test_update_lockfiles_includes_pythondeps
  test_update_lockfiles_generates_buildrequirements
  test_update_lockfiles_filters_rpm_packages
  test_update_lockfiles_filters_rpm_packages_nvr
  test_update_lockfiles_does_not_modify_sources
  test_update_lockfiles_multiple_targets
  test_update_lockfiles_creates_symlinks
  test_update_lockfiles_generates_rpms_in
  test_update_sources_pure_rpm_generates_rpms_in
  test_update_sources_pure_rpm_skips_lockfiles
  test_update_lockfiles_pure_rpm_generates_rpms_in
  test_update_lockfiles_pure_rpm_skips_lockfiles
  test_update_sources_all_includes_pure_rpm
  test_update_sources_applies_exclusions
  test_sync_locks_preserves_source_pins
  test_sync_locks_refreshes_constraints_at_branch_tip
  test_sync_locks_clones_missing_at_pinned_hash
  test_sync_locks_preserves_preexisting_checkout
  test_sync_locks_uses_REQUIREMENTS_SRC
  test_sync_locks_does_not_generate_rpms_in
  test_sync_locks_creates_default_stream_symlinks
  test_sync_locks_single_target_does_not_affect_other
  test_sync_locks_unknown_target_fails
)

for t in "${TESTS[@]}"; do
  run_test "${t}"
done

echo ""
echo "=== ${_PASS} passed, ${_FAIL} failed, ${_SKIP} skipped ==="

[[ ${_FAIL} -eq 0 ]]
