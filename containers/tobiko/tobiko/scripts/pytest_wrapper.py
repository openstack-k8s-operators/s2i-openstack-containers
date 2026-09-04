#!/usr/bin/env python3
"""Pytest entrypoint for the tobiko image.

TODO: remove when tobiko/tests/conftest.py does not require git metadata.
run_tests.py shells out to pytest; patch subprocess in this process before
pytest imports conftest.

"""
import sys

sys.path.insert(0, '/usr/share/tobiko/tools')
import tobiko_skip_git_metadata  # noqa: F401

from pytest import console_main

if __name__ == '__main__':
    raise SystemExit(console_main())
