#!/usr/bin/env python3
"""Build a unique OSV-Scanner input from per-service pip-compile lockfiles.

Each image keeps its own requirements.lock.<stream>. Those files share most
packages, so scanning them individually repeats the same CVE once per service.
This script emits one osv-scanner.json with unique (name, version) pins so a
single scan covers the union of what images install.

Version conflicts are kept as separate pins: both setuptools==9.1.0 and
setuptools==82.0.1 are scanned when they appear.
"""

from __future__ import annotations

import argparse
import json
import sys

from pathlib import Path


LOCKFILE_PREFIX = "requirements.lock."
ECOSYSTEM = "PyPI"


def iter_lockfiles(containers_dir: Path) -> list[Path]:
    files = [
        path
        for path in sorted(containers_dir.rglob(f"{LOCKFILE_PREFIX}*"))
        if path.is_file() and not path.is_symlink()
    ]
    return files


def parse_requirement_line(line: str) -> tuple[str, str] | None:
    stripped = line.strip()
    if not stripped or stripped.startswith("#") or stripped.startswith("-"):
        return None
    # Drop inline hashes / extras after the requirement: pkg==1.2.3 --hash=...
    requirement = stripped.split("--", 1)[0].strip()
    requirement = requirement.split(";", 1)[0].strip()
    if "==" not in requirement:
        return None
    name, version = requirement.split("==", 1)
    name = name.split("[", 1)[0].strip().lower()
    version = version.strip()
    if not name or not version:
        return None
    return name, version


def collect_packages(lockfiles: list[Path]) -> tuple[dict[tuple[str, str], None], int]:
    packages: dict[tuple[str, str], None] = {}
    raw_count = 0
    for path in lockfiles:
        for line in path.read_text(encoding="utf-8").splitlines():
            parsed = parse_requirement_line(line)
            if parsed is None:
                continue
            raw_count += 1
            packages[parsed] = None
    return packages, raw_count


def to_osv_document(packages: dict[tuple[str, str], None]) -> dict:
    entries = [
        {
            "package": {
                "name": name,
                "version": version,
                "ecosystem": ECOSYSTEM,
            }
        }
        for name, version in packages
    ]
    return {"results": [{"packages": entries}]}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--containers-dir",
        type=Path,
        default=Path("containers"),
        help="Root directory that holds per-service lockfiles",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("osv-union.json"),
        help="Path to write the osv-scanner.json document",
    )
    args = parser.parse_args(argv)

    lockfiles = iter_lockfiles(args.containers_dir)
    if not lockfiles:
        print(
            f"No {LOCKFILE_PREFIX}* files found under {args.containers_dir}",
            file=sys.stderr,
        )
        return 1

    packages, raw_count = collect_packages(lockfiles)
    args.output.write_text(
        json.dumps(to_osv_document(packages), indent=2) + "\n",
        encoding="utf-8",
    )

    versions_by_name: dict[str, set[str]] = {}
    for name, version in packages:
        versions_by_name.setdefault(name, set()).add(version)
    conflicts = sum(1 for versions in versions_by_name.values() if len(versions) > 1)

    print(
        f"Lockfiles: {len(lockfiles)}; "
        f"pins: {raw_count}; "
        f"unique (name, version): {len(packages)}; "
        f"name version-conflicts: {conflicts}"
    )
    print(f"Wrote {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
