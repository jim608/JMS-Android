from pathlib import Path
import re
import tempfile
import unittest

from jms_release_notes import release_notes_for, require_current_notes, validate_release_notes
from correct_jms_release_description import correct_description


class FakeReleaseApi:
    def __init__(self):
        self.calls = []
        self.release = {
            'id': 7, 'tag_name': 'v0.11.1-jms.11', 'name': 'Old title', 'body': 'Old notes',
            'draft': False, 'prerelease': True, 'html_url': 'https://example.invalid/release',
            'assets': [
                {'id': 1, 'name': 'update.json', 'size': 10, 'digest': 'sha256:abc'},
                {'id': 2, 'name': 'JMS-Android-0.11.1-jms.11-release-arm64-test-signed.apk', 'size': 20,
                 'digest': 'sha256:def'},
            ],
        }

    def api(self, endpoint, method='GET', payload=None):
        self.calls.append((endpoint, method, payload))
        if method == 'PATCH':
            self.release.update(payload)
        return self.release.copy()


class ReleaseNotesTests(unittest.TestCase):
    def test_correction_only_changes_existing_release_title_and_body(self):
        github = FakeReleaseApi()
        url, changed = correct_description(github, '0.11.1-jms.11', '# JMS 0.11.1-jms.11\n', False)
        self.assertTrue(changed)
        self.assertEqual(len(github.calls), 1)
        self.assertEqual(url, github.release['html_url'])
        original_assets = github.release['assets'].copy()
        _, changed = correct_description(github, '0.11.1-jms.11', '# JMS 0.11.1-jms.11\n', True)
        self.assertTrue(changed)
        self.assertEqual(github.calls[-1][2], {'name': 'JMS 0.11.1-jms.11', 'body': '# JMS 0.11.1-jms.11\n'})
        self.assertEqual(github.release['assets'], original_assets)
        self.assertEqual(correct_description(github, '0.11.1-jms.11', '# JMS 0.11.1-jms.11\n', True)[1], False)

    def test_current_notes_are_exactly_one_version_from_changelog(self):
        root = Path(__file__).resolve().parents[1]
        version = re.search(r'^version:\s*([^\s+]+)\+\d+$',
                            (root / 'pubspec.yaml').read_text(encoding='utf-8'), re.MULTILINE)
        self.assertIsNotNone(version)
        current = release_notes_for(root / 'CHANGELOG.md', version.group(1))
        self.assertEqual(current, require_current_notes(
            root / 'CHANGELOG.md', root / 'docs/JMS_RELEASE_NOTES.zh-Hant.md', version.group(1)))
        prior = release_notes_for(root / 'CHANGELOG.md', '0.11.1-jms.12')
        self.assertTrue(prior.startswith('# JMS 0.11.1-jms.12\n'))
        historical = release_notes_for(root / 'CHANGELOG.md', '0.11.1-jms.11')
        self.assertTrue(historical.startswith('# JMS 0.11.1-jms.11\n'))
        self.assertIn('https://legacy-seerr.example.invalid', historical)
        self.assertNotIn('先前的 `.10` 測試版', current)

    def test_mismatched_version_or_drift_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            changelog = Path(directory) / 'CHANGELOG.md'
            notes = Path(directory) / 'notes.md'
            changelog.write_text('# JMS 0.11.1-jms.12\n\n## 修正\n- 修正點片網址。\n', encoding='utf-8')
            notes.write_text('# JMS 0.11.1-jms.11\n\n## 修正\n- 修正點片網址。\n', encoding='utf-8')
            with self.assertRaises(ValueError):
                require_current_notes(changelog, notes, '0.11.1-jms.12')
            with self.assertRaises(ValueError):
                release_notes_for(changelog, '0.11.1-jms.11')

    def test_internal_reports_placeholders_paths_and_secrets_are_rejected(self):
        valid = '# JMS 0.11.1-jms.12\n\n## 修正\n- 修正點片網址。\n'
        for text in ('PASS', '我已完成', 'TODO', 'D:' + '\\private\\file',
                     'ghp_' + 'abcdefghijklmnopqrstuvwxyz1234567890',
                     'https://' + 'user:password@example.invalid'):
            with self.subTest(text=text):
                with self.assertRaises(ValueError):
                    validate_release_notes(valid + '\n## 已知問題\n- ' + text + '。\n', '0.11.1-jms.12')
        with self.assertRaises(ValueError):
            validate_release_notes(valid + '\n## 移除\n', '0.11.1-jms.12')
        with self.assertRaises(ValueError):
            validate_release_notes(valid + '\n## 新增\n- 未實作。\n', '0.11.1-jms.12')


if __name__ == '__main__':
    unittest.main()
