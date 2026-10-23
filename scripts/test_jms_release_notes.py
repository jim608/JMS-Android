from pathlib import Path
import re
import tempfile
import unittest

from jms_release_notes import release_notes_for, require_current_notes, validate_release_notes
class ReleaseNotesTests(unittest.TestCase):
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
        self.assertIn('https://jellyseer.jms.example.invalid', historical)
        self.assertNotIn('## English', historical)
        self.assertIn('## English', current)
        self.assertEqual(current, validate_release_notes(
            current, version.group(1), require_english=True))
        self.assertNotIn('先前的 `.10` 測試版', current)

    def test_bilingual_change_only_release_does_not_invent_an_added_section(self):
        with tempfile.TemporaryDirectory() as directory:
            changelog = Path(directory) / 'CHANGELOG.md'
            english = Path(directory) / 'CHANGELOG.en.md'
            version = '0.11.1-jms.44'
            changelog.write_text(
                '# JMS ' + version + '\n\n## 調整\n- 改善介面排版。\n', encoding='utf-8')
            english.write_text(
                '# JMS ' + version + '\n\n## Changed\n- Improve interface typography.\n', encoding='utf-8')
            notes = release_notes_for(changelog, version, english_changelog=english, require_english=True)
            self.assertEqual(notes, validate_release_notes(notes, version, require_english=True))
            self.assertIn('### 調整\n', notes)
            self.assertIn('### Changed\n', notes)
            self.assertNotIn('### Added', notes)
            english.write_text(
                '# JMS ' + version + '\n\n## Changed\n- Improve interface typography.\n- Add an unmatched item.\n',
                encoding='utf-8')
            with self.assertRaises(ValueError):
                release_notes_for(changelog, version, english_changelog=english, require_english=True)

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
