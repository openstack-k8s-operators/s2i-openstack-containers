#!/usr/bin/env bash
# Tests for build.sh auto-detect and list-sources commands.
#
# Creates a minimal containers tree that exercises project-level and
# image-level sources.txt files so tests run offline and without real
# container builds.
#
# Usage:
#   bash tests/test_auto_detect.sh
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

assert_grep()    { assert "grep '$1' in $2" grep -q "$1" "$2"; }
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
      echo "    --- build.log (last 20 lines) ---"
      tail -20 "${TEST_DIR}/build.log" | sed 's/^/    /'
      echo "    ---"
    fi
  fi

  _teardown_fixture
}

# ── Fixture ──────────────────────────────────────────────────────────────
#
# Tree layout:
#   containers/
#     alpha/
#       sources.txt           → alpha-svc (project-level)
#       alpha-one/Containerfile
#       alpha-two/Containerfile
#     beta/
#       sources.txt           → beta-svc (project-level)
#       beta-sub/
#         sources.txt          → beta-extra (image-level only)
#         Containerfile
#       beta-main/Containerfile
#
# This exercises:
#   - project-level match → all images under the project
#   - image-level match   → only the specific image
#   - list-sources dedup  → image-level source also in project-level

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR=""

_setup_fixture() {
  TEST_DIR="$(mktemp -d)"

  ln -s "${SCRIPT_DIR}/build.sh" "${TEST_DIR}/build.sh"

  # alpha: two images, one project-level sources.txt
  mkdir -p "${TEST_DIR}/containers/alpha/alpha-one"
  mkdir -p "${TEST_DIR}/containers/alpha/alpha-two"
  mkdir -p "${TEST_DIR}/containers/alpha/src"
  echo "FROM scratch" > "${TEST_DIR}/containers/alpha/alpha-one/Containerfile"
  echo "FROM scratch" > "${TEST_DIR}/containers/alpha/alpha-two/Containerfile"
  cat > "${TEST_DIR}/containers/alpha/sources.txt" <<'EOF'
master upper-constraints https://opendev.org/openstack/requirements.git master abc123
master alpha-svc https://opendev.org/openstack/alpha-svc.git master def456
EOF

  # beta: two images, project-level + one image-level sources.txt
  mkdir -p "${TEST_DIR}/containers/beta/beta-main"
  mkdir -p "${TEST_DIR}/containers/beta/beta-sub"
  mkdir -p "${TEST_DIR}/containers/beta/src"
  echo "FROM scratch" > "${TEST_DIR}/containers/beta/beta-main/Containerfile"
  echo "FROM scratch" > "${TEST_DIR}/containers/beta/beta-sub/Containerfile"
  cat > "${TEST_DIR}/containers/beta/sources.txt" <<'EOF'
master upper-constraints https://opendev.org/openstack/requirements.git master abc123
master beta-svc https://opendev.org/openstack/beta-svc.git master 111222
EOF
  cat > "${TEST_DIR}/containers/beta/beta-sub/sources.txt" <<'EOF'
master beta-extra https://opendev.org/openstack/beta-extra.git master 333444
EOF
}

_teardown_fixture() {
  [[ -n "${TEST_DIR}" ]] && rm -rf "${TEST_DIR}"
}

_run() {
  local action="$1"
  shift
  (
    cd "${TEST_DIR}"
    export STREAM=master
    export REGISTRY=registry.test:5000
    export NAMESPACE=openstack
    export TAG=test
    export PARALLEL=1
    ./build.sh "${action}" "$@"
  )
}

# ── auto-detect tests ────────────────────────────────────────────────────

test_project_level_match_returns_all_images() {
  local output
  output="$(_run auto-detect openstack/alpha-svc 2>/dev/null)"
  echo "${output}" > "${TEST_DIR}/build.log"

  local count
  count="$(echo "${output}" | wc -l | tr -d ' ')"
  assert "returns 2 images" test "${count}" -eq 2
  assert "contains alpha/alpha-one" echo "${output}" | grep -qF "alpha/alpha-one"
  assert "contains alpha/alpha-two" echo "${output}" | grep -qF "alpha/alpha-two"
}

test_image_level_match_returns_only_that_image() {
  local output
  output="$(_run auto-detect openstack/beta-extra 2>/dev/null)"
  echo "${output}" > "${TEST_DIR}/build.log"

  local count
  count="$(echo "${output}" | wc -l | tr -d ' ')"
  assert "returns exactly 1 image" test "${count}" -eq 1
  assert "returns beta/beta-sub" echo "${output}" | grep -qF "beta/beta-sub"
}

test_image_level_match_does_not_return_siblings() {
  local output
  output="$(_run auto-detect openstack/beta-extra 2>/dev/null)"
  echo "${output}" > "${TEST_DIR}/build.log"

  assert "does not contain beta/beta-main" \
    test "$(echo "${output}" | grep -c "beta/beta-main")" -eq 0
}

test_full_url_form() {
  local output
  output="$(_run auto-detect "https://opendev.org/openstack/alpha-svc.git" 2>/dev/null)"
  echo "${output}" > "${TEST_DIR}/build.log"

  assert "contains alpha/alpha-one" echo "${output}" | grep -qF "alpha/alpha-one"
}

test_zuul_canonical_name_form() {
  local output
  output="$(_run auto-detect "opendev.org/openstack/alpha-svc" 2>/dev/null)"
  echo "${output}" > "${TEST_DIR}/build.log"

  local count
  count="$(echo "${output}" | wc -l | tr -d ' ')"
  assert "returns 2 images" test "${count}" -eq 2
  assert "contains alpha/alpha-one" echo "${output}" | grep -qF "alpha/alpha-one"
  assert "contains alpha/alpha-two" echo "${output}" | grep -qF "alpha/alpha-two"
}

test_unknown_project_fails() {
  local rc=0
  local stderr
  stderr="$(_run auto-detect "openstack/nonexistent" 2>&1 >/dev/null)" || rc=$?

  assert "non-zero exit" test "${rc}" -ne 0
  echo "${stderr}" > "${TEST_DIR}/build.log"
  assert_grep "no images reference" "${TEST_DIR}/build.log"
}

test_empty_arg_fails() {
  local rc=0
  _run auto-detect "" >/dev/null 2>&1 || rc=$?
  assert "non-zero exit" test "${rc}" -ne 0
}

test_no_arg_fails() {
  local rc=0
  (
    cd "${TEST_DIR}"
    export PARALLEL=1
    ./build.sh auto-detect
  ) >/dev/null 2>&1 || rc=$?
  assert "non-zero exit" test "${rc}" -ne 0
}

# ── list-sources tests ───────────────────────────────────────────────────

test_list_sources_image_level_returns_pipe_delimited() {
  local output
  output="$(_run list-sources beta/beta-sub master 2>/dev/null)"
  echo "${output}" > "${TEST_DIR}/build.log"

  local line_count
  line_count="$(echo "${output}" | wc -l | tr -d ' ')"
  assert "at least 1 line" test "${line_count}" -ge 1

  while IFS= read -r line; do
    local field_count
    field_count="$(echo "${line}" | awk -F'|' '{print NF}')"
    assert "5 pipe-delimited fields in: ${line}" test "${field_count}" -eq 5
  done <<< "${output}"
}

test_list_sources_image_level_includes_project_and_image_sources() {
  local output
  output="$(_run list-sources beta/beta-sub master 2>/dev/null)"
  echo "${output}" > "${TEST_DIR}/build.log"

  assert_grep "beta-svc" "${TEST_DIR}/build.log"
  assert_grep "beta-extra" "${TEST_DIR}/build.log"
}

test_list_sources_excludes_upper_constraints() {
  local output
  output="$(_run list-sources alpha/alpha-one master 2>/dev/null)"
  echo "${output}" > "${TEST_DIR}/build.log"

  assert_no_grep "upper-constraints" "${TEST_DIR}/build.log"
}

test_list_sources_project_level_includes_image_level_sources() {
  local output
  output="$(_run list-sources beta master 2>/dev/null)"
  echo "${output}" > "${TEST_DIR}/build.log"

  assert_grep "beta-svc" "${TEST_DIR}/build.log"
  assert_grep "beta-extra" "${TEST_DIR}/build.log"
}

test_list_sources_project_level_deduplicates() {
  # beta-sub/sources.txt could cause duplicates with project-level
  # if the same source appears in both (not in this fixture, but the
  # code path is exercised by ensuring no repeated names)
  local output
  output="$(_run list-sources beta master 2>/dev/null)"
  echo "${output}" > "${TEST_DIR}/build.log"

  local beta_svc_count
  beta_svc_count="$(echo "${output}" | grep -c "^beta-svc|" || true)"
  assert "beta-svc appears exactly once" test "${beta_svc_count}" -eq 1
}

test_list_sources_nonexistent_stream_returns_nothing() {
  local output
  output="$(_run list-sources alpha/alpha-one nonexistent-stream 2>/dev/null)"
  assert "empty output" test -z "${output}"
}

test_list_required_projects_includes_opendev_repo() {
  local output
  output="$(_run list-required-projects master 2>/dev/null)"
  echo "${output}" > "${TEST_DIR}/build.log"

  assert_grep "opendev.org/openstack/requirements" "${TEST_DIR}/build.log"
  assert_grep "opendev.org/openstack/beta-svc" "${TEST_DIR}/build.log"
}

test_list_required_projects_is_sorted_unique() {
  local output
  output="$(_run list-required-projects master 2>/dev/null)"
  echo "${output}" > "${TEST_DIR}/build.log"

  local sorted
  sorted="$(echo "${output}" | sort -u)"
  assert "sorted unique output" test "${output}" = "${sorted}"
}

# ── create-zuul-required-projects.sh tests ───────────────────────────────

_run_generator() {
  S2I_REPO_ROOT="${TEST_DIR}" STREAM=master PARALLEL=1 \
    "${SCRIPT_DIR}/scripts/create-zuul-required-projects.sh" "$@"
}

test_generator_requires_output() {
  local rc=0
  local stderr
  stderr="$(_run_generator 2>&1 >/dev/null)" || rc=$?
  echo "${stderr}" > "${TEST_DIR}/build.log"

  assert "non-zero exit" test "${rc}" -ne 0
  assert_grep "output is required" "${TEST_DIR}/build.log"
}

test_generator_writes_opendev_required_projects() {
  echo "master extra-gh https://github.com/example/foo.git master abcdef" \
    >> "${TEST_DIR}/containers/alpha/sources.txt"

  local out="${TEST_DIR}/s2i-source-required-projects.yaml"
  _run_generator --output "${out}" --stream master \
    > "${TEST_DIR}/build.log"

  assert "output file exists" test -f "${out}"
  assert_grep "name: s2i-openstack-zuul-sources-base" "${out}"
  assert_grep "opendev.org/openstack/requirements" "${out}"
  assert_grep "opendev.org/openstack/beta-svc" "${out}"
  assert_grep "github.com/openstack-k8s-operators/s2i-openstack-containers" "${out}"
  assert_no_grep "github.com/example/foo" "${out}"
}

test_generator_unknown_stream_fails() {
  local rc=0
  local stderr
  stderr="$(_run_generator --output "${TEST_DIR}/out.yaml" --stream missing 2>&1)" || rc=$?
  echo "${stderr}" > "${TEST_DIR}/build.log"

  assert "non-zero exit" test "${rc}" -ne 0
  assert_grep "no required projects found" "${TEST_DIR}/build.log"
}

test_generator_allow_from_keeps_tenant_projects_only() {
  cat > "${TEST_DIR}/projects.yaml" <<'EOF'
- job:
    name: unrelated-job
    required-projects:
      - name: opendev.org/openstack/requirements
- project:
    name: opendev.org/openstack/beta-svc
- project:
    name: '^github.com/example/.*'
EOF

  local out="${TEST_DIR}/s2i-source-required-projects.yaml"
  local stderr
  stderr="$(_run_generator --output "${out}" --allow-from "${TEST_DIR}/projects.yaml" 2>&1)"
  echo "${stderr}" > "${TEST_DIR}/build.log"

  assert_grep "name: s2i-openstack-zuul-sources-base" "${out}"
  assert_grep "opendev.org/openstack/beta-svc" "${out}"
  assert_grep "github.com/openstack-k8s-operators/s2i-openstack-containers" "${out}"
  assert_no_grep "opendev.org/openstack/requirements" "${out}"
  assert_no_grep "opendev.org/openstack/alpha-svc" "${out}"
  assert_grep "Skipped" "${TEST_DIR}/build.log"
}

# ── Run all tests ────────────────────────────────────────────────────────

echo "=== auto-detect and list-sources tests ==="
echo ""

TESTS=(
  test_project_level_match_returns_all_images
  test_image_level_match_returns_only_that_image
  test_image_level_match_does_not_return_siblings
  test_full_url_form
  test_zuul_canonical_name_form
  test_unknown_project_fails
  test_empty_arg_fails
  test_no_arg_fails
  test_list_sources_image_level_returns_pipe_delimited
  test_list_sources_image_level_includes_project_and_image_sources
  test_list_sources_excludes_upper_constraints
  test_list_sources_project_level_includes_image_level_sources
  test_list_sources_project_level_deduplicates
  test_list_sources_nonexistent_stream_returns_nothing
  test_list_required_projects_includes_opendev_repo
  test_list_required_projects_is_sorted_unique
  test_generator_requires_output
  test_generator_writes_opendev_required_projects
  test_generator_unknown_stream_fails
  test_generator_allow_from_keeps_tenant_projects_only
)

for t in "${TESTS[@]}"; do
  run_test "${t}"
done

echo ""
echo "=== ${_PASS} passed, ${_FAIL} failed, 0 skipped ==="

[[ ${_FAIL} -eq 0 ]]
