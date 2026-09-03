"""TODO: remove when tobiko/tests/conftest.py does not require git metadata.

pytest_configure runs git log / git describe with no try/except. This image
has no checkout; return empty.
"""

import subprocess

_real_check_output = subprocess.check_output

_SKIP = {
    ("git", "log", "-n", "1"),
    ("git", "describe", "--tags"),
}


def _check_output(args, *pargs, **kwargs):
    if isinstance(args, (list, tuple)) and tuple(args) in _SKIP:
        return b"" if not kwargs.get("universal_newlines") else ""
    try:
        return _real_check_output(args, *pargs, **kwargs)
    except FileNotFoundError:
        if isinstance(args, (list, tuple)) and args and args[0] == "git":
            return b"" if not kwargs.get("universal_newlines") else ""
        raise


subprocess.check_output = _check_output
