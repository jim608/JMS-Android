"""Pure synthetic fixtures; these tests never execute a JMS binary or use a profile."""

import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import shlex
import stat
import struct
import subprocess
import tarfile
import tempfile
import unittest
from unittest import mock

import package_jms_steamdeck as package


def synthetic_elf(*, machine=62, elf_class=2, endian=1, elf_type=3, os_abi=0):
    # Deliberately non-executable test data: an ELF header and a marker, no code.
    ident = b"\x7fELF" + bytes((elf_class, endian, 1, os_abi)) + b"\0" * 8
    return struct.pack("<16sHHIQQQIHHHHHH", ident, elf_type, machine, 1, 0, 0, 0, 0,
                       64, 0, 0, 0, 0, 0) + b"SYNTHETIC-NOT-A-PROGRAM"


class SteamDeckPackageTests(unittest.TestCase):
    def setUp(self):
        project = Path(__file__).resolve().parent.parent
        fixtures = (project / "build/steamdeck-test-fixtures").resolve()
        if not fixtures.is_relative_to(project):
            raise RuntimeError("Fixture root escaped the workspace")
        fixtures.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="package-", dir=fixtures)
        self.root = Path(self.temp.name)
        if not self.root.resolve().is_relative_to(fixtures):
            raise RuntimeError("Temporary fixture escaped its verified root")
        self.addCleanup(self.temp.cleanup)
        self.bundle = self.root / "release" / "bundle"
        self.files = {
            "jms": synthetic_elf(elf_type=2),
            "lib/libapp.so": synthetic_elf() + b"AOT",
            "lib/libflutter_linux_gtk.so": synthetic_elf() + b"ENGINE",
            "lib/libfixture_plugin.so": synthetic_elf() + b"PLUGIN",
            "data/icudtl.dat": b"synthetic-icu",
            "data/flutter_assets/AssetManifest.bin": b"synthetic-assets",
            "data/flutter_assets/NOTICES.Z": b"synthetic-flutter-notices",
            "data/flutter_assets/assets/fixture.txt": b"asset bytes\x00\xff",
        }
        for name, data in self.files.items():
            path = self.bundle / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        self.license = self.root / "LICENSE"
        self.license.write_bytes(b"GNU GENERAL PUBLIC LICENSE\nVersion 3, 29 June 2007\nfixture\n")
        self.notices = self.root / "native-notices.txt"
        self.notices.write_bytes(b"JMS Android native components - SYNTHETIC supplied notice\n")
        self.output = self.root / "output"

    def arguments(self, **overrides):
        values = dict(bundle=self.bundle, output=self.output, version="0.11.1-jms.45", build_number=47,
                      source_commit="b" * 40, source_fingerprint="a" * 64,
                      license_path=self.license, notices_path=self.notices)
        values.update(overrides)
        return values

    def build(self, **overrides):
        return package.package_portable(**self.arguments(**overrides))

    def reject(self, **overrides):
        with self.assertRaises((ValueError, OSError)):
            self.build(**overrides)
        self.assertFalse(self.output.exists())

    def read_archive(self, receipt, output=None):
        output = output or self.output
        with tarfile.open(output / receipt["artifact"], "r:gz") as archive:
            prefix = receipt["artifact"][:-len(".tar.gz")] + "/"
            return {member.name[len(prefix):]: archive.extractfile(member).read()
                    for member in archive.getmembers() if member.isfile()}

    def test_preserves_raw_bundle_and_declared_source_identity(self):
        before = {name: path.read_bytes() for name, path in
                  ((name, self.bundle / name) for name in self.files)}
        receipt = self.build()
        self.assertTrue(receipt["artifact"].startswith("JMS-SteamDeck-TEST-"))
        self.assertIn("linux-x64-aaaaaaaaaaaa.tar.gz", receipt["artifact"])
        contents = self.read_archive(receipt)
        for name, expected in before.items():
            self.assertEqual(contents[name], expected)
            self.assertEqual((self.bundle / name).read_bytes(), expected)
        self.assertEqual(contents["LICENSE"], self.license.read_bytes())
        self.assertEqual(contents["notices/PROVIDED-NATIVE-NOTICES.txt"], self.notices.read_bytes())
        metadata = json.loads(contents["JMS_STEAMDECK_TEST.json"])
        self.assertEqual(metadata["baseSourceCommit"], "b" * 40)
        self.assertEqual(metadata["sourceFingerprint"], "a" * 64)
        self.assertEqual(metadata["launcherArguments"], ["--handheld", "--skipNotifications"])
        for field in ("steamOsRuntimeVerified", "fullySelfContained", "nativeLinuxRawAxisImplemented",
                      "nativeLicenseClosureVerified", "sessionKeyringAndIpcIsolated", "installerIncluded",
                      "updateFeedIncluded"):
            self.assertFalse(metadata[field], field)
        self.assertEqual(metadata["bundleFingerprint"], hashlib.sha256(package.canonical(metadata["bundleFiles"])).hexdigest())
        for name in ("README-STEAMDECK-TEST.md", "JMS_STEAMDECK_TEST.json", "STEAMDECK_TEST_NOTICES.txt"):
            self.assertNotIn(str(self.root).encode(), contents[name])
        readme = contents["README-STEAMDECK-TEST.md"].decode()
        for text in ("Enter", "Escape", "arrow keys", "NOT fully self-contained", "shared keyring", "raw",
                     "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS", "does not establish Linux"):
            self.assertIn(text, readme)

    def test_archive_has_safe_members_modes_and_complete_checksums(self):
        receipt = self.build(epoch=123456789)
        contents = self.read_archive(receipt)
        sums = dict(line.split("  ", 1)[::-1] for line in contents["SHA256SUMS.txt"].decode().splitlines())
        self.assertEqual(set(sums), set(contents) - {"SHA256SUMS.txt"})
        for name, digest in sums.items():
            self.assertEqual(hashlib.sha256(contents[name]).hexdigest(), digest)
        with tarfile.open(self.output / receipt["artifact"]) as archive:
            for member in archive:
                self.assertFalse(member.issym() or member.islnk())
                self.assertFalse(member.name.startswith("/"))
                self.assertNotIn("..", Path(member.name).parts)
                self.assertEqual((member.uid, member.gid, member.mtime), (0, 0, 123456789))
                expected_mode = 0o755 if member.isdir() or member.name.endswith(("/jms", "/Launch-JMS-SteamDeck.sh")) else 0o644
                self.assertEqual(member.mode, expected_mode)
        for line in (self.output / "SHA256SUMS.txt").read_text().splitlines():
            digest, name = line.split("  ", 1)
            self.assertEqual(package.sha256_file(self.output / name), digest)

    def test_archive_is_deterministic_even_when_input_mtimes_change(self):
        first = self.build()
        for name in self.files:
            os.utime(self.bundle / name, (987654321, 987654321))
        second_output = self.root / "other-output"
        second = self.build(output=second_output)
        self.assertEqual(first, second)
        self.assertEqual((self.output / first["artifact"]).read_bytes(), (second_output / second["artifact"]).read_bytes())

    def test_refuses_each_missing_required_file(self):
        for name in package.REQUIRED_FILES:
            with self.subTest(name=name):
                path = self.bundle / name
                data = path.read_bytes()
                path.unlink()
                self.reject()
                path.write_bytes(data)

    def test_refuses_missing_assets_and_empty_icu(self):
        for name in list(self.files):
            if name.startswith("data/flutter_assets/"):
                (self.bundle / name).unlink()
        self.reject()
        (self.bundle / "data/flutter_assets/fixture").write_bytes(b"asset")
        (self.bundle / "data/icudtl.dat").write_bytes(b"")
        self.reject()

    def test_rejects_wrong_elf_platform_or_header(self):
        variants = [synthetic_elf(machine=183), synthetic_elf(elf_class=1), synthetic_elf(endian=2),
                    synthetic_elf(elf_type=1), synthetic_elf(os_abi=9), b"\x7fELF", b"MZ-Windows-PE"]
        for data in variants:
            with self.subTest(header=data[:20]):
                (self.bundle / "jms").write_bytes(data)
                self.reject()

    def test_checks_plugin_elf_content_and_not_only_required_files(self):
        (self.bundle / "lib/libfixture_plugin.so").write_bytes(synthetic_elf(machine=183))
        self.reject()

    def test_rejects_text_disguised_as_a_shared_library(self):
        (self.bundle / "lib/libapp.so").write_bytes(b"not an ELF library")
        self.reject()

    def test_rejects_windows_names_and_pe_without_an_extension(self):
        for name, data in (("extra.exe", synthetic_elf()), ("lib/win.dll", b"MZ-fixture"), ("renamed", b"MZ-fixture")):
            with self.subTest(name=name):
                path = self.bundle / name
                path.write_bytes(data)
                self.reject()
                path.unlink()

    def test_rejects_debug_and_local_state_artifacts(self):
        for name in ("kernel_blob.bin", "app.dill", "vm_snapshot_data", "isolate_snapshot_data", "jms.debug",
                     "debug/fixture", "profile/fixture", "bundle.dSYM/fixture", ".jms-steamdeck-test/config"):
            with self.subTest(name=name):
                path = self.bundle / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"synthetic debug or state data")
                self.reject()
                path.unlink()
                if path.parent != self.bundle:
                    path.parent.rmdir()

    def test_rejects_debug_build_directory_even_with_aot_named_files(self):
        debug_bundle = self.root / "debug" / "bundle"
        debug_bundle.parent.mkdir()
        # No moving/deleting a real tree: use the same synthetic fixture files.
        for name, data in self.files.items():
            path = debug_bundle / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        self.reject(bundle=debug_bundle)

    def test_rejects_unsafe_archive_paths_without_creating_them(self):
        for name in ("../escape", "/absolute", "a\\b", "C:escape", "new\nline", "trailing.", "space ", "CON.txt"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                package.safe_relative(name)

    def test_rejects_symlinks(self):
        link = self.bundle / "lib/escape.so"
        try:
            link.symlink_to(self.license)
        except OSError:
            self.skipTest("Host does not permit synthetic symlink creation")
        self.reject()

    def test_rejects_windows_reparse_points_without_needing_a_real_junction(self):
        original = Path.lstat

        def reparse(path):
            value = original(path)
            if path == self.bundle / "jms":
                return type("ReparseStat", (), {"st_mode": value.st_mode, "st_file_attributes": 0x400})()
            return value

        with mock.patch.object(Path, "lstat", reparse):
            self.reject()

    def test_rejects_hardlink_aliases(self):
        alias = self.bundle / "alias"
        try:
            os.link(self.bundle / "jms", alias)
        except OSError:
            self.skipTest("Host does not permit synthetic hardlinks")
        self.reject()

    @unittest.skipUnless(hasattr(os, "mkfifo"), "FIFO fixtures require a POSIX host")
    def test_rejects_special_files(self):
        os.mkfifo(self.bundle / "fixture-fifo")
        self.reject()

    def test_refuses_existing_output_without_touching_any_bytes(self):
        receipt = self.build()
        before = {path.name: path.read_bytes() for path in self.output.iterdir()}
        with self.assertRaises(ValueError):
            self.build()
        self.assertEqual(before, {path.name: path.read_bytes() for path in self.output.iterdir()})
        self.assertEqual(package.sha256_file(self.output / receipt["artifact"]), receipt["sha256"])

    def test_refuses_output_inside_bundle_and_parent_traversal(self):
        self.reject(output=self.bundle / "new-output")
        self.reject(bundle=self.bundle / ".." / "bundle")
        self.reject(output=self.root / "missing-parent" / "output")

    def test_refuses_generated_metadata_collisions(self):
        for name in ("README-STEAMDECK-TEST.md", "readme-steamdeck-test.MD", "notices/untrusted.txt"):
            with self.subTest(name=name):
                path = self.bundle / name
                path.parent.mkdir(exist_ok=True)
                path.write_bytes(b"collision")
                self.reject()
                path.unlink()
                if path.parent != self.bundle:
                    path.parent.rmdir()

    def test_refuses_inconsistent_license_and_empty_notices(self):
        (self.bundle / "LICENSE").write_bytes(b"different license")
        self.reject()
        (self.bundle / "LICENSE").unlink()
        self.notices.write_bytes(b" \n")
        self.reject()

    def test_refuses_invalid_identity(self):
        for change in ({"version": "../escape"}, {"build_number": 0}, {"build_number": True},
                       {"source_commit": "short"}, {"source_fingerprint": "short"}, {"epoch": -1}):
            with self.subTest(change=change):
                self.reject(**change)

    def test_source_mutation_fails_without_leaving_a_finished_archive(self):
        inspect = package.inspect_bundle

        def mutate(value):
            result = inspect(value)
            path = self.bundle / "jms"
            data = path.read_bytes()
            path.write_bytes(data[:-1] + b"!")
            return result

        with mock.patch.object(package, "inspect_bundle", side_effect=mutate):
            with self.assertRaisesRegex(ValueError, "changed during packaging"):
                self.build()
        self.assertEqual(list(self.output.glob("*.tar.gz")), [])
        self.assertFalse((self.output / "delivery-receipt.json").exists())

    def test_cli_uses_only_explicit_inputs(self):
        args = ["--bundle", str(self.bundle), "--output", str(self.output), "--version", "0.11.1-jms.45",
                "--build-number", "47", "--source-commit", "b" * 40, "--source-fingerprint", "a" * 64,
                "--license", str(self.license), "--notices", str(self.notices)]
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            self.assertEqual(package.main(args), 0)
        self.assertFalse(json.loads(stdout.getvalue())["steamOsRuntimeVerified"])

    def test_synthetic_launcher_preserves_arguments_and_only_changes_file_state_environment(self):
        if os.name == "nt":
            candidates = [Path("C:/Program Files/Git/bin/bash.exe"), Path("C:/Program Files/Git/usr/bin/bash.exe")]
            shell = next((path for path in candidates if path.is_file()), None)
            if shell is None:
                self.skipTest("Git Bash unavailable; no WSL or tool installation fallback")
            shell_args = [str(shell), "--noprofile", "--norc"]
        else:
            shell_args = ["/bin/sh"]
        fixture = self.root / "fake launcher with spaces"
        fixture.mkdir()
        launcher = fixture / "Launch-JMS-SteamDeck.sh"
        launcher.write_bytes(package.launcher_bytes())
        # A new shell stub in an independent temp directory, never the ELF
        # fixture from an archive and never a user-installed JMS executable.
        stub = fixture / "jms"
        stub.write_text("#!/bin/sh\nprintf '%s\\0' \"$@\" > argv.bin\n"
                        "printf '%s\\0' \"$PWD\" \"$XDG_CONFIG_HOME\" \"$XDG_DATA_HOME\" "
                        "\"$XDG_CACHE_HOME\" \"$TMPDIR\" \"$XDG_RUNTIME_DIR\" \"$DBUS_SESSION_BUS_ADDRESS\" > env.bin\n",
                        encoding="utf-8", newline="\n")
        stub.chmod(0o755)
        args = ["two words", "$(touch forbidden)", "semi;colon", "line\nbreak", "quote'\"literal"]
        # Enter the Linux/POSIX argv contract from a shell caller. Passing these
        # edge cases through Windows CreateProcess -> MSYS argv conversion would
        # test that unrelated conversion rather than the portable launcher's $@.
        caller = fixture / "synthetic-caller.sh"
        caller.write_text("#!/bin/sh\nexec ./Launch-JMS-SteamDeck.sh " +
                          " ".join(shlex.quote(value) for value in args) + "\n", encoding="utf-8", newline="\n")
        env = os.environ.copy()
        env.pop("BASH_ENV", None)
        env.pop("ENV", None)
        env.update(XDG_RUNTIME_DIR="runtime-sentinel", DBUS_SESSION_BUS_ADDRESS="bus-sentinel")
        result = subprocess.run([*shell_args, "./synthetic-caller.sh"], cwd=fixture, env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        captured = (fixture / "argv.bin").read_bytes().split(b"\0")[:-1]
        self.assertEqual(captured, [value.encode() for value in ["--handheld", "--skipNotifications", *args]])
        values = (fixture / "env.bin").read_bytes().decode().split("\0")[:-1]
        for value, suffix in zip(values[1:5], ("config", "data", "cache", "tmp")):
            self.assertTrue(value.endswith("/.jms-steamdeck-test/" + suffix), value)
        self.assertEqual(values[5:], ["runtime-sentinel", "bus-sentinel"])
        self.assertFalse((fixture / "forbidden").exists())
        self.assertTrue((fixture / ".jms-steamdeck-test/tmp").is_dir())


if __name__ == "__main__":
    unittest.main()
