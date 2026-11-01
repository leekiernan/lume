#!/usr/bin/env python3
"""Bump the fork's version after merging a branch into main.

Run on main, right after `git merge --no-ff <branch>`:

  Scripts/bump-version.py              # bump for the merge at HEAD
  Scripts/bump-version.py --dry-run    # print the bump, change nothing
  Scripts/bump-version.py --level minor   # override the computed level

The level is semantic versioning, read from the merged branch's commits
(conventional commit subjects, the merge's second parent back to its first):

  major   a breaking change: `type!:` or a `BREAKING CHANGE:` footer
  minor   any `feat` commit
  patch   anything else (`fix`, `perf`, `refactor`, `chore`, `docs`, …)

A branch with no conventional commits falls back to its name: `feat/` is
minor, anything else patch. Every bump also adds one to the build number.

MARKETING_VERSION and CURRENT_PROJECT_VERSION are written to every build
configuration that carries them, and recorded in
Scripts/fork-project-overrides.json, so an upstream project-file intake keeps
the fork's numbering instead of taking upstream's. Then the two files are
committed as `chore(release): <version> (<build>)`.
"""

import argparse
import importlib.machinery
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "Lume.xcodeproj" / "project.pbxproj"
OVERRIDES = ROOT / "Scripts" / "fork-project-overrides.json"
VERSION_KEY = "MARKETING_VERSION"
BUILD_KEY = "CURRENT_PROJECT_VERSION"
LEVELS = ("patch", "minor", "major")

# `type(scope)!: subject`
SUBJECT = re.compile(r"^(?P<type>[a-z]+)(?:\([^)]*\))?(?P<bang>!)?: ")

sys.dont_write_bytecode = True  # loading fork-project.py must not leave a __pycache__
fork_project = importlib.machinery.SourceFileLoader(
    "fork_project", str(ROOT / "Scripts" / "fork-project.py")
).load_module()


def git(*args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(ROOT), *args], check=True, capture_output=True, text=True
    ).stdout.strip()


def merged_branch() -> tuple[str, list[tuple[str, str]]]:
    """The branch merged at HEAD and its commits as (subject, body) pairs."""
    parents = git("rev-list", "--parents", "-n", "1", "HEAD").split()
    if len(parents) != 3:
        sys.exit("bump-version: HEAD is not a merge commit — run it right after `git merge --no-ff`")
    subject = git("log", "-1", "--format=%s", "HEAD")
    match = re.search(r"Merge branch '([^']+)'", subject)
    branch = match.group(1) if match else ""
    log = git("log", "--format=%s%x1f%b%x1e", f"{parents[1]}..{parents[2]}")
    commits = []
    for entry in log.split("\x1e"):
        if entry.strip():
            subject, _, body = entry.strip().partition("\x1f")
            commits.append((subject, body))
    return branch, commits


def level_for(branch: str, commits: list[tuple[str, str]]) -> str:
    level = None
    for subject, body in commits:
        match = SUBJECT.match(subject)
        if not match:
            continue
        if match["bang"] or "BREAKING CHANGE:" in body:
            return "major"
        found = "minor" if match["type"] == "feat" else "patch"
        if level is None or LEVELS.index(found) > LEVELS.index(level):
            level = found
    if level:
        return level
    return "minor" if branch.startswith("feat/") else "patch"


def bumped(version: str, level: str) -> str:
    parts = [int(p) for p in version.split(".")]
    major, minor, patch = (parts + [0, 0, 0])[:3]
    if level == "major":
        return f"{major + 1}.0.0"
    if level == "minor":
        return f"{major}.{minor + 1}.0"
    return f"{major}.{minor}.{patch + 1}"


def current(text: str, overrides: dict, key: str) -> str:
    """The fork's value for `key`. A target taken from upstream can carry
    upstream's numbering until its first bump, so a value already recorded in
    the overrides wins over what the project file shows."""
    recorded = {c[key].rstrip(";") for c in overrides.get("configurations", {}).values() if key in c}
    values = recorded or set(re.findall(rf"^\t+{key} = ([^;\n]+);$", text, re.M))
    if len(values) != 1:
        sys.exit(f"bump-version: expected one {key}, found {sorted(values)}")
    return values.pop()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--level", choices=LEVELS, help="override the computed level")
    parser.add_argument("--dry-run", action="store_true", help="print the bump without changing anything")
    args = parser.parse_args()

    branch, commits = merged_branch()
    level = args.level or level_for(branch, commits)
    text = PROJECT.read_text()
    overrides = json.loads(OVERRIDES.read_text())
    version, build = current(text, overrides, VERSION_KEY), current(text, overrides, BUILD_KEY)
    new_version, new_build = bumped(version, level), str(int(build) + 1)
    print(f"{branch or 'merge'}: {level} — {version} ({build}) → {new_version} ({new_build})")
    if args.dry_run:
        return

    text = re.sub(rf"^(\t+{VERSION_KEY} = )[^;\n]+;$", rf"\g<1>{new_version};", text, flags=re.M)
    text = re.sub(rf"^(\t+{BUILD_KEY} = )[^;\n]+;$", rf"\g<1>{new_build};", text, flags=re.M)
    PROJECT.write_text(text)

    configurations = overrides.setdefault("configurations", {})
    for config_id, config in fork_project.configs(text).items():
        if VERSION_KEY in config or BUILD_KEY in config:
            entry = configurations.setdefault(config_id, {})
            entry[VERSION_KEY] = f"{new_version};"
            entry[BUILD_KEY] = f"{new_build};"
    OVERRIDES.write_text(json.dumps(overrides, indent=2) + "\n")

    git("add", str(PROJECT), str(OVERRIDES))
    git("commit", "-m", f"chore(release): {new_version} ({new_build})")
    print(f"committed chore(release): {new_version} ({new_build})")


if __name__ == "__main__":
    main()
