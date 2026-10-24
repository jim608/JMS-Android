import hashlib
import json
from pathlib import Path
import tempfile
import subprocess
import unittest
from unittest import mock

import build_jms_steamdeck_local as build


class LocalDeckBuildTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture_parent = (Path(__file__).resolve().parent.parent / 'build/steamdeck-test-fixtures').resolve()
        cls.fixture_parent.mkdir(parents=True, exist_ok=True)

    def test_exact_source_and_tamper(self):
        with tempfile.TemporaryDirectory(dir=self.fixture_parent) as value:
            root = Path(value)
            self.assertTrue(root.resolve().is_relative_to(self.fixture_parent))
            (root / 'synthetic.dart').write_text('FAKE SOURCE', encoding='utf-8')
            files = {'synthetic.dart': build.digest(root / 'synthetic.dart')}
            fingerprint = hashlib.sha256(json.dumps(files, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
            manifest = {'files': files, 'source_fingerprint': fingerprint}
            self.assertEqual(build.verify_source(root, manifest), fingerprint)
            (root / 'synthetic.dart').write_text('MODIFIED FAKE', encoding='utf-8')
            with self.assertRaisesRegex(ValueError, 'SHA mismatch'):
                build.verify_source(root, manifest)

    def test_rejects_escaping_member(self):
        with tempfile.TemporaryDirectory(dir=self.fixture_parent) as value:
            self.assertTrue(Path(value).resolve().is_relative_to(self.fixture_parent))
            with self.assertRaisesRegex(ValueError, 'Unsafe'):
                build.verify_source(Path(value), {'files': {'../fake': '0' * 64}})

    def test_non_linux_fails_before_command_execution(self):
        with mock.patch.object(build.platform, 'system', return_value='Windows'), mock.patch.object(build.platform, 'machine', return_value='AMD64'), mock.patch.object(build.subprocess, 'run') as run:
            result = build.preflight()
        self.assertFalse(result['ready'])
        self.assertIn('existing Linux x86-64 build environment', result['missing'])
        run.assert_not_called()

    def test_missing_linux_tools_does_not_install(self):
        with mock.patch.object(build.platform, 'system', return_value='Linux'), mock.patch.object(build.platform, 'machine', return_value='x86_64'), mock.patch.object(build, 'isolated_network', return_value=True), mock.patch.object(build.shutil, 'which', return_value=None), mock.patch.object(build.subprocess, 'run') as run:
            result = build.preflight()
        self.assertFalse(result['ready'])
        self.assertFalse(result['install_attempted'])
        self.assertIn('clang++', result['missing'])
        run.assert_not_called()

    def test_existing_linux_sdk_preflight_and_uncached_engine(self):
        with tempfile.TemporaryDirectory(dir=self.fixture_parent) as value:
            root = Path(value)
            self.assertTrue(root.resolve().is_relative_to(self.fixture_parent))
            tool = root / 'bin/flutter'
            tool.parent.mkdir()
            tool.write_text('FAKE TOOL, NEVER EXECUTED', encoding='utf-8')
            def fake_run(command, **kwargs):
                return subprocess.CompletedProcess(command, 0, json.dumps({'frameworkRevision': build.FLUTTER_REVISION}) if command[0] == 'flutter' else '')
            with mock.patch.object(build.platform, 'system', return_value='Linux'), mock.patch.object(build.platform, 'machine', return_value='x86_64'), mock.patch.object(build, 'isolated_network', return_value=True), mock.patch.object(build.shutil, 'which', return_value=str(tool)), mock.patch.object(build.subprocess, 'run', side_effect=fake_run) as run:
                missing = build.preflight()
                self.assertFalse(missing['ready'])
                self.assertTrue(any('gen_snapshot' in x for x in missing['missing']))
                run.assert_not_called()
                for name in ['bin/cache/dart-sdk/bin/dart', 'bin/cache/flutter_tools.snapshot', 'packages/flutter_tools/.dart_tool/package_config.json', 'bin/cache/artifacts/engine/linux-x64-release/gen_snapshot', 'bin/cache/artifacts/engine/linux-x64-release/libflutter_linux_gtk.so', 'bin/cache/artifacts/engine/linux-x64/icudtl.dat', 'bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf', 'bin/cache/artifacts/engine/linux-x64/flutter_linux/flutter_linux.h']:
                    path = root / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text('FAKE CACHE FILE', encoding='utf-8')
                (root / 'bin/cache/flutter.version.json').write_text(json.dumps({'frameworkRevision': build.FLUTTER_REVISION}), encoding='utf-8')
                ready = build.preflight()
                self.assertTrue(ready['ready'])
                self.assertFalse(ready['install_attempted'])
                self.assertTrue(all(call.args[0][0] == 'pkg-config' for call in run.call_args_list))

    def test_network_guard_does_not_change_network(self):
        with mock.patch.object(build.platform, 'system', return_value='Linux'), mock.patch.object(build.platform, 'machine', return_value='x86_64'), mock.patch.object(build, 'isolated_network', return_value=False), mock.patch.object(build.subprocess, 'run') as run:
            result = build.preflight()
        self.assertFalse(result['ready'])
        self.assertTrue(any('network-isolated' in x for x in result['missing']))
        run.assert_not_called()

    def test_existing_cmake_cache_preserved_before_preflight(self):
        with tempfile.TemporaryDirectory(dir=self.fixture_parent) as value:
            root = Path(value)
            self.assertTrue(root.resolve().is_relative_to(self.fixture_parent))
            (root / 'synthetic.dart').write_text('FAKE', encoding='utf-8')
            files = {'synthetic.dart': build.digest(root / 'synthetic.dart')}
            fingerprint = hashlib.sha256(json.dumps(files, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
            manifest = root / 'manifest.json'
            manifest.write_text(json.dumps({'files': files, 'source_fingerprint': fingerprint}), encoding='utf-8')
            cache = root / 'build/linux/x64/CMakeCache.txt'
            cache.parent.mkdir(parents=True)
            cache.write_text('FAKE PRIOR CACHE', encoding='utf-8')
            with mock.patch.object(build, 'preflight') as preflight:
                with self.assertRaisesRegex(ValueError, 'Existing Linux CMake cache'):
                    build.main(['--source', str(root), '--manifest', str(manifest), '--output', str(root / 'new-output'), '--preflight-only'])
            preflight.assert_not_called()
            self.assertEqual(cache.read_text(encoding='utf-8'), 'FAKE PRIOR CACHE')


if __name__ == '__main__':
    unittest.main()
