#!/usr/bin/env bash
# Contract tests for roles/s2i_build (no real container builds).
#
# Uses a fake build.sh that records argv + env, then runs the role via
# ansible-playbook.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

assert_file_contains() {
  local file="$1" needle="$2"
  if grep -qF -- "${needle}" "${file}"; then
    return 0
  fi
  echo "    ASSERTION FAILED: '${needle}' not in ${file}"
  echo "    --- file contents ---"
  cat "${file}" || true
  return 1
}

pass() {
  echo "    PASS"
  PASS=$((PASS + 1))
}

fail() {
  echo "    FAIL: $*"
  FAIL=$((FAIL + 1))
}

if ! command -v ansible-playbook >/dev/null 2>&1; then
  echo "SKIP: ansible-playbook not on PATH"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

MOCK_REPO="${TMP}/repo"
mkdir -p "${MOCK_REPO}"
cat > "${MOCK_REPO}/build.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
  echo "argv:$*"
  echo "STREAM=${STREAM-}"
  echo "REGISTRY=${REGISTRY-}"
  echo "NAMESPACE=${NAMESPACE-}"
  echo "TAG=${TAG-}"
  echo "IMAGE_PREFIX=${IMAGE_PREFIX-}"
  echo "BASE_IMAGE=${BASE_IMAGE-}"
} >> "$(dirname "$0")/build.log"
EOF
chmod +x "${MOCK_REPO}/build.sh"

PLAYBOOK="${TMP}/run.yaml"
cat > "${PLAYBOOK}" <<EOF
---
- hosts: localhost
  connection: local
  gather_facts: false
  roles:
    - role: ${ROOT}/roles/s2i_build
EOF

INV="${TMP}/inventory"
cat > "${INV}" <<'EOF'
localhost ansible_connection=local
EOF

run_role() {
  rm -f "${MOCK_REPO}/build.log"
  ANSIBLE_ROLES_PATH="${ROOT}/roles" \
  ANSIBLE_LOCAL_TEMP="${TMP}/ansible-local" \
  ANSIBLE_REMOTE_TMP="${TMP}/ansible-remote" \
    ansible-playbook -i "${INV}" "${PLAYBOOK}" \
      -e "s2i_build_repo_dir=${MOCK_REPO}" \
      "$@"
}

echo "==> build watcher includes base then watcher"
if run_role \
  -e '{"s2i_build_targets":["watcher"]}' \
  -e s2i_build_stream=master \
  -e s2i_build_registry=localhost \
  -e s2i_build_namespace=openstack \
  -e s2i_build_tag=master-latest \
  && assert_file_contains "${MOCK_REPO}/build.log" "argv:build base" \
  && assert_file_contains "${MOCK_REPO}/build.log" "argv:build watcher" \
  && assert_file_contains "${MOCK_REPO}/build.log" "STREAM=master"
then
  pass
else
  fail "watcher/base sequence"
fi

echo "==> BASE_IMAGE skips include-base"
if run_role \
  -e '{"s2i_build_targets":["watcher"]}' \
  -e s2i_build_base_image=quay.io/openstack/openstack-base:master-latest \
  -e s2i_build_include_base=true \
  && assert_file_contains "${MOCK_REPO}/build.log" "argv:build watcher" \
  && assert_file_contains "${MOCK_REPO}/build.log" "BASE_IMAGE=quay.io/openstack/openstack-base:master-latest" \
  && ! grep -qF "argv:build base" "${MOCK_REPO}/build.log"
then
  pass
else
  fail "BASE_IMAGE skip"
fi

echo "==> push after build when s2i_build_push=true"
if run_role \
  -e '{"s2i_build_targets":["all"]}' \
  -e s2i_build_push=true \
  && assert_file_contains "${MOCK_REPO}/build.log" "argv:build all" \
  && assert_file_contains "${MOCK_REPO}/build.log" "argv:push all"
then
  pass
else
  fail "push"
fi

echo "==> missing s2i_build_repo_dir fails"
if ANSIBLE_ROLES_PATH="${ROOT}/roles" \
  ANSIBLE_LOCAL_TEMP="${TMP}/ansible-local" \
  ANSIBLE_REMOTE_TMP="${TMP}/ansible-remote" \
  ansible-playbook -i "${INV}" "${PLAYBOOK}" \
    -e s2i_build_repo_dir="" >/dev/null 2>&1
then
  fail "expected missing repo_dir to fail"
else
  pass
fi

echo "==> invalid s2i_build_action fails"
if run_role -e s2i_build_action=not-a-verb >/dev/null 2>&1
then
  fail "expected invalid action to fail"
else
  pass
fi

echo
echo "Passed: ${PASS}  Failed: ${FAIL}"
[[ "${FAIL}" -eq 0 ]]
