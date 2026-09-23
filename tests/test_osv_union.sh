#!/usr/bin/env bash
# Tests for .github/scripts/osv-union-lockfiles.py
set -uo pipefail

_PASS=0
_FAIL=0
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${REPO_ROOT}/.github/scripts/osv-union-lockfiles.py"

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

run_test() {
  local name="$1"
  local rc=0
  ( set -e; "${name}" ) || rc=$?
  if [[ ${rc} -eq 0 ]]; then
    echo "  PASS  ${name}"
    ((_PASS++))
  else
    echo "  FAIL  ${name}"
    ((_FAIL++))
  fi
}

test_unions_duplicate_pins() {
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "${tmp}/containers/alpha" "${tmp}/containers/beta"
  cat > "${tmp}/containers/alpha/requirements.lock.master" <<'EOF'
cryptography==43.0.3
webob==1.8.10
EOF
  cat > "${tmp}/containers/beta/requirements.lock.master" <<'EOF'
cryptography==43.0.3
setuptools==82.0.1
# comment
cryptography[ssh]==43.0.3
EOF
  python3 "${SCRIPT}" \
    --containers-dir "${tmp}/containers" \
    --output "${tmp}/osv-union.json"

  assert "output exists" test -f "${tmp}/osv-union.json"
  python3 - "${tmp}/osv-union.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
pkgs = [
    (p["package"]["name"], p["package"]["version"], p["package"]["ecosystem"])
    for p in data["results"][0]["packages"]
]
assert len(pkgs) == 3, pkgs
assert ("cryptography", "43.0.3", "PyPI") in pkgs
assert ("webob", "1.8.10", "PyPI") in pkgs
assert ("setuptools", "82.0.1", "PyPI") in pkgs
PY
  rm -rf "${tmp}"
}

test_keeps_conflicting_versions() {
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "${tmp}/containers/alpha" "${tmp}/containers/beta"
  echo "setuptools==9.1.0" > "${tmp}/containers/alpha/requirements.lock.master"
  echo "setuptools==82.0.1" > "${tmp}/containers/beta/requirements.lock.master"
  python3 "${SCRIPT}" \
    --containers-dir "${tmp}/containers" \
    --output "${tmp}/osv-union.json"
  python3 - "${tmp}/osv-union.json" <<'PY'
import json
import sys

pkgs = {
    (p["package"]["name"], p["package"]["version"])
    for p in json.load(open(sys.argv[1], encoding="utf-8"))["results"][0]["packages"]
}
assert pkgs == {("setuptools", "9.1.0"), ("setuptools", "82.0.1")}, pkgs
PY
  rm -rf "${tmp}"
}

test_skips_lockfile_symlinks() {
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "${tmp}/containers/alpha"
  echo "webob==1.8.10" > "${tmp}/containers/alpha/requirements.lock.master"
  ln -s requirements.lock.master "${tmp}/containers/alpha/requirements.lock"
  python3 "${SCRIPT}" \
    --containers-dir "${tmp}/containers" \
    --output "${tmp}/osv-union.json"
  python3 - "${tmp}/osv-union.json" <<'PY'
import json
import sys

pkgs = json.load(open(sys.argv[1], encoding="utf-8"))["results"][0]["packages"]
assert len(pkgs) == 1, pkgs
PY
  rm -rf "${tmp}"
}

echo "=== osv-union-lockfiles ==="
run_test test_unions_duplicate_pins
run_test test_keeps_conflicting_versions
run_test test_skips_lockfile_symlinks

echo ""
echo "Results: ${_PASS} passed, ${_FAIL} failed"
if [[ ${_FAIL} -gt 0 ]]; then
  exit 1
fi
