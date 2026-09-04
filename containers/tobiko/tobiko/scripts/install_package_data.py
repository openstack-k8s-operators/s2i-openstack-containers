#!/usr/bin/env python3
"""Copy non-Python package data (Heat templates, playbooks) onto the install.

"""
import importlib.util
import os
import shutil
import sys


def installed_tobiko_dir() -> str:
    spec = importlib.util.find_spec("tobiko")
    if spec is None or not spec.origin:
        raise SystemExit("tobiko is not installed")
    return os.path.dirname(os.path.abspath(spec.origin))


def main(src: str) -> None:
    dst = installed_tobiko_dir()
    for root, _dirs, files in os.walk(src):
        rel = os.path.relpath(root, src)
        for name in files:
            if name.endswith(".py"):
                continue
            dest_dir = dst if rel == os.curdir else os.path.join(dst, rel)
            os.makedirs(dest_dir, exist_ok=True)
            shutil.copy2(os.path.join(root, name), os.path.join(dest_dir, name))


if __name__ == "__main__":
    main(sys.argv[1])
