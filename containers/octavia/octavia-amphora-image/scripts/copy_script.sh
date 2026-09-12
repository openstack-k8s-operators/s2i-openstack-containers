#!/bin/bash
set -eu

DEST_DIR="${DEST_DIR:-/target}"

if [ ! -d "${DEST_DIR}" ]; then
    echo "${DEST_DIR} doesn't exist"
    exit 1
fi

if [ -e "${DEST_DIR}"/.notmounted ]; then
    echo "${DEST_DIR} is not an external volume"
    exit 2
fi

cp -v /images/* "${DEST_DIR}/"
