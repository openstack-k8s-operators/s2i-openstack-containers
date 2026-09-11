"""Installed into site-packages as sitecustomize.py.

TODO: remove when tobiko/tests/conftest.py does not require git metadata.
run_tests.py starts pytest in a subprocess; this is loaded at Python startup
(including xdist workers) so subprocess is patched before conftest runs.
"""
import sys

sys.path.insert(0, '/usr/share/tobiko/tools')
import tobiko_skip_git_metadata  # noqa: F401
