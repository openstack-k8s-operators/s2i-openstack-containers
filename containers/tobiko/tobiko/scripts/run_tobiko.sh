#!/usr/bin/env bash
# Entrypoint for test-operator. Loads tox.ini setenv (stdlib, no tox package)
# then calls tools/run_tests.py. Reports go to TOBIKO_REPORT_DIR on the logs PVC.

set -x

if [[ "${TOBIKO_DEBUG_MODE}" == true ]]; then
    trap 'echo "run_tobiko.sh error"; sleep infinity' ERR
fi

if [[ -n "${TOBIKO_VERSION}" ]]; then
    echo "WARNING: TOBIKO_VERSION is ignored; rebuild the image to change tobiko." >&2
fi
if [[ -n "${TOBIKO_PATCH_REFSPEC}" ]]; then
    echo "WARNING: TOBIKO_PATCH_REFSPEC is ignored; rebuild the image." >&2
fi

SOURCE_BUILT_PKGS="/source-built-packages.txt"
if [[ -r "${SOURCE_BUILT_PKGS}" ]]; then
    IFS=, read -r _ _tobiko_commit _tobiko_release \
        < <(grep -m1 '^tobiko,' "${SOURCE_BUILT_PKGS}")
    [[ -n "${_tobiko_commit}" && "${_tobiko_commit}" != unknown ]] && \
        export TOBIKO_GIT_COMMIT="${_tobiko_commit}"
    [[ -n "${_tobiko_release}" && "${_tobiko_release}" != unknown ]] && \
        export TOBIKO_GIT_RELEASE="${_tobiko_release}"
fi

[[ -z "${TOBIKO_TESTENV}" ]] && echo "TOBIKO_TESTENV not set" && exit 1

TOBIKO_DIR="${TOBIKO_DIR:-/var/lib/tobiko}"
TOBIKO_PRIVATE_KEY_FILE="${TOBIKO_PRIVATE_KEY_FILE:-id_ecdsa}"
TOBIKO_KEYS_FOLDER="${TOBIKO_KEYS_FOLDER:-/etc/test_operator}"
TOBIKO_LOGS_DIR_NAME="${TOBIKO_LOGS_DIR_NAME:-tobiko}"

export HOME="${TOBIKO_DIR}"
export OS_CLOUD="${TOBIKO_OS_CLOUD:-${OS_CLOUD:-default}}"
[[ -n "${TOBIKO_PYTEST_ADDOPTS}" ]] && export PYTEST_ADDOPTS="${TOBIKO_PYTEST_ADDOPTS}"
[[ -n "${TOBIKO_NUM_PROCESSES}" ]] && export TOX_NUM_PROCESSES="${TOBIKO_NUM_PROCESSES}"
[[ -n "${TOBIKO_PREVENT_CREATE}" ]] && export TOBIKO_PREVENT_CREATE="${TOBIKO_PREVENT_CREATE}"
[[ -n "${TOBIKO_RUN_TESTS_TIMEOUT}" ]] && export TOX_RUN_TESTS_TIMEOUT="${TOBIKO_RUN_TESTS_TIMEOUT}"

export TOBIKO_REPORT_DIR="${TOBIKO_DIR}/external_files/${TOBIKO_LOGS_DIR_NAME}"
export TOX_COVER_DIR="${TOBIKO_REPORT_DIR}/cover"
mkdir -p "${TOBIKO_REPORT_DIR}" "${TOBIKO_DIR}/tobiko" "${TMPDIR:-/tmp}"

# test-operator mounts keys at TOBIKO_KEYS_FOLDER; ssh reads ~/.ssh.
# TODO: remove this copy when test-operator mounts the SSH key into
# ~/.ssh with the correct permissions.
if [[ -f "${TOBIKO_KEYS_FOLDER}/${TOBIKO_PRIVATE_KEY_FILE}" ]]; then
    mkdir -p "${HOME}/.ssh"
    chmod 700 "${HOME}/.ssh"
    cp "${TOBIKO_KEYS_FOLDER}/${TOBIKO_PRIVATE_KEY_FILE}"* "${HOME}/.ssh/"
    chmod 600 "${HOME}/.ssh/${TOBIKO_PRIVATE_KEY_FILE}" 2>/dev/null || true
fi

# Parent of the installed tobiko package (site-packages). Passed to
# load_tox_setenv.py as {toxinidir} so tox.ini paths become absolute
# (.../site-packages/tobiko/tests/...) before pytest runs.
# cd: pytest resolves relative pytestAddopts/posargs (tobiko/tests/...)
# from cwd; WORKDIR /var/lib/tobiko does not have that tree.
SITE_PACKAGES="$(python3 -c "import importlib.util, os; s = importlib.util.find_spec('tobiko'); print(os.path.dirname(os.path.dirname(os.path.abspath(s.origin))))")"
cd "${SITE_PACKAGES}"

EXTRA_POSARGS=()
TESTENV="${TOBIKO_TESTENV}"
if [[ "${TOBIKO_TESTENV}" == *" -- "* ]]; then
    # shellcheck disable=SC2206
    EXTRA_POSARGS=(${TOBIKO_TESTENV#* -- })
    TESTENV="${TOBIKO_TESTENV%% -- *}"
fi
TESTENV="${TESTENV#"${TESTENV%%[![:space:]]*}"}"
TESTENV="${TESTENV%"${TESTENV##*[![:space:]]}"}"

setenv_exports="$(python3 /usr/local/bin/load_tox_setenv.py "${TESTENV}" "${SITE_PACKAGES}")" || exit 1
eval "${setenv_exports}"

# Flags in PYTEST_ADDOPTS (--skipregex, -k) stay in the env; pytest
# applies them. If pytestAddopts is a test file, pass that file to
# pytest instead of the whole tox.ini directory.
ADDOPTS_FLAGS_ARR=()
ADDOPTS_PATHS_ARR=()
if [[ -n "${PYTEST_ADDOPTS:-}" ]]; then
    eval "$(python3 /usr/local/bin/load_tox_setenv.py --split-addopts "${SITE_PACKAGES}")"
fi

# tox.ini: run_tests.py {env:RUN_TESTS_EXTRA_ARGS} {posargs:{env:TOBIKO_TEST_PATH}}
RUN_ARGS=("${RUN_TESTS_EXTRA_ARGS_ARR[@]}")
if [[ ${#EXTRA_POSARGS[@]} -gt 0 ]]; then
    RUN_ARGS+=("${EXTRA_POSARGS[@]}")
elif [[ ${#ADDOPTS_PATHS_ARR[@]} -gt 0 ]]; then
    RUN_ARGS+=("${ADDOPTS_PATHS_ARR[@]}")
else
    RUN_ARGS+=("${TOBIKO_TEST_PATH:-${OS_TEST_PATH}}")
fi

/usr/bin/run_tests.py "${RUN_ARGS[@]}"
RETURN_VALUE=$?

if [[ -n "${USE_EXTERNAL_FILES}" ]]; then
    if [[ -f /etc/tobiko/tobiko.conf ]]; then
        cp /etc/tobiko/tobiko.conf "${TOBIKO_REPORT_DIR}/"
    fi
    if [[ -f "${TOBIKO_DIR}/tobiko/tobiko.log" ]]; then
        cp "${TOBIKO_DIR}/tobiko/tobiko.log" "${TOBIKO_REPORT_DIR}/"
    fi
fi

if [[ "${TOBIKO_DEBUG_MODE}" == true ]]; then
    sleep infinity
fi

exit "${RETURN_VALUE}"
