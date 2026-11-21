#!/usr/bin/env python3
import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest


spec = importlib.util.spec_from_file_location("playback_packages", Path(__file__).with_name("playback-packages.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

POLICY = {"architectures": ["arm64"], "platforms": ["ios", "macos"], "variants": [None, "simulator"]}


def compile_object(folder, arch):
    source = folder / "f.c"
    source.write_text("int lume_value(void) { return 42; }\n")
    output = folder / f"f-{arch}.o"
    subprocess.run(["clang", "-arch", arch, "-c", str(source), "-o", str(output)], check=True)
    return output


class PathSafetyTests(unittest.TestCase):
    def test_archive_members_cannot_escape(self):
        for name in ("/etc/passwd", "../x", "a/../../x", ""):
            with self.assertRaises(ValueError):
                module.safe_relative(name)
        self.assertEqual(module.safe_relative("Sources/a.h"), Path("Sources/a.h"))

    def test_symlinks_must_stay_inside(self):
        module.safe_link("A.framework/Headers", "Versions/Current/Headers")
        for target in ("/usr/lib", "../../outside"):
            with self.assertRaises(ValueError):
                module.safe_link("A.framework/Headers", target)

    def test_path_filter(self):
        self.assertTrue(module.wanted("Sources/x.swift", ["Sources"]))
        self.assertFalse(module.wanted("SourcesExtra/x", ["Sources"]))
        self.assertTrue(module.wanted("anything", []))


class ManifestTests(unittest.TestCase):
    def test_only_the_pinned_binary_url_is_rewritten(self):
        with tempfile.TemporaryDirectory() as folder:
            manifest = Path(folder) / "Package.swift"
            manifest.write_text('.binaryTarget(\n  name: "VLCKit",\n  url: "https://v/x.zip",\n  checksum: "ab"\n)\n')
            binaries = {"VLCKit.xcframework": {"target": "VLCKit", "url": "https://v/x.zip"}}
            module.point_manifest_at_local_binaries(manifest, binaries)
            self.assertIn('name: "VLCKit",\n  path: "VLCKit.xcframework"\n)', manifest.read_text())
            with self.assertRaises(ValueError):
                module.point_manifest_at_local_binaries(manifest, binaries)

    def test_a_changed_upstream_url_is_refused(self):
        with tempfile.TemporaryDirectory() as folder:
            manifest = Path(folder) / "Package.swift"
            manifest.write_text('.binaryTarget(name: "VLCKit", url: "https://v/new.zip", checksum: "ab")')
            with self.assertRaises(ValueError):
                module.point_manifest_at_local_binaries(
                    manifest, {"VLCKit.xcframework": {"target": "VLCKit", "url": "https://v/old.zip"}})


class TreeHashTests(unittest.TestCase):
    def test_hash_covers_content_mode_and_links(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "a").write_text("1")
            base = module.tree_sha256(root)
            self.assertEqual(base, module.tree_sha256(root))
            (root / "a").chmod(0o755)
            executable = module.tree_sha256(root)
            self.assertNotEqual(base, executable)
            os.symlink("a", root / "b")
            self.assertNotEqual(executable, module.tree_sha256(root))


class ThinningTests(unittest.TestCase):
    def test_xcframework_keeps_supported_arm64_slices_byte_for_byte(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            arm, intel = compile_object(root, "arm64"), compile_object(root, "x86_64")
            framework = root / "pkg/Sources/F.xcframework"
            libraries = []
            for identifier, platform, variant in (("macos-arm64_x86_64", "macos", None),
                                                  ("watchos-arm64", "watchos", None),
                                                  ("ios-arm64_x86_64-maccatalyst", "ios", "maccatalyst")):
                slice_folder = framework / identifier
                (slice_folder / "dSYMs").mkdir(parents=True)
                subprocess.run(["lipo", "-create", str(arm), str(intel), "-output", str(slice_folder / "libF.o")],
                               check=True)
                library = {"LibraryIdentifier": identifier, "LibraryPath": "libF.o", "SupportedPlatform": platform,
                           "SupportedArchitectures": ["arm64", "x86_64"]}
                if variant:
                    library["SupportedPlatformVariant"] = variant
                libraries.append(library)
            (framework / "Info.plist").write_bytes(plistlib.dumps({"AvailableLibraries": libraries}))
            (framework / "_CodeSignature").mkdir()

            symbols = module.thin_xcframework(framework, root / "pkg", POLICY)

            self.assertEqual(symbols, [])
            self.assertEqual(sorted(p.name for p in framework.iterdir()), ["Info.plist", "macos-arm64_x86_64"])
            kept = framework / "macos-arm64_x86_64/libF.o"
            self.assertEqual(kept.read_bytes(), arm.read_bytes())
            info = plistlib.loads((framework / "Info.plist").read_bytes())
            self.assertEqual([l["SupportedArchitectures"] for l in info["AvailableLibraries"]], [["arm64"]])

    def test_an_untouched_platform_keeps_its_device_slice_whole(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            arm, intel = compile_object(root, "arm64"), compile_object(root, "x86_64")
            framework = root / "H.xcframework"
            libraries = []
            for identifier, variant in (("macos-arm64_x86_64", None), ("ios-arm64_x86_64-simulator", "simulator")):
                platform = "macos" if variant is None else "ios"
                (framework / identifier).mkdir(parents=True)
                subprocess.run(["lipo", "-create", str(arm), str(intel), "-output",
                                str(framework / identifier / "libH.o")], check=True)
                library = {"LibraryIdentifier": identifier, "LibraryPath": "libH.o", "SupportedPlatform": platform,
                           "SupportedArchitectures": ["arm64", "x86_64"]}
                if variant:
                    library["SupportedPlatformVariant"] = variant
                libraries.append(library)
            (framework / "Info.plist").write_bytes(plistlib.dumps({"AvailableLibraries": libraries}))
            universal = (framework / "macos-arm64_x86_64/libH.o").read_bytes()

            module.thin_xcframework(framework, root, POLICY, untouched_platforms=["macos"])

            self.assertEqual((framework / "macos-arm64_x86_64/libH.o").read_bytes(), universal)
            self.assertEqual((framework / "ios-arm64_x86_64-simulator/libH.o").read_bytes(), arm.read_bytes())
            info = plistlib.loads((framework / "Info.plist").read_bytes())
            self.assertEqual([l["SupportedArchitectures"] for l in info["AvailableLibraries"]],
                             [["arm64", "x86_64"], ["arm64"]])

    def test_a_slice_without_arm64_is_dropped_and_an_empty_framework_refused(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            framework = root / "G.xcframework"
            (framework / "ios-x86_64-simulator").mkdir(parents=True)
            library = {"LibraryIdentifier": "ios-x86_64-simulator", "LibraryPath": "libG.o",
                       "SupportedPlatform": "ios", "SupportedPlatformVariant": "simulator",
                       "SupportedArchitectures": ["x86_64"]}
            (framework / "Info.plist").write_bytes(plistlib.dumps({"AvailableLibraries": [library]}))
            with self.assertRaises(ValueError):
                module.thin_xcframework(framework, root, POLICY)


if __name__ == "__main__":
    unittest.main()
