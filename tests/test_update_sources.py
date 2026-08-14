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

"""Tests for build.sh update-sources behavior."""

import csv
import os
import pathlib
import subprocess
import tempfile
import unittest


class UpdateSourcesTest(unittest.TestCase):
    def setUp(self):
        self.repo_root = pathlib.Path(__file__).resolve().parents[1]
        tmp_root = self.repo_root / ".tmp"
        tmp_root.mkdir(exist_ok=True)
        self.temporary_directory = tempfile.TemporaryDirectory(
            dir=tmp_root, prefix="update-sources-test."
        )
        self.addCleanup(self.temporary_directory.cleanup)
        self.test_root = pathlib.Path(self.temporary_directory.name)
        upstream_root = self.test_root / "upstream"
        upstream_root.mkdir()

        self.upstream_requirements = upstream_root / "requirements.git"
        self.requirements_old, self.requirements_new = self.create_remote(
            self.upstream_requirements,
            [
                {"upper-constraints.txt": "six==1.17.0\n"},
                {"upper-constraints.txt": ("six==1.17.0\npbr==7.0.3\n")},
            ],
        )
        self.upstream_service = upstream_root / "test-svc.git"
        self.service_old, self.service_new = self.create_remote(
            self.upstream_service,
            [
                {"requirements.txt": "six\npbr\n"},
                {"requirements.txt": "six\npbr\n# v2\n"},
            ],
        )
        (self.test_root / "build.sh").symlink_to(self.repo_root / "build.sh")
        self.project_root = self.test_root / "containers" / "test-svc"
        image_root = self.project_root / "test-svc"
        (self.project_root / "src").mkdir(parents=True)
        (image_root / "src").mkdir(parents=True)
        self.write_sources(
            "master upper-constraints "
            f"{self.upstream_requirements} master {self.requirements_old}\n"
            "master test-svc "
            f"{self.upstream_service} master {self.service_old}\n"
        )
        (image_root / "Containerfile").write_text(
            "FROM scratch\n", encoding="utf-8"
        )
        (image_root / "bindeps.txt").write_text("python3\n", encoding="utf-8")
        (image_root / "builddeps.txt").write_text("gcc\n", encoding="utf-8")
        (image_root / "pythondeps.txt").touch()
        (image_root / "pythonbuilddeps.txt").touch()

        self.additional_services = {}
        for name in ("test-svc2", "test-svc3"):
            remote = upstream_root / f"{name}.git"
            old, new = self.create_remote(
                remote,
                [
                    {"requirements.txt": "six\npbr\n"},
                    {"requirements.txt": "six\npbr\n# v2\n"},
                ],
            )
            self.additional_services[name] = (remote, old, new)
            self.create_project_fixture(name, remote, old)

        self.manifest_path = (
            self.test_root
            / ".tmp/source-maintenance/frozen-source-refs.master.tsv"
        )

    def run_command(self, command, cwd=None):
        result = subprocess.run(
            command,
            cwd=cwd,
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            self.fail(
                f"command failed with {result.returncode}: {command}\n"
                f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
            )
        return result.stdout.strip()

    def create_remote(self, destination, commits):
        work = self.test_root / f"work-{destination.stem}"
        self.run_command(["git", "init", "-b", "master", str(work)])
        self.run_command(
            ["git", "config", "user.email", "test@example.com"], work
        )
        self.run_command(["git", "config", "user.name", "Test"], work)
        self.run_command(["git", "config", "commit.gpgsign", "false"], work)
        hashes = []
        for index, files in enumerate(commits, start=1):
            for name, content in files.items():
                (work / name).write_text(content, encoding="utf-8")
            self.run_command(["git", "add", "-A"], work)
            self.run_command(["git", "commit", "-m", f"v{index}"], work)
            hashes.append(self.run_command(["git", "rev-parse", "HEAD"], work))
        self.run_command(
            ["git", "clone", "--bare", str(work), str(destination)]
        )
        return hashes[0], hashes[-1]

    def write_sources(self, content):
        (self.project_root / "sources.txt").write_text(
            content, encoding="utf-8"
        )

    def create_project_fixture(self, name, remote, pinned_hash):
        project_root = self.test_root / "containers" / name
        image_root = project_root / name
        (project_root / "src").mkdir(parents=True)
        (image_root / "src").mkdir(parents=True)
        (project_root / "sources.txt").write_text(
            "master upper-constraints "
            f"{self.upstream_requirements} master {self.requirements_old}\n"
            f"master {name} {remote} master {pinned_hash}\n",
            encoding="utf-8",
        )
        (image_root / "Containerfile").write_text(
            "FROM scratch\n", encoding="utf-8"
        )
        (image_root / "bindeps.txt").write_text("python3\n", encoding="utf-8")
        (image_root / "builddeps.txt").write_text("gcc\n", encoding="utf-8")
        (image_root / "pythondeps.txt").touch()
        (image_root / "pythonbuilddeps.txt").touch()

    def run_update_result(self, *targets, **environment):
        command_environment = os.environ.copy()
        command_environment.update({"STREAM": "master"})
        command_environment.update(environment)
        if not targets:
            targets = ("test-svc",)
        result = subprocess.run(
            ["bash", "./build.sh", "update-sources", *targets],
            cwd=self.test_root,
            check=False,
            capture_output=True,
            text=True,
            env=command_environment,
        )
        (self.test_root / "build.log").write_text(
            result.stdout + result.stderr, encoding="utf-8"
        )
        return result

    def run_update(self, *targets, **environment):
        result = self.run_update_result(*targets, **environment)
        if result.returncode != 0:
            self.fail(
                f"update-sources failed with {result.returncode}:\n"
                f"{result.stdout}{result.stderr}"
            )
        return result.stdout + result.stderr

    def manifest_for_stream(self, stream):
        filename = f"frozen-source-refs.{stream.replace('/', '%2F')}.tsv"
        return self.test_root / ".tmp/source-maintenance" / filename

    def manifest_rows(self):
        with self.manifest_path.open(encoding="utf-8", newline="") as stream:
            return list(csv.DictReader(stream, delimiter="\t"))

    def source_field(self, name, field, project_root=None):
        if project_root is None:
            project_root = self.project_root
        for line in (
            (project_root / "sources.txt")
            .read_text(encoding="utf-8")
            .splitlines()
        ):
            columns = line.split()
            if columns[:2] == ["master", name]:
                return columns[field - 1]
        self.fail(f"source entry was not found: {name}")

    def test_updates_hashes_to_frozen_branch_tips(self):
        self.run_update()

        self.assertEqual(
            self.requirements_new,
            self.source_field("upper-constraints", 5),
        )
        self.assertEqual(self.service_new, self.source_field("test-svc", 5))
        rows = self.manifest_rows()
        self.assertEqual(
            ["upper-constraints", "test-svc"], [row["name"] for row in rows]
        )
        self.assertEqual(
            [self.requirements_new, self.service_new],
            [row["frozen_commit"] for row in rows],
        )
        self.assertEqual({"declared-ref"}, {row["authority"] for row in rows})

    def test_fetches_upper_constraints(self):
        self.run_update()

        constraints = (
            self.project_root / "upper-constraints.txt.master"
        ).read_text(encoding="utf-8")
        self.assertIn("six==1.17.0", constraints)
        self.assertIn("pbr==7.0.3", constraints)

    def test_generates_rpms_in_yaml(self):
        self.run_update()

        rpms = (self.project_root / "rpms.in.yaml").read_text(encoding="utf-8")
        self.assertIn("python3", rpms)
        self.assertIn("gcc", rpms)

    def test_generates_requirements_lock(self):
        self.run_update()

        lock = (self.project_root / "requirements.lock.master").read_text(
            encoding="utf-8"
        )
        self.assertIn("six", lock)

    def test_generates_buildrequirements_lock(self):
        self.run_update()

        build_lock = self.project_root / "buildrequirements.lock.master"
        self.assertTrue(build_lock.is_file())
        self.assertNotIn("# via", build_lock.read_text(encoding="utf-8"))

    def test_creates_default_stream_symlinks(self):
        self.run_update(DEFAULT_STREAM="master")

        expected = {
            "upper-constraints.txt": "upper-constraints.txt.master",
            "requirements.lock": "requirements.lock.master",
            "buildrequirements.lock": "buildrequirements.lock.master",
        }
        for name, target in expected.items():
            link = self.project_root / name
            self.assertTrue(link.is_symlink())
            self.assertEqual(target, os.readlink(link))

    def test_skips_symlinks_for_non_default_stream(self):
        self.run_update(DEFAULT_STREAM="other")

        for name in (
            "upper-constraints.txt",
            "requirements.lock",
            "buildrequirements.lock",
        ):
            self.assertFalse((self.project_root / name).is_symlink())

    def test_skip_hash_update_preserves_and_records_committed_hashes(self):
        self.run_update(SKIP_HASH_UPDATE="1")

        self.assertEqual(
            self.requirements_old,
            self.source_field("upper-constraints", 5),
        )
        self.assertEqual(self.service_old, self.source_field("test-svc", 5))
        self.assertTrue(
            (self.project_root / "requirements.lock.master").is_file()
        )
        rows = self.manifest_rows()
        self.assertEqual(
            [self.requirements_old, self.service_old],
            [row["frozen_commit"] for row in rows],
        )
        self.assertEqual({"committed-pin"}, {row["authority"] for row in rows})

    def test_skip_hash_update_uses_pinned_constraints(self):
        self.run_update(SKIP_HASH_UPDATE="1")

        constraints = (
            self.project_root / "upper-constraints.txt.master"
        ).read_text(encoding="utf-8")
        self.assertIn("six==1.17.0", constraints)
        self.assertNotIn("pbr", constraints)

    def test_hash_in_branch_field_selects_constraints_commit(self):
        self.write_sources(
            "master upper-constraints "
            f"{self.upstream_requirements} {self.requirements_old} "
            f"{self.requirements_new}\n"
            "master test-svc "
            f"{self.upstream_service} master {self.service_old}\n"
        )

        self.run_update()

        self.assertEqual(
            self.requirements_old,
            self.source_field("upper-constraints", 5),
        )
        constraints = (
            self.project_root / "upper-constraints.txt.master"
        ).read_text(encoding="utf-8")
        self.assertIn("six==1.17.0", constraints)
        self.assertNotIn("pbr", constraints)

    def test_hash_in_branch_field_selects_regular_repo_commit(self):
        self.write_sources(
            "master upper-constraints "
            f"{self.upstream_requirements} master {self.requirements_old}\n"
            "master test-svc "
            f"{self.upstream_service} {self.service_old} "
            f"{self.service_new}\n"
        )

        self.run_update()

        self.assertEqual(self.service_old, self.source_field("test-svc", 5))
        self.assertTrue(
            (self.project_root / "requirements.lock.master").is_file()
        )

    def test_lockfile_excludes_rpm_python_packages(self):
        image_root = self.project_root / "test-svc"
        (image_root / "bindeps.txt").write_text(
            "python3\npython3-six\n", encoding="utf-8"
        )

        output = self.run_update()

        lock = (self.project_root / "requirements.lock.master").read_text(
            encoding="utf-8"
        )
        self.assertNotIn("six==", lock)
        self.assertIn("Filtering RPM-provided packages", output)

    def test_preexisting_checkout_is_preserved_and_recorded(self):
        source = self.project_root / "src" / "test-svc"
        self.run_command(
            ["git", "clone", str(self.upstream_service), str(source)]
        )
        (source / "MARKER").write_text("local-dev\n", encoding="utf-8")

        self.run_update()

        self.assertEqual(
            "local-dev\n",
            (source / "MARKER").read_text(encoding="utf-8"),
        )
        self.assertEqual(self.service_old, self.source_field("test-svc", 5))
        service_row = self.manifest_rows()[1]
        self.assertEqual("pre-existing-checkout", service_row["authority"])
        self.assertEqual(self.service_new, service_row["frozen_commit"])

    def test_unversioned_preexisting_source_fails_before_mutation(self):
        source = self.project_root / "src" / "test-svc"
        source.mkdir()
        (source / "requirements.txt").write_text("six\n", encoding="utf-8")
        original_sources = (self.project_root / "sources.txt").read_bytes()

        result = self.run_update_result()

        self.assertNotEqual(0, result.returncode)
        self.assertIn("is not a Git checkout", result.stderr)
        self.assertEqual(
            original_sources, (self.project_root / "sources.txt").read_bytes()
        )
        self.assertFalse(
            (self.project_root / "upper-constraints.txt.master").exists()
        )
        self.assertFalse(self.manifest_path.exists())

    def test_slash_stream_uses_safe_manifest_filename(self):
        result = self.run_update_result(STREAM="stable/test")

        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        manifest = self.manifest_for_stream("stable/test")
        self.assertTrue(manifest.is_file())
        self.assertEqual(
            self.test_root / ".tmp/source-maintenance", manifest.parent
        )
        self.assertFalse(
            (self.test_root / ".tmp/source-maintenance/stable").exists()
        )

    def test_unsafe_stream_fails_before_filesystem_mutation(self):
        original_sources = (self.project_root / "sources.txt").read_bytes()

        result = self.run_update_result(STREAM="../../escape")

        self.assertNotEqual(0, result.returncode)
        self.assertIn("Unsafe stream name", result.stderr)
        self.assertEqual(
            original_sources, (self.project_root / "sources.txt").read_bytes()
        )
        self.assertFalse((self.test_root / ".tmp").exists())

    def test_unresolvable_ref_fails_before_mutation(self):
        self.write_sources(
            "master upper-constraints "
            f"{self.upstream_requirements} master {self.requirements_old}\n"
            "master test-svc "
            f"{self.upstream_service} missing-branch {self.service_old}\n"
        )
        original_sources = (self.project_root / "sources.txt").read_bytes()

        result = self.run_update_result()

        self.assertNotEqual(0, result.returncode)
        self.assertIn("Could not freeze ref 'missing-branch'", result.stderr)
        self.assertEqual(
            original_sources, (self.project_root / "sources.txt").read_bytes()
        )
        self.assertFalse(
            (self.project_root / "upper-constraints.txt.master").exists()
        )
        self.assertFalse(self.manifest_path.exists())

    def test_failed_preflight_removes_stale_manifest(self):
        self.run_update()
        self.assertTrue(self.manifest_path.is_file())
        self.write_sources(
            "master upper-constraints "
            f"{self.upstream_requirements} master {self.requirements_new}\n"
            "master test-svc "
            f"{self.upstream_service} missing-branch {self.service_new}\n"
        )

        result = self.run_update_result()

        self.assertNotEqual(0, result.returncode)
        self.assertFalse(self.manifest_path.exists())

    def test_list_discovers_all_projects(self):
        result = subprocess.run(
            ["bash", "./build.sh", "list"],
            cwd=self.test_root,
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("test-svc/test-svc", result.stdout)
        self.assertIn("test-svc2/test-svc2", result.stdout)
        self.assertIn("test-svc3/test-svc3", result.stdout)

    def test_multiple_targets_update_only_selected_projects(self):
        self.run_update("test-svc", "test-svc2", DEFAULT_STREAM="master")

        service2_new = self.additional_services["test-svc2"][2]
        service3_old = self.additional_services["test-svc3"][1]
        project2 = self.test_root / "containers/test-svc2"
        project3 = self.test_root / "containers/test-svc3"
        self.assertEqual(self.service_new, self.source_field("test-svc", 5))
        self.assertEqual(
            service2_new,
            self.source_field("test-svc2", 5, project2),
        )
        self.assertEqual(
            service3_old,
            self.source_field("test-svc3", 5, project3),
        )
        for project in (self.project_root, project2):
            self.assertTrue(
                (project / "upper-constraints.txt.master").is_file()
            )
            self.assertTrue((project / "requirements.lock.master").is_file())
            self.assertTrue((project / "rpms.in.yaml").is_file())
            self.assertTrue((project / "requirements.lock").is_symlink())
        self.assertFalse((project3 / "upper-constraints.txt.master").exists())
        self.assertFalse((project3 / "requirements.lock.master").exists())
        self.assertFalse((project3 / "rpms.in.yaml").exists())

    def test_single_target_does_not_affect_other_projects(self):
        self.run_update("test-svc")

        project2 = self.test_root / "containers/test-svc2"
        self.assertEqual(
            self.additional_services["test-svc2"][1],
            self.source_field("test-svc2", 5, project2),
        )
        self.assertFalse((project2 / "requirements.lock.master").exists())

    def test_all_updates_every_project(self):
        self.run_update("all")

        self.assertEqual(self.service_new, self.source_field("test-svc", 5))
        for name in ("test-svc2", "test-svc3"):
            project = self.test_root / "containers" / name
            self.assertEqual(
                self.additional_services[name][2],
                self.source_field(name, 5, project),
            )
            self.assertTrue((project / "requirements.lock.master").is_file())

    def test_unknown_target_fails_before_mutation(self):
        result = self.run_update_result("nonexistent")

        self.assertNotEqual(0, result.returncode)
        self.assertIn("ERROR: Unknown image or project", result.stderr)
        self.assertFalse(self.manifest_path.exists())

    def test_duplicate_ref_records_retain_deterministic_rows(self):
        image_sources = self.project_root / "test-svc" / "sources.txt"
        image_sources.write_text(
            "master helper "
            f"{self.upstream_service} master {self.service_old}\n",
            encoding="utf-8",
        )

        self.run_update()

        rows = self.manifest_rows()
        self.assertEqual(
            ["upper-constraints", "test-svc", "helper"],
            [row["name"] for row in rows],
        )
        self.assertEqual(rows[1]["frozen_commit"], rows[2]["frozen_commit"])


if __name__ == "__main__":
    unittest.main()
