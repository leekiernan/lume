#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location(
    "check_playback_dependencies", Path(__file__).with_name("check-playback-dependencies.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

MANIFEST = '''
    dependencies: [
        .package(url: "https://github.com/superuser404notfound/FFmpegBuild", .upToNextMinor(from: "3.15.0")),  // 3.15.0: notes
        .package(url: "https://github.com/kishikawakatsumi/SMBClient", .upToNextMinor(from: "0.3.1")),
        .package(url: "https://github.com/superuser404notfound/LibDovi.git", from: "2.2.0"),
    ],
'''


def lock(ffmpeg="3.15.0", dovi="2.2.0"):
    return {"packages": [
        {"name": "KSPlayer", "url": "https://github.com/kingslay/KSPlayer", "version": "be7f60d3"},
        {"name": "FFmpegBuild", "url": "https://github.com/superuser404notfound/FFmpegBuild", "version": ffmpeg},
        {"name": "LibDovi", "url": "https://github.com/superuser404notfound/LibDovi", "version": dovi},
    ]}


class CheckTests(unittest.TestCase):
    def test_matching_versions_pass(self):
        checked, problems = module.check(lock(), {"Aether": MANIFEST})
        self.assertEqual(checked, ["FFmpegBuild for Aether", "LibDovi for Aether"])
        self.assertEqual(problems, [])

    def test_an_engine_raising_its_minor_is_caught(self):
        _, problems = module.check(lock(), {"Aether": MANIFEST.replace('from: "3.15.0"', 'from: "3.16.0"')})
        self.assertEqual(len(problems), 1)
        self.assertIn("FFmpegBuild 3.15.0", problems[0])

    def test_a_newer_patch_is_allowed_but_not_a_newer_minor(self):
        self.assertEqual(module.check(lock(ffmpeg="3.15.2"), {"Aether": MANIFEST})[1], [])
        self.assertEqual(len(module.check(lock(ffmpeg="3.16.0"), {"Aether": MANIFEST})[1]), 1)

    def test_requirement_forms(self):
        self.assertTrue(module.satisfies("2.9.0", 'from: "2.2.0"'))
        self.assertFalse(module.satisfies("3.0.0", '.upToNextMajor(from: "2.2.0")'))
        self.assertTrue(module.satisfies("1.2.3", 'exact: "1.2.3"'))
        self.assertTrue(module.satisfies("1.4.0", '"1.2.0"..<"1.5.0"'))
        with self.assertRaises(ValueError):
            module.satisfies("1.0.0", 'branch: "main"')


if __name__ == "__main__":
    unittest.main()
