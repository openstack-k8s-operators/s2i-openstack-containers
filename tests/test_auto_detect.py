"""Tests for build.sh auto-detect and list-sources commands."""

import os
import pathlib
import subprocess
import unittest

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
BUILD_SH = REPO_ROOT / "build.sh"
CONTAINERS_DIR = REPO_ROOT / "containers"


def _run_build_sh(command: str, *args: str) -> subprocess.CompletedProcess:
    env = {**os.environ, "PARALLEL": "1"}
    return subprocess.run(
        ["bash", str(BUILD_SH), command, *args],
        capture_output=True,
        text=True,
        cwd=str(REPO_ROOT),
        env=env,
        timeout=30,
    )


def _run_auto_detect(*args: str) -> subprocess.CompletedProcess:
    return _run_build_sh("auto-detect", *args)


def _sources_txt_projects() -> dict[str, list[str]]:
    """Parse all sources.txt to build a map of canonical_project -> images."""
    result: dict[str, set[str]] = {}
    for sources_file in sorted(CONTAINERS_DIR.rglob("sources.txt")):
        rel = sources_file.relative_to(CONTAINERS_DIR)
        project_name = str(rel).split("/")[0]

        for line in sources_file.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            fields = line.split()
            if len(fields) < 4:
                continue
            _stream, name, url, *_ = fields
            if name == "upper-constraints":
                continue
            url_path = url.split("://", 1)[-1] if "://" in url else url
            url_path = url_path.split("/", 1)[-1] if "/" in url_path else ""
            url_path = url_path.removesuffix(".git")
            if not url_path:
                continue
            result.setdefault(url_path, set())
            # Find actual image targets under this project
            for containerfile in CONTAINERS_DIR.glob(
                f"{project_name}/*/Containerfile"
            ):
                image = (
                    f"{project_name}/{containerfile.parent.name}"
                )
                result[url_path].add(image)
            if project_name == "base" and (
                CONTAINERS_DIR / "base" / "Containerfile"
            ).exists():
                result[url_path].add("base")
    return {k: sorted(v) for k, v in result.items()}


class TestAutoDetect(unittest.TestCase):
    def test_exact_project_match(self):
        proc = _run_auto_detect("openstack/tempest")
        self.assertEqual(proc.returncode, 0)
        images = proc.stdout.strip().splitlines()
        self.assertIn("tempest/tempest", images)

    def test_no_false_positives_for_substring(self):
        """openstack/watcher should NOT match openstack/watcher-tempest-plugin."""
        proc = _run_auto_detect("openstack/watcher")
        self.assertEqual(proc.returncode, 0)
        images = proc.stdout.strip().splitlines()
        self.assertNotIn("tempest/tempest", images)
        self.assertIn("watcher/watcher-base", images)

    def test_full_url_form(self):
        proc = _run_auto_detect(
            "https://opendev.org/openstack/tempest.git"
        )
        self.assertEqual(proc.returncode, 0)
        images = proc.stdout.strip().splitlines()
        self.assertIn("tempest/tempest", images)

    def test_unknown_project_fails(self):
        proc = _run_auto_detect("openstack/nonexistent-project")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("no images reference", proc.stderr)

    def test_empty_arg_fails(self):
        proc = _run_auto_detect("")
        self.assertNotEqual(proc.returncode, 0)

    def test_no_arg_fails(self):
        env = {**os.environ, "PARALLEL": "1"}
        proc = subprocess.run(
            ["bash", str(BUILD_SH), "auto-detect"],
            capture_output=True,
            text=True,
            cwd=str(REPO_ROOT),
            env=env,
            timeout=30,
        )
        self.assertNotEqual(proc.returncode, 0)

    def test_multi_image_project(self):
        """Projects like neutron should return multiple images."""
        proc = _run_auto_detect("openstack/neutron")
        self.assertEqual(proc.returncode, 0)
        images = proc.stdout.strip().splitlines()
        self.assertGreater(len(images), 1)
        for img in images:
            self.assertTrue(
                img.startswith("neutron/"),
                f"Expected neutron/ prefix, got: {img}",
            )

    def test_sub_image_sources(self):
        """networking-baremetal is in sub-image sources.txt files."""
        proc = _run_auto_detect("openstack/networking-baremetal")
        self.assertEqual(proc.returncode, 0)
        images = proc.stdout.strip().splitlines()
        self.assertIn("neutron/ironic-neutron-agent", images)
        self.assertIn("neutron/neutron-server", images)

    def test_consistency_with_sources_txt(self):
        """Every project in sources.txt should be detectable."""
        project_map = _sources_txt_projects()
        for project, expected_images in project_map.items():
            with self.subTest(project=project):
                proc = _run_auto_detect(project)
                self.assertEqual(
                    proc.returncode,
                    0,
                    f"auto-detect failed for {project}: {proc.stderr}",
                )
                detected = sorted(proc.stdout.strip().splitlines())
                self.assertEqual(
                    detected,
                    expected_images,
                    f"Mismatch for {project}",
                )


class TestListSources(unittest.TestCase):
    """Tests for build.sh list-sources command."""

    def test_returns_pipe_delimited_records(self):
        proc = _run_build_sh("list-sources", "watcher/watcher-base", "master")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        lines = proc.stdout.strip().splitlines()
        self.assertGreater(len(lines), 0)
        for line in lines:
            fields = line.split("|")
            self.assertEqual(
                len(fields),
                4,
                f"Expected 4 pipe-delimited fields, got: {line}",
            )
            name, canonical, url, dest = fields
            self.assertTrue(name, "name field is empty")
            self.assertTrue(canonical, "canonical_project field is empty")
            self.assertTrue(url.startswith("https://"), f"unexpected url: {url}")
            self.assertIn("/src/", dest, f"dest should contain /src/: {dest}")

    def test_excludes_upper_constraints(self):
        proc = _run_build_sh("list-sources", "watcher/watcher-base", "master")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        for line in proc.stdout.strip().splitlines():
            name = line.split("|")[0]
            self.assertNotEqual(name, "upper-constraints")

    def test_no_target_fails(self):
        proc = _run_build_sh("list-sources")
        self.assertNotEqual(proc.returncode, 0)

    def test_tempest_includes_plugins(self):
        proc = _run_build_sh("list-sources", "tempest/tempest", "master")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        names = [line.split("|")[0] for line in proc.stdout.strip().splitlines()]
        self.assertIn("tempest", names)
        plugin_count = sum(1 for n in names if "tempest-plugin" in n)
        self.assertGreater(
            plugin_count, 0, "tempest/tempest should include tempest plugins"
        )

    def test_sub_image_sources_merge(self):
        """list-sources for a sub-image should include project-level sources."""
        proc = _run_build_sh(
            "list-sources", "neutron/ironic-neutron-agent", "master"
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        names = [line.split("|")[0] for line in proc.stdout.strip().splitlines()]
        self.assertIn("neutron", names, "project-level source should be included")
        self.assertIn(
            "networking-baremetal",
            names,
            "sub-image source should be included",
        )

    def test_dest_paths_point_to_project_src(self):
        proc = _run_build_sh("list-sources", "watcher/watcher-base", "master")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        for line in proc.stdout.strip().splitlines():
            dest = line.split("|")[3]
            self.assertIn(
                "/containers/watcher/src/",
                dest,
                f"dest should be under project's src/: {dest}",
            )

    def test_stream_filter(self):
        """Passing a non-existent stream should return nothing."""
        proc = _run_build_sh(
            "list-sources", "watcher/watcher-base", "nonexistent-stream"
        )
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout.strip(), "")


if __name__ == "__main__":
    unittest.main()
