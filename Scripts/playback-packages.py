#!/usr/bin/env python3
"""Fetch Lume's playback packages from upstream into a shared local store.

KSPlayer, FFmpegKit, FFmpegBuild, LibDovi and VLCKit are not cloned by
SwiftPM: their Git histories hold years of superseded binaries. This script
downloads each one's snapshot at the commit pinned in
Scripts/playback-dependencies.json (no history), keeps only the slices Lume
builds (ARM64 iOS, macOS, tvOS and visionOS, device and simulator), drops the
dSYMs, and checks the result against the content hash in the lock.

Packages land in ~/Library/Developer/Lume-PlaybackPackages, shared by every
checkout and worktree on the Mac; Dependencies/<name> is a gitignored symlink
into it. Retained ARM64 machine code is upstream's byte for byte.

    playback-packages.py fetch            # set up or repair Dependencies/ (idempotent)
    playback-packages.py pin --package X  # after editing the lock: rebuild X, record its hash
    playback-packages.py symbols ...      # archive build phase: matching dSYMs from upstream
    playback-packages.py prune [--apply]  # remove store entries the current lock doesn't use

Runs on Python 3.9+ (Xcode's /usr/bin/python3) with macOS's lipo, ditto and dwarfdump.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import zipfile


ROOT = Path(__file__).resolve().parent.parent
LOCK = ROOT / "Scripts/playback-dependencies.json"
DEPENDENCIES = ROOT / "Dependencies"
STORE = Path(os.environ.get("LUME_PLAYBACK_STORE", Path.home() / "Library/Developer/Lume-PlaybackPackages"))
SYMBOLS_FILE = ".lume-symbols.json"
FAT_MAGIC = {b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}
CHUNK = 1024 * 1024
# Xcode PLATFORM_NAME -> (XCFramework SupportedPlatform, SupportedPlatformVariant)
PLATFORMS = {"macosx": ("macos", None), "iphoneos": ("ios", None), "appletvos": ("tvos", None),
             "xros": ("xros", None), "iphonesimulator": ("ios", "simulator"),
             "appletvsimulator": ("tvos", "simulator"), "xrsimulator": ("xros", "simulator")}


def log(message):
    print(f"playback-packages: {message}", flush=True)


def load_lock():
    return json.loads(LOCK.read_text())


# Downloads and safe extraction --------------------------------------------------------------

def open_url(url):
    if not url.startswith("https://"):
        raise ValueError(f"Playback sources must use HTTPS: {url}")
    request = urllib.request.Request(url, headers={"User-Agent": "lume-playback-packages"})
    return urllib.request.urlopen(request, timeout=120)


def download(url, destination, sha256):
    digest = hashlib.sha256()
    with open_url(url) as source, open(destination, "wb") as target:
        for chunk in iter(lambda: source.read(CHUNK), b""):
            digest.update(chunk)
            target.write(chunk)
    if digest.hexdigest() != sha256:
        raise ValueError(f"Checksum mismatch for {url}")


def safe_relative(name):
    path = Path(name)
    if not name or path.is_absolute() or ".." in path.parts:
        raise ValueError(f"Unsafe archive member: {name}")
    return path


def safe_link(relative, target):
    if os.path.isabs(target) or os.path.normpath(os.path.join(os.path.dirname(relative), target)).startswith(".."):
        raise ValueError(f"Archive symlink escapes its package: {relative} -> {target}")


def wanted(relative, prefixes):
    return not prefixes or any(relative == p or relative.startswith(p + "/") for p in prefixes)


def extract_tar(url, destination, prefixes=()):
    """Stream a source snapshot, stripping its top folder, writing only `prefixes`."""
    count = 0
    with open_url(url) as response, tarfile.open(fileobj=response, mode="r|gz") as archive:
        for member in archive:
            parts = member.name.split("/", 1)
            if len(parts) < 2 or not parts[1].strip("/"):
                continue
            relative = parts[1].rstrip("/")
            if not wanted(relative, prefixes):
                continue
            target = destination / safe_relative(relative)
            target.parent.mkdir(parents=True, exist_ok=True)
            if member.isdir():
                target.mkdir(exist_ok=True)
            elif member.isfile():
                with archive.extractfile(member) as source, open(target, "wb") as output:
                    shutil.copyfileobj(source, output, CHUNK)
                target.chmod(0o755 if member.mode & 0o111 else 0o644)
            elif member.issym():
                safe_link(relative, member.linkname)
                os.symlink(member.linkname, target)
            else:
                raise ValueError(f"Unsupported archive member: {member.name}")
            count += 1
    if not count:
        raise ValueError(f"Nothing extracted from {url}")


def find_one(root, name):
    matches = [path for path in root.rglob(name) if path.is_dir()]
    if len(matches) != 1:
        raise ValueError(f"Expected one {name} in the download, found {len(matches)}")
    return matches[0]


# Thinning ------------------------------------------------------------------------------------

def file_sha256(path, offset=0, size=None):
    digest = hashlib.sha256()
    with open(path, "rb") as source:
        source.seek(offset)
        remaining = size
        while remaining is None or remaining > 0:
            chunk = source.read(CHUNK if remaining is None else min(CHUNK, remaining))
            if not chunk:
                if remaining:
                    raise ValueError(f"Truncated binary: {path}")
                break
            digest.update(chunk)
            if remaining is not None:
                remaining -= len(chunk)
    return digest.hexdigest()


def thin_file(path):
    """Replace a fat Mach-O with its ARM64 slice, proving the bytes are unchanged."""
    with open(path, "rb") as source:
        if source.read(4) not in FAT_MAGIC:
            return
    details = subprocess.run(["lipo", "-detailed_info", str(path)], check=True,
                             capture_output=True, text=True).stdout
    match = re.search(r"architecture arm64\n(.*?)(?=architecture |\Z)", details, re.S)
    if not match:
        raise ValueError(f"No ARM64 slice in {path}")
    offset = int(re.search(r"\boffset (\d+)", match[1])[1])
    size = int(re.search(r"\bsize (\d+)", match[1])[1])
    expected = file_sha256(path, offset, size)
    thinned = path.with_name(path.name + ".arm64")
    subprocess.run(["lipo", str(path), "-thin", "arm64", "-output", str(thinned)], check=True)
    if file_sha256(thinned) != expected:
        raise ValueError(f"Thinning changed retained machine code: {path}")
    thinned.chmod(stat.S_IMODE(path.stat().st_mode))
    thinned.replace(path)


def uuids(binary):
    output = subprocess.run(["dwarfdump", "--uuid", str(binary)], check=True,
                            capture_output=True, text=True).stdout
    return {uuid.upper(): arch for uuid, arch in re.findall(r"UUID: ([A-Fa-f0-9-]+) \(([^)]+)\)", output)}


def thin_xcframework(framework, package_root, policy, untouched_platforms=()):
    """Keep the policy's slices, thin them to ARM64, move dSYM records out.

    A device slice on an `untouched_platforms` platform keeps all its
    architectures: Swift package products (LumeAetherBridge) still link x86_64
    in a Mac archive, whatever the app's own ARCHS.
    """
    info_path = framework / "Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    kept, symbols = [], []
    for library in info["AvailableLibraries"]:
        folder = framework / library["LibraryIdentifier"]
        if (library["SupportedPlatform"] not in policy["platforms"]
                or library.get("SupportedPlatformVariant") not in policy["variants"]
                or "arm64" not in library["SupportedArchitectures"]):
            shutil.rmtree(folder)
            continue
        debug_path = library.pop("DebugSymbolsPath", None)
        if debug_path:
            shutil.rmtree(folder / debug_path)
        thin = not (library["SupportedPlatform"] in untouched_platforms
                    and library.get("SupportedPlatformVariant") is None)
        if thin:
            for file in sorted(folder.rglob("*")):
                if file.is_file() and not file.is_symlink():
                    thin_file(file)
            library["SupportedArchitectures"] = ["arm64"]
        if debug_path:
            binary = folder / library.get("BinaryPath", library["LibraryPath"] + "/" + Path(library["LibraryPath"]).stem)
            symbols.append({
                "xcframework": framework.relative_to(package_root).as_posix(),
                "library_identifier": library["LibraryIdentifier"],
                "platform": library["SupportedPlatform"],
                "variant": library.get("SupportedPlatformVariant"),
                "framework": library["LibraryPath"],
                "debug_symbols_path": debug_path,
                "thinned": thin,
                "uuids": uuids(binary),
            })
        kept.append(library)
    if not kept:
        raise ValueError(f"No supported slices remain in {framework}")
    info["AvailableLibraries"] = kept
    info_path.chmod(0o644)
    info_path.write_bytes(plistlib.dumps(info, sort_keys=True))
    # The container changed; each slice's own signature is untouched.
    shutil.rmtree(framework / "_CodeSignature", ignore_errors=True)
    return symbols


# Building a package --------------------------------------------------------------------------

def tree_sha256(root):
    """Hash names, modes, symlinks and contents, so a rebuild proves an identical package."""
    digest = hashlib.sha256()
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(dirnames + filenames):
            path = Path(dirpath) / name
            relative = path.relative_to(root).as_posix()
            if path.is_symlink():
                entry = f"L {relative} {os.readlink(path)}"
            elif path.is_dir():
                entry = f"D {relative}"
            else:
                executable = "x" if path.stat().st_mode & 0o111 else "-"
                entry = f"F {relative} {executable} {file_sha256(path)}"
            digest.update(entry.encode() + b"\n")
    return digest.hexdigest()


def point_manifest_at_local_binaries(manifest, binaries):
    text = manifest.read_text()
    for relative, source in binaries.items():
        pattern = re.compile(r'(\.binaryTarget\(\s*name:\s*"' + re.escape(source["target"]) + r'"\s*,\s*)'
                             r'url:\s*"(?P<url>[^"]+)"\s*,\s*checksum:\s*"[^"]+"')
        matches = list(pattern.finditer(text))
        if len(matches) != 1 or matches[0]["url"] != source["url"]:
            raise ValueError(f"{manifest} no longer pins {source['url']}; review the lock")
        text = pattern.sub(lambda m: m[1] + f'path: "{relative}"', text)
    manifest.write_text(text)


def build(package, policy, work):
    """Assemble one package in `work` and return its tree hash."""
    log(f"downloading {package['name']} {package['version']} ({package['revision'][:12]})")
    extract_tar(package["source"].format(revision=package["revision"]), work, package.get("paths", ()))
    downloads = work.parent / (work.name + "-downloads")
    try:
        for relative, source in package.get("binaries", {}).items():
            downloads.mkdir()
            archive = downloads / "binary.zip"
            download(source["url"], archive, source["sha256"])
            subprocess.run(["ditto", "-x", "-k", str(archive), str(downloads / "x")], check=True)
            shutil.move(str(find_one(downloads / "x", Path(relative).name)), str(work / relative))
            shutil.rmtree(downloads)
    finally:
        shutil.rmtree(downloads, ignore_errors=True)
    if package.get("binaries"):
        point_manifest_at_local_binaries(work / "Package.swift", package["binaries"])
    symbols = []
    for framework in sorted(work.rglob("*.xcframework")):
        if framework.is_dir() and ".xcframework/" not in framework.relative_to(work).as_posix():
            symbols += thin_xcframework(framework, work, policy, package.get("untouched_platforms", ()))
    (work / SYMBOLS_FILE).write_text(json.dumps(symbols, indent=2, sort_keys=True) + "\n")
    return tree_sha256(work)


def store_path(package):
    return STORE / f"{package['name']}-{package['tree_sha256'][:16]}"


def ensure(package, policy, pin=False):
    """Make sure the store holds this package; returns its folder."""
    if not pin and not package.get("tree_sha256"):
        raise ValueError(f"{package['name']} has no tree_sha256; run: playback-packages.py pin --package {package['name']}")
    if not pin and store_path(package).is_dir():
        return store_path(package)
    STORE.mkdir(parents=True, exist_ok=True)
    work_root = Path(tempfile.mkdtemp(prefix=f".{package['name']}-", dir=STORE))
    try:
        work = work_root / "package"
        work.mkdir()
        actual = build(package, policy, work)
        if pin:
            package["tree_sha256"] = actual
        elif actual != package["tree_sha256"]:
            raise ValueError(f"{package['name']} does not match its pinned content (got {actual}); "
                             "upstream changed or the lock is stale")
        final = store_path(package)
        if final.is_dir():
            return final
        work.rename(final)
        log(f"stored {final}")
        return final
    finally:
        shutil.rmtree(work_root, ignore_errors=True)


def link(package, folder):
    link_path = DEPENDENCIES / package["name"]
    if link_path.is_symlink():
        if os.readlink(link_path) == str(folder):
            return
        link_path.unlink()
    elif link_path.exists():
        raise ValueError(f"{link_path} is a real folder; move it aside (packages now live in {STORE})")
    link_path.symlink_to(folder)
    log(f"Dependencies/{package['name']} -> {folder}")


# Commands ------------------------------------------------------------------------------------

def selected(lock, names):
    packages = lock["packages"]
    unknown = set(names or ()) - {package["name"] for package in packages}
    if unknown:
        raise ValueError(f"Unknown packages: {sorted(unknown)}")
    return [package for package in packages if not names or package["name"] in names]


def command_fetch(args):
    lock = load_lock()
    for package in selected(lock, args.package):
        link(package, ensure(package, lock["distribution"]))
    log("ready")


def command_pin(args):
    lock = load_lock()
    for package in selected(lock, args.package):
        old = package.get("tree_sha256")
        folder = ensure(package, lock["distribution"], pin=True)
        LOCK.write_text(json.dumps(lock, indent=2) + "\n")
        link(package, folder)
        log(f"{package['name']} tree_sha256 {'unchanged' if old == package['tree_sha256'] else 'updated'}: {package['tree_sha256']}")


def command_prune(args):
    used = {store_path(package).name for package in load_lock()["packages"] if package.get("tree_sha256")}
    stale = sorted(path for path in STORE.iterdir() if path.name not in used) if STORE.is_dir() else []
    for path in stale:
        log(("removing " if args.apply else "unused by this checkout's lock: ") + str(path))
        if args.apply:
            shutil.rmtree(path)
    if stale and not args.apply:
        log("other branches or worktrees may still use these; rerun with --apply to delete")


def extract_symbols(package, record, destination):
    """Pull one slice's dSYMs from the upstream download into `destination`."""
    inside = f"{record['xcframework']}/{record['library_identifier']}/{record['debug_symbols_path']}"
    binary = package.get("binaries", {}).get(record["xcframework"])
    if binary is None:
        extract_tar(package["source"].format(revision=package["revision"]), destination, [inside])
        return destination / inside
    archive = destination / "binary.zip"
    download(binary["url"], archive, binary["sha256"])
    suffix = f"{Path(record['xcframework']).name}/{record['library_identifier']}/{record['debug_symbols_path']}/"
    with zipfile.ZipFile(archive) as source:
        members = [m for m in source.infolist() if suffix in m.filename and not m.is_dir()]
        if not members:
            raise ValueError(f"No dSYMs for {record['library_identifier']} in {binary['url']}")
        for member in members:
            if stat.S_ISLNK(member.external_attr >> 16):
                raise ValueError(f"Unexpected symlink in symbols: {member.filename}")
            relative = safe_relative(member.filename[member.filename.index(suffix) + len(suffix):])
            target = destination / "symbols" / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            with source.open(member) as data, open(target, "wb") as output:
                shutil.copyfileobj(data, output, CHUNK)
    archive.unlink()
    return destination / "symbols"


def command_symbols(args):
    sdk, variant = PLATFORMS[args.platform]
    args.destination.mkdir(parents=True, exist_ok=True)
    for package in load_lock()["packages"]:
        records_file = DEPENDENCIES / package["name"] / SYMBOLS_FILE
        records = json.loads(records_file.read_text()) if records_file.is_file() else []
        for record in records:
            if (record["platform"], record["variant"]) != (sdk, variant):
                continue
            framework = args.frameworks / record["framework"]
            binary = framework / framework.stem
            if not binary.is_file():
                log(f"{framework.name} is not in this build; skipping its symbols")
                continue
            if uuids(binary) != record["uuids"]:
                raise ValueError(f"{framework.name} in the build does not match the pinned {package['name']}")
            bundle = args.destination / (framework.name + ".dSYM")
            dwarf = bundle / "Contents/Resources/DWARF" / framework.stem
            if bundle.exists():
                if dwarf.is_file() and uuids(dwarf) == record["uuids"]:
                    continue
                raise ValueError(f"Stale symbols at {bundle}; refusing to overwrite")
            with tempfile.TemporaryDirectory(prefix="lume-symbols-", dir=args.temporary) as temporary:
                source = extract_symbols(package, record, Path(temporary)) / bundle.name
                source_dwarf = source / "Contents/Resources/DWARF" / framework.stem
                if record["thinned"]:
                    thin_file(source_dwarf)
                if uuids(source_dwarf) != record["uuids"]:
                    raise ValueError(f"Upstream symbols do not match {framework.name}")
                shutil.copytree(source, bundle)
            log(f"added {bundle.name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    fetch = commands.add_parser("fetch", help="Download missing packages and link Dependencies/")
    fetch.add_argument("--package", action="append")
    fetch.set_defaults(run=command_fetch)
    pin = commands.add_parser("pin", help="Rebuild packages and record their content hashes in the lock")
    pin.add_argument("--package", action="append", required=True)
    pin.set_defaults(run=command_pin)
    prune = commands.add_parser("prune", help="List (or --apply: delete) store entries this lock doesn't use")
    prune.add_argument("--apply", action="store_true")
    prune.set_defaults(run=command_prune)
    symbols = commands.add_parser("symbols", help="Copy matching upstream dSYMs into an archive")
    symbols.add_argument("--platform", choices=sorted(PLATFORMS), required=True)
    symbols.add_argument("--frameworks", type=Path, required=True)
    symbols.add_argument("--destination", type=Path, required=True)
    symbols.add_argument("--temporary", default=os.environ.get("TEMP_DIR"))
    symbols.set_defaults(run=command_symbols)
    args = parser.parse_args()
    try:
        args.run(args)
    except (ValueError, OSError, subprocess.CalledProcessError, tarfile.TarError) as error:
        print(f"playback-packages: error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
