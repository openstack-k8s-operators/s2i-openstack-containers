# When pre-built wheels are available in the chroot (bind-mounted by
# extra-data.d/50-mount-wheels), configure pip to use them exclusively.
# This is sourced by dib-run-parts before install.d scripts run.
if [ -d /tmp/wheels ]; then
    export PIP_FIND_LINKS="/tmp/wheels/pkgs /tmp/wheels/deps"
    export PIP_NO_INDEX=1
fi
