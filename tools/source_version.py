#!/usr/bin/env python3
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.

"""Calculate and validate a PBR package version from a source checkout."""

import argparse
import os

from pathlib import Path

from packaging.version import Version
from pbr.packaging import get_version


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_dir", type=Path)
    parser.add_argument("package_name")
    args = parser.parse_args()

    os.chdir(args.source_dir)
    version = get_version(args.package_name)
    Version(version)
    print(version)


if __name__ == "__main__":
    main()
