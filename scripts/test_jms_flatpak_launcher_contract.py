"""Launcher fixtures only: never call Flatpak or inspect user application data."""
import configparser
import re
import shlex
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import yaml

import package_jms_flatpak as package


ROOT = Path(__file__).resolve().parents[1]
APP = 'com.jim608.jms'


class FlatpakLauncherContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        script = (ROOT / 'scripts/test_jms_flatpak.sh').read_text(encoding='utf-8')
        cls.validator = script.split("<<'PY_DESKTOP'\n", 1)[1].split('\nPY_DESKTOP\n', 1)[0]

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='jms-launcher-contract-')
        self.workspace = Path(temporary.name).resolve()
        self.assertTrue(self.workspace.is_relative_to(Path(tempfile.gettempdir()).resolve()))
        self.addCleanup(temporary.cleanup)
        self.exports = self.workspace / 'exports'
        self.exports.mkdir()
        self.canonical = self.exports / f'{APP}.desktop'
        self.legacy = self.exports / f'{APP}.SteamDeck.desktop'
        self.write_current_exports()

    @staticmethod
    def entry(path):
        parsed = configparser.ConfigParser(interpolation=None)
        parsed.optionxform = str
        parsed.read(path, encoding='utf-8')
        return parsed

    def change(self, path, **changes):
        parsed = self.entry(path)
        for key, value in changes.items():
            parsed['Desktop Entry'][key] = value
        with path.open('w', encoding='utf-8') as stream:
            parsed.write(stream, space_around_delimiters=False)

    def write_current_exports(self):
        # Model Flatpak's documented Exec rewrite without invoking Flatpak.
        for name, target in [('JMS.desktop', self.canonical), ('JMS-SteamDeck.desktop', self.legacy)]:
            source = (ROOT / 'flatpak' / name).read_text(encoding='utf-8')
            command = shlex.split(re.search(r'^Exec=(.+)$', source, re.M)[1])
            exported = '/usr/bin/flatpak run --branch=stable --arch=x86_64 --command=jms ' + APP
            if command[1:]:
                exported += ' ' + shlex.join(command[1:])
            target.write_text(re.sub(r'^Exec=.+$', 'Exec=' + exported, source, flags=re.M), encoding='utf-8')

    def validate_exports(self):
        return subprocess.run(
            [sys.executable, '-c', self.validator, str(self.canonical), str(self.legacy), str(self.exports)],
            capture_output=True,
            text=True,
            timeout=10,
        ).returncode

    def test_current_rewritten_exports_have_one_visible_launcher_and_hidden_handheld_compatibility(self):
        self.assertEqual(self.validate_exports(), 0)
        canonical = self.entry(self.canonical)['Desktop Entry']
        legacy = self.entry(self.legacy)['Desktop Entry']
        self.assertFalse(canonical.getboolean('NoDisplay', fallback=False))
        self.assertNotIn('--handheld', shlex.split(canonical['Exec']))
        self.assertTrue(legacy.getboolean('NoDisplay'))
        self.assertIn('--handheld', shlex.split(legacy['Exec']))

    def test_export_validator_rejects_regressions_in_visibility_and_compatibility(self):
        mutations = [
            ('canonical hidden', 'canonical', {'NoDisplay': 'true'}),
            ('canonical handheld', 'canonical', {'Exec': f'/usr/bin/flatpak run {APP} --handheld'}),
            ('wrong canonical app', 'canonical', {'Exec': '/usr/bin/flatpak run org.example.Other'}),
            ('legacy visible', 'legacy', {'NoDisplay': 'false'}),
            ('legacy loses handheld', 'legacy', {'Exec': f'/usr/bin/flatpak run {APP}'}),
            ('wrong legacy app', 'legacy', {'Exec': '/usr/bin/flatpak run org.example.Other --handheld'}),
        ]
        for label, target, changes in mutations:
            with self.subTest(label=label):
                self.write_current_exports()
                self.change(getattr(self, target), **changes)
                self.assertNotEqual(self.validate_exports(), 0)

    def test_missing_legacy_or_extra_visible_managed_launcher_is_rejected(self):
        self.legacy.unlink()
        self.assertNotEqual(self.validate_exports(), 0)
        self.write_current_exports()
        extra = self.exports / f'{APP}.Old.desktop'
        extra.write_bytes(self.canonical.read_bytes())
        self.assertNotEqual(self.validate_exports(), 0)

    def test_unrelated_exported_applications_are_untouched(self):
        unrelated = self.exports / 'org.example.Other.desktop'
        content = '[Desktop Entry]\nName=Other\nExec=other\nType=Application\n'
        unrelated.write_text(content, encoding='utf-8')
        self.assertEqual(self.validate_exports(), 0)
        self.assertEqual(unrelated.read_text(encoding='utf-8'), content)

    def test_fixture_export_update_hides_old_menu_entry_without_deleting_legacy_or_user_shortcuts(self):
        # This is an export-byte transition fixture, not a real prior-version
        # Flatpak upgrade or desktop/Steam menu-cache verification.
        user_apps = self.workspace / 'user-applications'
        user_apps.mkdir()
        shortcut = user_apps / f'{APP}.MySteamShortcut.desktop'
        user_content = '[Desktop Entry]\nName=My shortcut\nExec=fixture-game --handheld\n'
        shortcut.write_text(user_content, encoding='utf-8')
        self.change(self.legacy, NoDisplay='false')
        self.assertNotEqual(self.validate_exports(), 0)
        self.write_current_exports()
        self.assertEqual(self.validate_exports(), 0)
        self.assertTrue(self.legacy.is_file())
        self.assertEqual(shortcut.read_text(encoding='utf-8'), user_content)

    def test_package_stage_preserves_both_launcher_sources_and_exact_manifest_install_names(self):
        canonical = self.entry(ROOT / 'flatpak/JMS.desktop')['Desktop Entry']
        legacy = self.entry(ROOT / 'flatpak/JMS-SteamDeck.desktop')['Desktop Entry']
        self.assertEqual(shlex.split(canonical['Exec']), ['jms'])
        self.assertEqual(shlex.split(legacy['Exec']), ['jms', '--handheld'])
        source = self.workspace / 'source'
        (source / 'flatpak').mkdir(parents=True)
        (source / 'icons/jms').mkdir(parents=True)
        (source / 'pubspec.yaml').write_text('version: 0.0.1+1\n', encoding='utf-8')
        (source / 'LICENSE').write_text('Fixture license\n', encoding='utf-8')
        (source / 'icons/jms/mark.svg').write_text('<svg/>\n', encoding='utf-8')
        (source / 'flatpak/com.jim608.jms.metainfo.xml').write_text(
            f'<component><id>{APP}</id><releases><release version="0.0.1"/></releases></component>',
            encoding='utf-8',
        )
        for name in ('JMS.desktop', 'JMS-SteamDeck.desktop', 'com.jim608.jms.yaml'):
            (source / 'flatpak' / name).write_bytes((ROOT / 'flatpak' / name).read_bytes())
        bundle = self.workspace / 'bundle'
        (bundle / 'lib').mkdir(parents=True)
        (bundle / 'jms').write_bytes(b'fixture executable')
        (bundle / 'lib/libapp.so').write_bytes(b'fixture AOT')
        staged = self.workspace / 'staged'
        with mock.patch.object(package, 'ROOT', source):
            package.stage(bundle, staged, 'a' * 40)
        for name in ('JMS.desktop', 'JMS-SteamDeck.desktop'):
            self.assertEqual((staged / name).read_bytes(), (ROOT / 'flatpak' / name).read_bytes())
        manifest = yaml.safe_load((staged / 'com.jim608.jms.yaml').read_text(encoding='utf-8'))
        module = next(item for item in manifest['modules'] if item['name'] == 'jms')
        installs = [command for command in module['build-commands'] if '/share/applications/' in command]
        self.assertEqual(installs, [
            'install -Dm644 JMS.desktop /app/share/applications/${FLATPAK_ID}.desktop',
            'install -Dm644 JMS-SteamDeck.desktop /app/share/applications/${FLATPAK_ID}.SteamDeck.desktop',
        ])
        file_sources = {item.get('path') for item in module['sources'] if item['type'] == 'file'}
        self.assertTrue({'JMS.desktop', 'JMS-SteamDeck.desktop'}.issubset(file_sources))


if __name__ == '__main__':
    unittest.main()
