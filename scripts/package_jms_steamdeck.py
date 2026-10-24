"""Package an explicit Linux x64 AOT bundle as an unsigned Steam Deck TEST archive.

This module never builds, executes, installs, updates or publishes JMS. It does
not inspect the host's user profile, keyring, services or installed packages.
"""

import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import struct
import tarfile


REQUIRED_FILES = (
    "jms",
    "lib/libapp.so",
    "lib/libflutter_linux_gtk.so",
    "data/icudtl.dat",
)
GENERATED_FILES = {
    "Launch-JMS-SteamDeck.sh",
    "README-STEAMDECK-TEST.md",
    "JMS_STEAMDECK_TEST.json",
    "STEAMDECK_TEST_NOTICES.txt",
    "notices/PROVIDED-NATIVE-NOTICES.txt",
    "SHA256SUMS.txt",
}
DEBUG_NAMES = {
    "kernel_blob.bin", "app.dill", "vm_snapshot_data", "isolate_snapshot_data",
    "vm_snapshot_instr", "isolate_snapshot_instr", "debug", "profile", ".dart_tool",
    ".jms-steamdeck-test",
}
WINDOWS_SUFFIXES = {".exe", ".dll", ".pdb", ".msi", ".bat", ".cmd", ".ps1"}


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _reject_link(path):
    info = path.lstat()
    if (stat.S_ISLNK(info.st_mode) or
            getattr(info, "st_file_attributes", 0) & 0x400 or
            (hasattr(path, "is_junction") and path.is_junction())):
        raise ValueError("Symlinks and reparse points are not accepted: " + path.name)
    return info


def checked_path(value, *, directory=False, allow_missing=False):
    path = Path(value)
    if ".." in path.parts:
        raise ValueError("Parent traversal is not accepted")
    path = path.absolute()
    for ancestor in reversed((path, *path.parents)):
        if ancestor.exists() or ancestor.is_symlink():
            _reject_link(ancestor)
    if not path.exists():
        if allow_missing:
            return path
        raise ValueError("Input does not exist: " + path.name)
    info = _reject_link(path)
    expected = stat.S_ISDIR if directory else stat.S_ISREG
    if not expected(info.st_mode):
        raise ValueError("Input has the wrong file type: " + path.name)
    return path


def safe_relative(name):
    path = PurePosixPath(name)
    if path.is_absolute() or not path.parts:
        raise ValueError("Unsafe bundle path")
    for part in path.parts:
        if (part in ("", ".", "..") or "\\" in part or ":" in part or
                part.endswith((".", " ")) or any(ord(char) < 32 or ord(char) == 127 for char in part)):
            raise ValueError("Unsafe bundle path: " + repr(name))
        stem = part.split(".", 1)[0].upper()
        if stem in {"CON", "PRN", "AUX", "NUL", *(f"COM{i}" for i in range(1, 10)),
                    *(f"LPT{i}" for i in range(1, 10))}:
            raise ValueError("Reserved bundle path: " + repr(name))
    return path.as_posix()


def validate_elf(path):
    with path.open("rb") as source:
        header = source.read(64)
    if len(header) < 64 or header[:7] != b"\x7fELF\x02\x01\x01" or header[7] not in (0, 3):
        raise ValueError("Expected a Linux x64 little-endian ELF64 file: " + path.name)
    fields = struct.unpack("<16sHHIQQQIHHHHHH", header)
    if fields[1] not in (2, 3) or fields[2] != 62 or fields[3] != 1 or fields[8] != 64:
        raise ValueError("Wrong ELF architecture, type or header: " + path.name)


def inspect_bundle(bundle):
    bundle = checked_path(bundle, directory=True)
    if bundle.parent.name.lower() in ("debug", "profile"):
        raise ValueError("Debug/profile build directories are not accepted")
    records = []
    seen = set()
    pending = [bundle]
    while pending:
        directory = pending.pop()
        for path in sorted(directory.iterdir(), key=lambda item: item.name):
            info = _reject_link(path)
            name = safe_relative(path.relative_to(bundle).as_posix())
            folded = name.casefold()
            if folded in seen:
                raise ValueError("Case-colliding bundle paths: " + name)
            seen.add(folded)
            if any(part.lower() in DEBUG_NAMES or part.lower().endswith(".dsym") for part in Path(name).parts):
                raise ValueError("Debug/profile or local state artifact in bundle: " + name)
            if path.suffix.lower() in WINDOWS_SUFFIXES or path.suffix.lower() in {".dill", ".debug", ".symbols"}:
                raise ValueError("Windows or debug artifact in bundle: " + name)
            if stat.S_ISDIR(info.st_mode):
                pending.append(path)
                continue
            if not stat.S_ISREG(info.st_mode) or info.st_nlink > 1:
                raise ValueError("Only regular, unaliased bundle files are accepted: " + name)
            with path.open("rb") as source:
                magic = source.read(4)
            if magic[:2] == b"MZ":
                raise ValueError("Windows PE content in bundle: " + name)
            if magic == b"\x7fELF" or name == "jms" or re.search(r"\.so(?:\.|$)", path.name):
                validate_elf(path)
            if (folded in {value.casefold() for value in GENERATED_FILES} or folded.startswith("notices/") or
                    (folded == "license" and name != "LICENSE")):
                raise ValueError("Bundle collides with generated package metadata: " + name)
            records.append({"path": name, "size": info.st_size, "sha256": sha256_file(path)})
    records.sort(key=lambda record: record["path"])
    names = {record["path"] for record in records}
    for required in REQUIRED_FILES:
        if required not in names:
            raise ValueError("Required AOT bundle file is missing: " + required)
    if not any(name.startswith("data/flutter_assets/") for name in names):
        raise ValueError("Flutter assets are missing or empty")
    if not (bundle / "data/icudtl.dat").stat().st_size:
        raise ValueError("ICU data must not be empty")
    return bundle, records


def launcher_bytes():
    return b'''#!/bin/sh
set -eu
umask 077
_jms_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
_jms_state="$_jms_dir/.jms-steamdeck-test"
mkdir -p "$_jms_state/config" "$_jms_state/data" "$_jms_state/cache" "$_jms_state/tmp"
XDG_CONFIG_HOME="$_jms_state/config"
XDG_DATA_HOME="$_jms_state/data"
XDG_CACHE_HOME="$_jms_state/cache"
TMPDIR="$_jms_state/tmp"
export XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME TMPDIR
cd -- "$_jms_dir"
exec "$_jms_dir/jms" --handheld --skipNotifications "$@"
'''


def readme_bytes():
    return """# JMS Steam Deck TEST portable bundle

Unsigned local test material. This is not an installed Arch package, an AppImage,
a Flatpak, an update feed, or a published Steam Deck release. SteamOS and a real
Steam Deck have not been verified by this packaging operation. No program is run.

Extract the whole archive into a user-writable folder. Keep jms, lib/ and data/
together. Add Launch-JMS-SteamDeck.sh as a non-Steam game and use that launcher.
The raw jms binary is retained unchanged. Steam Input's keyboard mapping contract:

* direction pad / left stick directions -> keyboard arrow keys;
* primary confirm -> Enter; return/cancel -> Escape;
* send ordinary press/release pairs; use directional focus, not mouse emulation.

The launcher always adds --handheld --skipNotifications and forwards additional
arguments as separate arguments. --handheld explicitly distinguishes a Steam
Input keyboard layout from an ordinary desktop keyboard. Native Linux raw
joystick/axis input has not been implemented; keyboard mapping is required.

The launcher gives this test's file preferences/data/cache/temp their own
.jms-steamdeck-test directory beside the executable (umask 077). It changes only
the child process XDG_CONFIG_HOME, XDG_DATA_HOME, XDG_CACHE_HOME and TMPDIR.
It does not change XDG_RUNTIME_DIR or DBUS_SESSION_BUS_ADDRESS. This is NOT a
sandbox or a separate security identity: Secret Service/libsecret uses JMS's
existing com.jim608.jms.seerr-session schema and the session's shared keyring;
Discord IPC, including /tmp fallback, and the session bus can still be shared.
--skipNotifications skips notification initialization only. It does not promise
to disable updates, Discord, networking, account access or keyring access.

This bundle is NOT fully self-contained. GTK 3 and libsecret are direct CMake
dependencies. The historical Linux dependency inventory also includes glibc,
libstdc++/gcc runtime, mpv, ALSA, sqlite, libarchive, xdg-user-dirs, Secret Service
with a keyring provider, and NetworkManager. Actual ELF DT_NEEDED libraries,
glibc/GLIBCXX versions, media codecs, GPU/audio/Wayland/X11 and SteamOS services
must be checked against the real release bundle and target device. The previous
Arch packaging's pacman/PolicyKit update mechanism is not supplied here. No
dependency is installed or any SteamOS read-only protection changed.

LICENSE and notices/PROVIDED-NATIVE-NOTICES.txt preserve the supplied materials;
Flutter assets (including any bundled NOTICES.Z) are preserved byte-for-byte.
Supplied notices may describe another platform, including Android. Their
inclusion does not establish Linux redistribution/license/source compliance.
STEAMDECK_TEST_NOTICES.txt lists the remaining validation boundaries. Keep the
corresponding reviewed source kit and its full source fingerprint with this
test bundle; a base Git commit alone does not describe uncommitted changes.

SHA256SUMS.txt covers each payload file except itself. JMS_STEAMDECK_TEST.json
records the exact input bundle file hashes, bundle fingerprint and declared
source identity. Header/AOT-layout checks reject known wrong-platform/debug
payloads; they are not proof of runtime compatibility or build reproducibility.
No Steam Deck update feed is supplied. The shared app's Linux in-app update
route is not validated for this portable archive. The packaging command does
not install, update, migrate profiles, broadcast or upload; the raw app retains
shared JMS features and their usual controls and consent requirements.
""".encode("utf-8")


def package_portable(*, bundle, output, version, build_number, source_commit,
                     source_fingerprint, license_path, notices_path, epoch=0):
    if not isinstance(version, str) or not re.fullmatch(r"\d+\.\d+\.\d+(?:-[A-Za-z0-9]+(?:[.-][A-Za-z0-9]+)*)?", version):
        raise ValueError("Invalid version name")
    if type(build_number) is not int or build_number < 1:
        raise ValueError("Build number must be a positive integer")
    if not isinstance(source_commit, str) or not re.fullmatch(r"[a-f0-9]{40}", source_commit):
        raise ValueError("A full base source commit is required")
    if not isinstance(source_fingerprint, str) or not re.fullmatch(r"[a-f0-9]{64}", source_fingerprint):
        raise ValueError("A full reviewed source fingerprint is required")
    if type(epoch) is not int or not 0 <= epoch <= 0xFFFFFFFF:
        raise ValueError("Invalid archive epoch")
    bundle, records = inspect_bundle(bundle)
    license_path = checked_path(license_path)
    notices_path = checked_path(notices_path)
    license_bytes = license_path.read_bytes()
    notices_bytes = notices_path.read_bytes()
    if b"GNU GENERAL PUBLIC LICENSE" not in license_bytes or b"Version 3" not in license_bytes:
        raise ValueError("The project's GPLv3 LICENSE is required")
    if not notices_bytes.strip():
        raise ValueError("Explicit native notices must not be empty")
    if (bundle / "LICENSE").exists() and (bundle / "LICENSE").read_bytes() != license_bytes:
        raise ValueError("Bundle LICENSE differs from the supplied project license")
    output = checked_path(output, allow_missing=True)
    if output.exists():
        raise ValueError("Output must be a new directory; refusing to overwrite it")
    if output.is_relative_to(bundle) or bundle.is_relative_to(output):
        raise ValueError("Output and input bundle must not overlap")
    if not output.parent.is_dir():
        raise ValueError("Output parent directory must already exist")

    bundle_fingerprint = hashlib.sha256(canonical(records)).hexdigest()
    identity = f"JMS-SteamDeck-TEST-{version}+{build_number}-linux-x64-{source_fingerprint[:12]}"
    metadata = {
        "schemaVersion": 1, "distribution": "steamdeck-test-portable", "platform": "linux-x64",
        "applicationId": "com.jim608.jms", "versionName": version, "versionCode": build_number,
        "baseSourceCommit": source_commit, "sourceFingerprint": source_fingerprint,
        "bundleFingerprint": bundle_fingerprint, "bundleFiles": records,
        "signing": "unsigned", "releaseAotLayoutChecked": True,
        "steamOsRuntimeVerified": False, "fullySelfContained": False,
        "nativeLinuxRawAxisImplemented": False, "installerIncluded": False,
        "updateFeedIncluded": False, "launcherArguments": ["--handheld", "--skipNotifications"],
        "nativeLicenseClosureVerified": False,
        "fileState": ".jms-steamdeck-test/{config,data,cache,tmp}",
        "sessionKeyringAndIpcIsolated": False,
    }
    generated = {
        "LICENSE": license_bytes,
        "Launch-JMS-SteamDeck.sh": launcher_bytes(),
        "README-STEAMDECK-TEST.md": readme_bytes(),
        "JMS_STEAMDECK_TEST.json": json.dumps(metadata, indent=2, ensure_ascii=False).encode("utf-8") + b"\n",
        "STEAMDECK_TEST_NOTICES.txt": (
            "JMS Steam Deck TEST - validation boundaries\n"
            "GPLv3 project license and supplied native notices are preserved separately.\n"
            "Supplied notices are not asserted to be Linux-specific or complete.\n"
            "No native license/source audit, ELF dependency closure, glibc/GLIBCXX\n"
            "compatibility, SteamOS/device, GPU/audio, controller-axis or account/keyring\n"
            "isolation acceptance was performed by this packager.\n"
            "No previous Windows, Android or Arch package is represented as this build.\n"
        ).encode("utf-8"),
        "notices/PROVIDED-NATIVE-NOTICES.txt": notices_bytes,
    }
    payload = {record["path"]: bundle / record["path"] for record in records}
    payload.update(generated)
    payload_hashes = {record["path"]: record["sha256"] for record in records}
    payload_hashes.update({name: hashlib.sha256(value).hexdigest() for name, value in generated.items()})
    payload_hashes = dict(sorted(payload_hashes.items()))
    expected_sizes = {record["path"]: record["size"] for record in records}
    payload["SHA256SUMS.txt"] = "".join(f"{digest}  {name}\n" for name, digest in payload_hashes.items()).encode("utf-8")

    output.mkdir(exist_ok=False)
    archive = output / (identity + ".tar.gz")
    created_archive = False
    try:
        with archive.open("xb") as compressed:
            created_archive = True
            with gzip.GzipFile(filename="", mode="wb", fileobj=compressed, mtime=epoch) as gzip_stream:
                with tarfile.open(fileobj=gzip_stream, mode="w|", format=tarfile.PAX_FORMAT) as container:
                    directories = {identity}
                    for name in payload:
                        directories.update(f"{identity}/{parent.as_posix()}" for parent in PurePosixPath(name).parents
                                           if parent.as_posix() != ".")
                    for name in sorted(directories):
                        member = tarfile.TarInfo(name + "/")
                        member.type = tarfile.DIRTYPE
                        member.mode = 0o755
                        member.mtime = epoch
                        container.addfile(member)
                    for name, value in sorted(payload.items()):
                        member = tarfile.TarInfo(identity + "/" + name)
                        member.mode = 0o755 if name in ("jms", "Launch-JMS-SteamDeck.sh") else 0o644
                        member.mtime = epoch
                        if isinstance(value, bytes):
                            member.size = len(value)
                            container.addfile(member, io.BytesIO(value))
                        else:
                            # Reject a file/link replacement that happened after validation.
                            info = _reject_link(value)
                            if (not stat.S_ISREG(info.st_mode) or info.st_nlink > 1 or
                                    info.st_size != expected_sizes[name]):
                                raise ValueError("Input bundle changed during packaging: " + name)
                            member.size = info.st_size
                            flags = os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0)
                            with os.fdopen(os.open(value, flags), "rb") as source:
                                opened = os.fstat(source.fileno())
                                if ((opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino) or
                                        not stat.S_ISREG(opened.st_mode) or opened.st_nlink > 1):
                                    raise ValueError("Input file was replaced during packaging: " + name)
                                reader = _HashingReader(source)
                                container.addfile(member, reader)
                                if reader.digest.hexdigest() != payload_hashes[name]:
                                    raise ValueError("Input bytes changed during packaging: " + name)
        _, after = inspect_bundle(bundle)
        if after != records:
            raise ValueError("Input bundle changed during packaging")
        receipt = {
            "schemaVersion": 1, "artifact": archive.name, "size": archive.stat().st_size,
            "sha256": sha256_file(archive), "sourceCommit": source_commit,
            "sourceFingerprint": source_fingerprint, "bundleFingerprint": bundle_fingerprint,
            "bundleFileCount": len(records), "payloadFileCount": len(payload),
            "steamOsRuntimeVerified": False, "nativeLicenseClosureVerified": False,
        }
        receipt_path = output / "delivery-receipt.json"
        with receipt_path.open("x", encoding="utf-8", newline="\n") as destination:
            json.dump(receipt, destination, indent=2)
            destination.write("\n")
        with (output / "SHA256SUMS.txt").open("x", encoding="utf-8", newline="\n") as destination:
            destination.write(f"{receipt['sha256']}  {archive.name}\n")
            destination.write(f"{sha256_file(receipt_path)}  {receipt_path.name}\n")
        return receipt
    except BaseException:
        # Only this invocation's exclusive archive is removed; never clean an
        # existing output tree or any input directory on failure.
        if created_archive and archive.is_file() and not archive.is_symlink():
            archive.unlink()
        raise


class _HashingReader:
    def __init__(self, source):
        self.source = source
        self.digest = hashlib.sha256()

    def read(self, size=-1):
        data = self.source.read(size)
        self.digest.update(data)
        return data


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build-number", type=int, required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--source-fingerprint", required=True)
    parser.add_argument("--license", dest="license_path", type=Path, required=True)
    parser.add_argument("--notices", dest="notices_path", type=Path, required=True)
    parser.add_argument("--epoch", type=int, default=0)
    args = parser.parse_args(argv)
    try:
        receipt = package_portable(**vars(args))
    except (OSError, ValueError) as error:
        parser.exit(2, f"Steam Deck TEST packaging failed: {error}\n")
    print(json.dumps(receipt, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
