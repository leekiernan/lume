#!/usr/bin/env python3
"""Exercise explicit target retirement and upstream replay without writing files."""
import importlib.util
import json
import sys
import unittest

from pathlib import Path

spec = importlib.util.spec_from_file_location("fork_project", Path(__file__).with_name("fork-project.py"))
sys.dont_write_bytecode = True
fork_project = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fork_project)


class TargetRetirementTests(unittest.TestCase):
    def setUp(self):
        self.overrides = json.loads(fork_project.OVERRIDES.read_text())
        self.upstream = fork_project.git_show("upstream/main")

    def test_replay_matches_working_project(self):
        self.assertEqual(fork_project.apply(self.upstream, self.overrides), fork_project.PROJECT.read_text())

    def test_removal_is_idempotent_and_has_no_dangling_references(self):
        ids = self.overrides["removedObjects"]
        removed = fork_project.remove_objects(self.upstream, ids)
        self.assertEqual(fork_project.remove_objects(removed, ids), removed)
        self.assertNotIn("LumeWidgets", removed)
        for object_id in ids:
            self.assertNotIn(object_id, removed)

    def test_other_targets_and_configurations_survive(self):
        removed = fork_project.remove_objects(self.upstream, self.overrides["removedObjects"])
        configs = fork_project.configs(self.upstream)
        expected = set(configs) - set(self.overrides["removedObjects"])
        self.assertEqual(set(fork_project.configs(removed)), expected)
        self.assertIn("LumePerformanceTests", removed)
        self.assertIn("LumeUITests", removed)

    def test_unknown_scalar_reference_is_rejected(self):
        object_id = self.overrides["removedObjects"][0]
        with self.assertRaises(ValueError):
            fork_project.remove_objects(f"\t\t\tproductReference = {object_id};\n", [object_id])

    def test_invalid_ids_are_rejected(self):
        with self.assertRaises(ValueError):
            fork_project.remove_objects(self.upstream, [".*"])

    def test_local_package_override_is_idempotent(self):
        url = "https://github.com/kingslay/KSPlayer"
        local = fork_project.localize_package(self.upstream, url, "Dependencies/KSPlayer")
        self.assertEqual(fork_project.localize_package(local, url, "Dependencies/KSPlayer"), local)
        self.assertNotIn(url, local)
        self.assertIn("relativePath = Dependencies/KSPlayer;", local)
        self.assertIn("productName = KSPlayer;", local)

    def test_missing_remote_is_rejected(self):
        with self.assertRaises(ValueError):
            fork_project.localize_package(self.upstream, "https://invalid.example/Absent", "Dependencies/Absent")

    def test_root_local_override_is_idempotent_and_keeps_other_packages(self):
        path, object_id = "Dependencies/FFmpegBuild", "C6DD5101000000000000AB01"
        local = fork_project.add_local_package(self.upstream, path, object_id)
        self.assertEqual(fork_project.add_local_package(local, path, object_id), local)
        self.assertEqual(local.count(object_id), 2)
        self.assertIn("relativePath = Dependencies/FFmpegBuild;", local)
        self.assertIn("https://code.videolan.org/videolan/VLCKit.git", local)

    def test_missing_package_sections_are_rejected(self):
        with self.assertRaises(ValueError):
            fork_project.add_local_package("", "Dependencies/FFmpegBuild", "C6DD5101000000000000AB01")


if __name__ == "__main__":
    unittest.main()
