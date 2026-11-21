#!/usr/bin/env python3
"""Keep the fork's project.pbxproj a pure function of upstream's.

The fork's project-file changes are mechanical: signing identity (team,
bundle ids, signing style), Xcode's recommended settings, explicitly retired
target objects and package requirements pinned differently from upstream. Carried as a diff,
they sit next to the version lines, so every upstream version bump conflicts.
Carried as data, an upstream project change is taken whole and the overrides
re-applied — no hand-merging.

  Scripts/fork-project.py capture [--base <rev>]
      Record how the working project file differs from <rev>'s (default
      upstream/main) into Scripts/fork-project-overrides.json. Run after a
      deliberate fork change to the project (e.g. accepting a new Xcode
      recommended setting), then commit both files.

  Scripts/fork-project.py apply [--from <rev>]
      Rewrite the working project file as <rev>'s (default: keep the working
      file) with the overrides applied. Idempotent.

  Scripts/fork-project.py check [--base <rev>]
      Exit non-zero unless applying the overrides to <rev>'s project file
      reproduces the working file exactly.

Upstream intake: when a cherry-pick conflicts in project.pbxproj,
  Scripts/fork-project.py apply --from <upstream-commit>
  git add Lume.xcodeproj/project.pbxproj
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "Lume.xcodeproj" / "project.pbxproj"
PROJECT_REL = "Lume.xcodeproj/project.pbxproj"
OVERRIDES = ROOT / "Scripts" / "fork-project-overrides.json"

# One XCBuildConfiguration: `\t\t<ID> /* <name> */ = {` … `buildSettings = {` … `};`
CONFIG = re.compile(
    r"(?P<head>\t\t(?P<id>[0-9A-F]{24}) /\* [^*]+ \*/ = \{\n"
    r"\t\t\tisa = XCBuildConfiguration;\n(?:\t\t\t[^\n]*\n)*?"
    r"\t\t\tbuildSettings = \{\n)(?P<body>(?:\t\t\t\t[^\n]*\n)*?)(?P<tail>\t\t\t\};\n)"
)
# A single-line setting inside buildSettings (multi-line arrays are left alone).
SETTING = re.compile(r'^\t\t\t\t(?P<key>"[^"]+"|[A-Za-z0-9_]+(?:\[[^\]]*\])?) = (?P<value>[^\n]*;)$')
ATTRIBUTE = re.compile(r"^(\t\t\t\t)(LastUpgradeCheck|LastSwiftUpdateCheck) = (\d+);$", re.M)
# One remote package's requirement block, found by its repository URL.
PACKAGE = re.compile(
    r"(?P<head>\t\t\tisa = XCRemoteSwiftPackageReference;\n\t\t\trepositoryURL = \"(?P<url>[^\"]+)\";\n"
    r"\t\t\trequirement = \{\n)(?P<body>(?:\t\t\t\t[^\n]*\n)*?)(?P<tail>\t\t\t\};\n)"
)


def git_show(rev: str) -> str:
    return subprocess.run(
        ["git", "-C", str(ROOT), "show", f"{rev}:{PROJECT_REL}"],
        check=True, capture_output=True, text=True,
    ).stdout


def settings(body: str) -> dict:
    out = {}
    for line in body.splitlines():
        match = SETTING.match(line)
        if match:
            out[match["key"]] = match["value"]
    return out


def configs(text: str) -> dict:
    return {m["id"]: settings(m["body"]) for m in CONFIG.finditer(text)}


def sort_key(line: str) -> str:
    match = SETTING.match(line)
    return match["key"].strip('"') if match else line


def apply_to_body(body: str, changes: dict) -> str:
    lines = body.splitlines()
    for key, value in changes.items():
        index = next((i for i, l in enumerate(lines) if (m := SETTING.match(l)) and m["key"] == key), None)
        if value is None:
            if index is not None:
                del lines[index]
            continue
        new = f"\t\t\t\t{key} = {value}"
        if index is not None:
            lines[index] = new
            continue
        # Xcode keeps buildSettings sorted by key; insert where it would.
        position = next((i for i, l in enumerate(lines) if SETTING.match(l) and sort_key(l) > key.strip('"')), len(lines))
        lines.insert(position, new)
    return "".join(f"{l}\n" for l in lines)


def apply(text: str, overrides: dict) -> str:
    removed = overrides.get("removedObjects", [])
    text = remove_objects(text, removed)
    unknown = set(overrides["configurations"]) - set(removed) - {m["id"] for m in CONFIG.finditer(text)}
    if unknown:
        sys.exit(f"fork-project: build configurations no longer in the project: {sorted(unknown)}")

    def replace(match):
        changes = overrides["configurations"].get(match["id"])
        if not changes:
            return match.group(0)
        return match["head"] + apply_to_body(match["body"], changes) + match["tail"]

    text = CONFIG.sub(replace, text)
    for url, requirement in overrides.get("packageRequirements", {}).items():
        # A package the fork pins differently from upstream (an engine held at
        # its last source-built revision, say).
        text = PACKAGE.sub(
            lambda m: m["head"] + requirement + m["tail"] if m["url"] == url else m.group(0), text
        )
        if url not in {m["url"] for m in PACKAGE.finditer(text)}:
            sys.exit(f"fork-project: package no longer in the project: {url}")
    for url, path in overrides.get("localPackages", {}).items():
        text = localize_package(text, url, path)
    for path, object_id in overrides.get("rootLocalPackages", {}).items():
        text = add_local_package(text, path, object_id)
    if "archiveSymbolsPhase" in overrides:
        text = add_archive_symbols_phase(text, overrides["archiveSymbolsPhase"])
    for name, minimum in overrides.get("attributes", {}).items():
        # Only ever raise: once upstream adopts a newer Xcode, theirs stands.
        text = ATTRIBUTE.sub(
            lambda m: m.group(0) if m[2] != name else f"{m[1]}{name} = {max(int(m[3]), minimum)};", text
        )
    return text


def localize_package(text: str, url: str, path: str) -> str:
    """Replace one remote package with a checked-in, same-product snapshot."""
    name = Path(path).name
    if not re.fullmatch(r"[A-Za-z0-9_/-]+", path) or ".." in Path(path).parts:
        raise ValueError(f"Invalid local package path: {path}")
    pattern = re.compile(
        r'\t\t(?P<id>[0-9A-F]{24}) /\* XCRemoteSwiftPackageReference "[^"\n]+" \*/ = \{\n'
        r'\t\t\tisa = XCRemoteSwiftPackageReference;\n'
        rf'\t\t\trepositoryURL = "{re.escape(url)}";\n.*?^\t\t\}};\n', re.M | re.S
    )
    match = pattern.search(text)
    if not match:
        if f'\t\t\trelativePath = {path};\n' in text:
            return text
        raise ValueError(f"Remote package no longer in project: {url}")
    object_id = match["id"]
    block = (f'\t\t{object_id} /* XCLocalSwiftPackageReference "{name}" */ = {{\n'
             f'\t\t\tisa = XCLocalSwiftPackageReference;\n\t\t\trelativePath = {path};\n\t\t}};\n')
    text = text[:match.start()] + text[match.end():]
    marker = "/* Begin XCLocalSwiftPackageReference section */\n"
    if marker not in text:
        raise ValueError("Expected an existing local-package section")
    text = text.replace(marker, marker + block, 1)
    text = re.sub(rf'^\t\t\tpackage = {object_id} /\* [^\n]+ \*/;\n', "", text, flags=re.M)
    return text.replace(f'XCRemoteSwiftPackageReference "{name}"', f'XCLocalSwiftPackageReference "{name}"')


def add_local_package(text: str, path: str, object_id: str) -> str:
    """Promote a transitive local override to an Xcode root dependency."""
    if not re.fullmatch(r"[A-Za-z0-9_/-]+", path) or ".." in Path(path).parts:
        raise ValueError(f"Invalid local package path: {path}")
    if not re.fullmatch(r"[0-9A-F]{24}", object_id):
        raise ValueError(f"Invalid project object id: {object_id}")
    name = Path(path).name
    if object_id in text:
        if f"relativePath = {path};" not in text:
            raise ValueError(f"Local package id already used: {object_id}")
        return text
    reference = f'{object_id} /* XCLocalSwiftPackageReference "{name}" */'
    marker = "\t\t\tpackageReferences = (\n"
    if marker not in text or "/* Begin XCLocalSwiftPackageReference section */\n" not in text:
        raise ValueError("Expected existing root and local package sections")
    text = text.replace(marker, marker + f"\t\t\t\t{reference},\n", 1)
    marker = "/* Begin XCLocalSwiftPackageReference section */\n"
    block = (f"\t\t{reference} = {{\n\t\t\tisa = XCLocalSwiftPackageReference;\n"
             f"\t\t\trelativePath = {path};\n\t\t}};\n")
    return text.replace(marker, marker + block, 1)


def add_archive_symbols_phase(text: str, config: dict) -> str:
    object_id, target = config["id"], config["target"]
    if not all(re.fullmatch(r"[0-9A-F]{24}", value) for value in (object_id, target)):
        raise ValueError("Invalid archive-symbol phase or target id")
    if object_id in text:
        return text
    reference = f"{object_id} /* Fetch playback archive symbols */"
    target_pattern = rf"(\t\t{target} /\* [^\n]+ \*/ = \{{\n.*?\t\t\tbuildPhases = \(\n)(.*?)(\t\t\t\);)"
    text, count = re.subn(target_pattern, lambda m: m[1] + m[2] + f"\t\t\t\t{reference},\n" + m[3], text, count=1, flags=re.S)
    if count != 1:
        raise ValueError("Archive-symbol target no longer exists")
    command = ('if [ "${ACTION}" = "install" ]; then\n'
               '  /usr/bin/python3 "${SRCROOT}/Scripts/playback-packages.py" symbols '
               '--platform "${PLATFORM_NAME}" --frameworks "${BUILT_PRODUCTS_DIR}" '
               '--destination "${DWARF_DSYM_FOLDER_PATH}"\nfi\n')
    # JSON string escaping is also valid for this PBX string value.
    block = (f"\t\t{reference} = {{\n\t\t\tisa = PBXShellScriptBuildPhase;\n"
             '\t\t\talwaysOutOfDate = 1;\n\t\t\tbuildActionMask = 2147483647;\n'
             '\t\t\tfiles = ();\n\t\t\tinputPaths = ();\n'
             '\t\t\tname = "Fetch playback archive symbols";\n\t\t\toutputPaths = ();\n'
             '\t\t\trunOnlyForDeploymentPostprocessing = 1;\n\t\t\tshellPath = /bin/sh;\n'
             f'\t\t\tshellScript = {json.dumps(command)};\n\t\t}};\n')
    marker = "/* Begin PBXShellScriptBuildPhase section */\n"
    if marker not in text:
        raise ValueError("Expected script build-phase section")
    return text.replace(marker, marker + block, 1)


def remove_objects(text: str, object_ids: list[str]) -> str:
    """Remove declared target objects, list references and TargetAttributes only.

    Refuse dangling scalar references: callers must explicitly include every
    dependent object rather than silently corrupt a surviving target.
    """
    for object_id in object_ids:
        if not re.fullmatch(r"[0-9A-F]{24}", object_id):
            raise ValueError(f"Invalid project object id: {object_id}")
        text = re.sub(
            rf"^\t\t{object_id} /\* [^\n]+? \*/ = (?:\{{[^\n]*\}};\n|\{{\n.*?^\t\t\}};\n)",
            "", text, flags=re.M | re.S,
        )
        text = re.sub(rf"^\t+{object_id} /\* [^\n]+ \*/,\n", "", text, flags=re.M)
        text = re.sub(rf"^\t{{5}}{object_id} = \{{\n.*?^\t{{5}}\}};\n", "", text, flags=re.M | re.S)
    remaining = [object_id for object_id in object_ids if object_id in text]
    if remaining:
        raise ValueError(f"Dangling references to removed project objects: {remaining}")
    return text


def capture(base_rev: str) -> dict:
    base_text, ours_text = git_show(base_rev), PROJECT.read_text()
    existing = json.loads(OVERRIDES.read_text())
    removed = existing.get("removedObjects", [])
    base_text = remove_objects(base_text, removed)
    base, ours = configs(base_text), configs(ours_text)
    if set(base) != set(ours):
        sys.exit(f"fork-project: configuration ids differ from {base_rev}; capture needs the same set")
    result = {"configurations": {}, "attributes": {}}
    if removed:
        result["removedObjects"] = removed
    if existing.get("localPackages"):
        result["localPackages"] = existing["localPackages"]
    if existing.get("rootLocalPackages"):
        result["rootLocalPackages"] = existing["rootLocalPackages"]
    if existing.get("archiveSymbolsPhase"):
        result["archiveSymbolsPhase"] = existing["archiveSymbolsPhase"]
    for config_id in sorted(ours):
        changes = {k: v for k, v in ours[config_id].items() if base[config_id].get(k) != v}
        changes.update({k: None for k in base[config_id] if k not in ours[config_id]})
        if changes:
            result["configurations"][config_id] = dict(sorted(changes.items()))
    base_packages = {m["url"]: m["body"] for m in PACKAGE.finditer(base_text)}
    packages = {
        m["url"]: m["body"] for m in PACKAGE.finditer(ours_text)
        if m["url"] in base_packages and base_packages[m["url"]] != m["body"]
    }
    if packages:
        result["packageRequirements"] = dict(sorted(packages.items()))
    base_attrs = {m[2]: int(m[3]) for m in ATTRIBUTE.finditer(base_text)}
    for m in ATTRIBUTE.finditer(ours_text):
        if int(m[3]) > base_attrs.get(m[2], 0):
            result["attributes"][m[2]] = int(m[3])
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("capture", "check"):
        sub.add_parser(name).add_argument("--base", default="upstream/main")
    sub.add_parser("apply").add_argument("--from", dest="source")
    args = parser.parse_args()

    if args.command == "capture":
        OVERRIDES.write_text(json.dumps(capture(args.base), indent=2) + "\n")
        print(f"fork-project: wrote {OVERRIDES.relative_to(ROOT)}")
    elif args.command == "apply":
        source = git_show(args.source) if args.source else PROJECT.read_text()
        PROJECT.write_text(apply(source, json.loads(OVERRIDES.read_text())))
        print(f"fork-project: applied overrides to {PROJECT_REL}")
    else:
        expected = apply(git_show(args.base), json.loads(OVERRIDES.read_text()))
        if expected != PROJECT.read_text():
            sys.exit(f"fork-project: {PROJECT_REL} is not {args.base} + overrides")
        print(f"fork-project: {PROJECT_REL} == {args.base} + overrides")


if __name__ == "__main__":
    main()
