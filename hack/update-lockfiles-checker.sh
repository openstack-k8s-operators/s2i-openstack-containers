#!/bin/bash
set -ex

if [ -n "${UPDATE_LOCKFILES_TARGETS:-}" ]; then
    # If there is variable UPDATE_LOCKFILES_TARGETS checked those services
    services="${UPDATE_LOCKFILES_TARGETS}"
else
    # If there is no variable, detect the changed containers in the last commit
    services=$(git diff --cached --name-only | grep "^containers/" | cut -d/ -f2 | sort -u | tr "\n" " ")
fi

# if there are services to be checked, run update-lockfiles on them.
if [ -n "${services}" ]; then
    tox -e update-lockfiles -- ${services}
fi
