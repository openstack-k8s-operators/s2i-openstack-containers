#!/usr/bin/env bash
# Sourced from openstack-k8s-operators/tcib
# container-images/tcib/base/tobiko/run_tobiko.sh
#
# Runtime entrypoint compatible with the TCIB openstack-tobiko image and
# test-operator (TOBIKO_TESTENV, TOBIKO_VERSION, USE_EXTERNAL_FILES, ...).

set -x

TOBIKO_DIR=/var/lib/tobiko
TOBIKO_SRC_DIR=/usr/local/src/tobiko
TOBIKO_DEBUG_MODE="${TOBIKO_DEBUG_MODE:-false}"

function catch_error_if_debug {
    echo "File run_tobiko.sh has run into an error!"
    sleep infinity
}

# Catch errors when in debug mode
if [[ "${TOBIKO_DEBUG_MODE}" == true ]]; then
    trap catch_error_if_debug ERR
fi

# assert mandatory variables have been set
[[ -z "${TOBIKO_TESTENV}" ]] && echo "TOBIKO_TESTENV not set" && exit 1

# set default values for the required variables
TOBIKO_VERSION="${TOBIKO_VERSION:-master}"
TOBIKO_PRIVATE_KEY_FILE="${TOBIKO_PRIVATE_KEY_FILE:-id_ecdsa}"
TOBIKO_KEYS_FOLDER="${TOBIKO_KEYS_FOLDER:-${TOBIKO_DIR}/external_files}"
TOBIKO_LOGS_DIR_NAME="${TOBIKO_LOGS_DIR_NAME:-"tobiko"}"

# export OS_CLOUD variable
[[ ! -z "${TOBIKO_OS_CLOUD}" ]] && export OS_CLOUD="${TOBIKO_OS_CLOUD}" || export OS_CLOUD=default

# export optional variables, relevant for tox and pytest execution (see tobiko tox.ini file)
[[ ! -z "${TOBIKO_PYTEST_ADDOPTS}" ]] && export PYTEST_ADDOPTS="${TOBIKO_PYTEST_ADDOPTS}"
[[ ! -z "${TOBIKO_RUN_TESTS_TIMEOUT}" ]] && export TOX_RUN_TESTS_TIMEOUT="${TOBIKO_RUN_TESTS_TIMEOUT}"
[[ ! -z "${TOBIKO_PREVENT_CREATE}" ]] && export TOBIKO_PREVENT_CREATE="${TOBIKO_PREVENT_CREATE}"
[[ ! -z "${TOBIKO_NUM_PROCESSES}" ]] && export TOX_NUM_PROCESSES="${TOBIKO_NUM_PROCESSES}"

pushd "${TOBIKO_DIR}"
cp -r "${TOBIKO_SRC_DIR}" tobiko
chown tobiko:tobiko -R tobiko
pushd tobiko
git pull --rebase
if [[ -n "${TOBIKO_PATCH_REFSPEC}" ]]; then
    git fetch "${TOBIKO_PATCH_REPOSITORY}" "${TOBIKO_PATCH_REFSPEC}" && git checkout FETCH_HEAD
else
    git checkout "${TOBIKO_VERSION}"
fi

# obtain clouds.yaml, ssh private/public keys and tobiko.conf from external_files directory
if [[ ! -z "${USE_EXTERNAL_FILES}" ]]; then
    if [[ -f "${TOBIKO_DIR}/external_files/clouds.yaml" ]]; then
        mkdir -p "${TOBIKO_DIR}/.config/openstack"
        cp "${TOBIKO_DIR}/external_files/clouds.yaml" "${TOBIKO_DIR}/.config/openstack/"
    fi
    if [[ -f "${TOBIKO_KEYS_FOLDER}/${TOBIKO_PRIVATE_KEY_FILE}" ]]; then
        mkdir -p "${TOBIKO_DIR}/.ssh"
        cp "${TOBIKO_KEYS_FOLDER}/${TOBIKO_PRIVATE_KEY_FILE}"* "${TOBIKO_DIR}/.ssh/"
        chown tobiko:tobiko "${TOBIKO_DIR}/.ssh/${TOBIKO_PRIVATE_KEY_FILE}"*
    fi
    [[ -f "${TOBIKO_DIR}/external_files/tobiko.conf" ]] && cp "${TOBIKO_DIR}/external_files/tobiko.conf" .
fi

# run tobiko tests
# Note(kstrenko): Unquoted to enable word splitting for tox -- syntax
python3 -m tox -e ${TOBIKO_TESTENV}
RETURN_VALUE=$?

# copy logs to external_files
if [[ ! -z "${USE_EXTERNAL_FILES}" ]]; then
    echo "Copying logs file"
    TOBIKO_TESTENV_ARR=(${TOBIKO_TESTENV})
    LOG_DIR="${TOX_REPORT_DIR:-/var/lib/tobiko/tobiko/.tox/${TOBIKO_TESTENV_ARR}/log}"
    cp -rf "${LOG_DIR}" "${TOBIKO_DIR}/external_files/${TOBIKO_LOGS_DIR_NAME}/"
    if [[ -f "tobiko.conf" ]]; then
        cp "tobiko.conf" "${TOBIKO_DIR}/external_files/${TOBIKO_LOGS_DIR_NAME}/"
    elif [[ -f "/etc/tobiko/tobiko.conf" ]]; then
        cp "/etc/tobiko/tobiko.conf" "${TOBIKO_DIR}/external_files/${TOBIKO_LOGS_DIR_NAME}/"
    fi
fi

# Keep pod in running state when in debug mode
if [[ "${TOBIKO_DEBUG_MODE}" == true ]]; then
    sleep infinity
fi

exit "${RETURN_VALUE}"
