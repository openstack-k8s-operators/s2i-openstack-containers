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

"""Architecture checks for pinned source reproducibility."""

import pathlib
import unittest


class ReproducibilityArchitectureTest(unittest.TestCase):
    def setUp(self):
        self.repo_root = pathlib.Path(__file__).resolve().parents[1]

    def read(self, path):
        return (self.repo_root / path).read_text(encoding="utf-8")

    def test_github_checks_pinned_source_reproducibility(self):
        workflow = self.read(".github/workflows/test-update-sources.yml")

        self.assertIn("tox -e update-lockfiles", workflow)
        self.assertIn("git diff --exit-code -- containers/", workflow)
        self.assertIn("frozen-source-refs.master.tsv", workflow)
        self.assertNotIn("tox -e update-sources", workflow)

    def test_github_workflows_use_canonical_python(self):
        setup = self.read(".github/actions/setup-tox/action.yml")

        self.assertIn("actions/setup-python@", setup)
        self.assertIn('python-version: "3.12"', setup)
        self.assertIn("python3 -m pip install tox", setup)

    def test_generator_runtime_and_cache_are_canonical(self):
        tox = self.read("tox.ini")
        update_environment = tox.split("[testenv:update-sources]", 1)[1].split(
            "[testenv:build]", 1
        )[0]

        self.assertIn("base_python = 3.12", tox)
        self.assertIn("sys.version_info[:2] == (3, 12)", update_environment)
        self.assertIn(
            "XDG_CACHE_HOME = {envtmpdir}/cache", update_environment
        )

    def test_lock_generation_uses_canonical_python(self):
        build = self.read("build.sh")

        self.assertIn(
            "pip-compile --allow-unsafe --no-annotate --strip-extras", build
        )
        self.assertIn("pybuild-deps compile \\\n      --no-annotate", build)
        self.assertEqual(3, build.count("normalize_generated_lock"))
        for directive in (
            "index-url",
            "extra-index-url",
            "trusted-host",
        ):
            self.assertIn(directive, build)
        dependency_inputs = list(
            (self.repo_root / "containers").glob("**/pythondeps.txt")
        )
        self.assertTrue(dependency_inputs)
        for dependency_input in dependency_inputs:
            self.assertNotIn(
                "legacy-cgi",
                dependency_input.read_text(encoding="utf-8"),
            )
        for lock in (self.repo_root / "containers").glob(
            "**/*requirements.lock.*"
        ):
            content = lock.read_text(encoding="utf-8")
            self.assertNotIn("legacy-cgi", content)
            self.assertNotIn("    # via", content)
            self.assertNotIn("--index-url ", content)
            self.assertNotIn("--extra-index-url ", content)
            self.assertNotIn("--trusted-host ", content)


if __name__ == "__main__":
    unittest.main()
