#!/usr/bin/env python3
"""Fail when a local playback package no longer satisfies the packages using it.

FFmpegKit, FFmpegBuild and LibDovi are local packages that replace KSPlayer's
and AetherEngine's same-identity dependencies. A local package carries no
version, so SwiftPM never compares it with their requirements: after an engine
upgrade the old binaries would build silently. This compares the versions in
Scripts/playback-dependencies.json with the requirements in AetherEngine's
manifest (at the version LumeAetherBridge pins) and in every fetched package's
manifest under Dependencies/.

Uses Python 3.9+ (Xcode's /usr/bin/python3 is enough).
"""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import urllib.request


ROOT = Path(__file__).resolve().parent.parent
LOCK = ROOT / "Scripts/playback-dependencies.json"
BRIDGE = ROOT / "LumeAetherBridge/Package.swift"
AETHER = "https://github.com/superuser404notfound/AetherEngine"
CHECKOUT = Path.home() / "Library/Developer/Lume-SharedSPM/checkouts/AetherEngine"
DEPENDENCY = re.compile(r'\.package\(\s*url:\s*"(?P<url>[^"]+)"\s*,\s*(?P<requirement>[^\n]*?)\)\s*,?\s*(?://|$)', re.M)
VERSION = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")


def parse_version(text):
    match = VERSION.match(text)
    if not match:
        raise ValueError(f"Not a semantic version: {text}")
    return tuple(int(part) for part in match.groups())


def normalize(url):
    return url.lower().removesuffix("/").removesuffix(".git")


def satisfies(version, requirement):
    """Evaluate the SwiftPM requirement forms Aether uses."""
    found = parse_version(version)
    if match := re.fullmatch(r'\.upToNextMinor\(from:\s*"([^"]+)"\)', requirement):
        low = parse_version(match[1])
        return low <= found < (low[0], low[1] + 1, 0)
    if match := re.fullmatch(r'(?:\.upToNextMajor\()?from:\s*"([^"]+)"\)?', requirement):
        low = parse_version(match[1])
        return low <= found < (low[0] + 1, 0, 0)
    if match := re.fullmatch(r'(?:\.exact\(|exact:\s*)"([^"]+)"\)?', requirement):
        return found == parse_version(match[1])
    if match := re.fullmatch(r'"([^"]+)"\s*\.\.<\s*"([^"]+)"', requirement):
        return parse_version(match[1]) <= found < parse_version(match[2])
    raise ValueError(f"Unsupported requirement: {requirement}")


def requirements(manifest):
    return {normalize(match["url"]): match["requirement"].strip() for match in DEPENDENCY.finditer(manifest)}


def pinned_aether_version():
    match = re.search(rf'\.package\(url:\s*"{re.escape(AETHER)}"\s*,\s*exact:\s*"([^"]+)"\)', BRIDGE.read_text())
    if not match:
        raise ValueError("LumeAetherBridge no longer pins AetherEngine exactly")
    return match[1]


def aether_manifest(version):
    """Prefer the shared package checkout; fetch the pinned tag otherwise."""
    tag = subprocess.run(["git", "-C", str(CHECKOUT), "describe", "--tags", "--exact-match"],
                         capture_output=True, text=True)
    if tag.returncode == 0 and tag.stdout.strip() == version:
        return (CHECKOUT / "Package.swift").read_text()
    url = AETHER.replace("github.com", "raw.githubusercontent.com") + f"/{version}/Package.swift"
    with urllib.request.urlopen(url, timeout=30) as response:
        return response.read().decode()


def check(lock, manifests):
    """`manifests` maps a dependent's name to its Package.swift text."""
    problems, checked = [], []
    for dependent, manifest in manifests.items():
        wanted = requirements(manifest)
        for package in lock["packages"]:
            requirement = wanted.get(normalize(package["url"]))
            if requirement is None:
                continue
            checked.append(f"{package['name']} for {dependent}")
            if not satisfies(package["version"], requirement):
                problems.append(f"{package['name']} {package['version']} does not satisfy {dependent}'s {requirement}")
    return checked, problems


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    version = pinned_aether_version()
    lock = json.loads(LOCK.read_text())
    manifests = {f"AetherEngine {version}": aether_manifest(version)}
    for package in lock["packages"]:
        manifest = ROOT / "Dependencies" / package["name"] / "Package.swift"
        if manifest.is_file():
            manifests[package["name"]] = manifest.read_text()
    checked, problems = check(lock, manifests)
    for problem in problems:
        print(f"check-playback-dependencies: {problem}", file=sys.stderr)
    if problems:
        print("Update Scripts/playback-dependencies.json and Dependencies/ (see Dependencies/README.md).",
              file=sys.stderr)
        return 1
    print(f"check-playback-dependencies: satisfied: {', '.join(checked)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
