import json
import io
from pathlib import Path
import tempfile
import unittest
import zipfile

from jms_release_notes import (release_notes_for, validate_release_notes, release_body_for_candidate,
                               release_notes_from_archive)
from prepare_jms_release import validate_source_name
from prepare_jms_flatpak_release import canonical_source_notes


VERSION = '0.11.1-jms.42'
CHINESE = f'# JMS {VERSION}\n\n## 新增\n- 新增字幕調整。\n\n## 修正\n- 修正字幕載入。\n'
ENGLISH = f'# JMS {VERSION}\n\n## Added\n- Add subtitle timing controls.\n\n## Fixed\n- Fix subtitle loading.\n'


class BilingualNotesTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.changelog = self.root / 'CHANGELOG.md'
        self.english = self.root / 'CHANGELOG.en.md'
        self.changelog.write_text(CHINESE, encoding='utf-8')
        self.english.write_text(ENGLISH, encoding='utf-8')
        (self.root / 'config').mkdir()
        (self.root / 'config/jms_release_notes.json').write_text(json.dumps({
            'schemaVersion': 1, 'englishRequiredFrom': VERSION,
        }), encoding='utf-8')

    def render(self):
        return release_notes_for(self.changelog, VERSION)

    def test_aligned_bilingual_render_preserves_bullets_and_candidate_footer(self):
        result = self.render()
        self.assertIn('## 繁體中文 / Traditional Chinese\n\n### 新增\n- 新增字幕調整。', result)
        self.assertIn('## English\n\n### Added\n- Add subtitle timing controls.', result)
        self.assertEqual(validate_release_notes(result, VERSION, require_english=True), result)
        body = release_body_for_candidate(result, VERSION, '1' * 40, f'JMS-{VERSION}-' + '2' * 12)
        self.assertTrue(body.startswith(result))
        self.assertEqual(body.count('來源提交：'), 1)
        self.assertLess(len(body), 20000)

    def test_missing_or_wrong_version_english_cannot_fall_back_to_chinese(self):
        self.english.unlink()
        with self.assertRaises(ValueError):
            self.render()
        self.english.write_text(ENGLISH.replace(VERSION, '0.11.1-jms.41'), encoding='utf-8')
        with self.assertRaises(ValueError):
            self.render()

    def test_future_versions_are_required_and_historical_versions_remain_valid(self):
        for version, required in [('0.11.1-jms.9', False), ('0.11.1-jms.41', False), ('0.11.1-jms.100', True)]:
            with self.subTest(version=version):
                self.changelog.write_text(CHINESE.replace(VERSION, version), encoding='utf-8')
                if required:
                    with self.assertRaises(ValueError):
                        release_notes_for(self.changelog, version)
                else:
                    self.assertNotIn('## English', release_notes_for(self.changelog, version))

    def test_explicit_english_requirement_works_without_policy(self):
        (self.root / 'config/jms_release_notes.json').unlink()
        self.assertEqual(release_notes_for(self.changelog, VERSION), CHINESE)
        self.assertIn('## English', release_notes_for(self.changelog, VERSION, require_english=True))

    def test_invalid_english_structure_and_alignment_are_rejected(self):
        variants = [
            ENGLISH + '\n' + ENGLISH,
            ENGLISH.replace('## Added', '## New'),
            ENGLISH.replace('## Added', '## Fixed').replace('## Fixed\n- Fix', '## Added\n- Fix'),
            ENGLISH.replace('- Add subtitle timing controls.', ''),
            ENGLISH.replace('## Fixed\n- Fix subtitle loading.\n', ''),
            ENGLISH.replace('- Add subtitle timing controls.', '- Add subtitle timing controls.\n- Add more controls.'),
            ENGLISH.replace('loading.', 'loading'),
        ]
        for variant in variants:
            with self.subTest(variant=variant):
                self.english.write_text(variant, encoding='utf-8')
                with self.assertRaises(ValueError):
                    self.render()

    def test_english_sensitive_and_internal_content_are_rejected(self):
        for value in ('TODO', 'PASS', 'I have completed the release', 'test results',
                      'D:' + '\\private\\file', 'https://' + 'user:password@example.invalid',
                      'https://' + '192.168.1.2/service', 'http://' + 'localhost/service',
                      'ghp_' + 'abcdefghijklmnopqrstuvwxyz1234567890'):
            with self.subTest(value=value):
                self.english.write_text(ENGLISH.replace('Add subtitle timing controls', value), encoding='utf-8')
                with self.assertRaises(ValueError):
                    self.render()

    def test_bilingual_language_order_and_chinese_only_requirement_are_strict(self):
        result = self.render()
        for bad in (result.replace('## English', '## English\n\n## English'),
                    result.replace('## 繁體中文 / Traditional Chinese', '## English', 1),
                    result.replace('### 新增', '## 新增')):
            with self.subTest(bad=bad):
                with self.assertRaises(ValueError):
                    validate_release_notes(bad, VERSION, require_english=True)
        with self.assertRaises(ValueError):
            validate_release_notes(CHINESE, VERSION, require_english=True)

    def test_invalid_policy_is_not_ignored(self):
        for policy in ({'schemaVersion': 2, 'englishRequiredFrom': VERSION},
                       {'schemaVersion': 1, 'englishRequiredFrom': 'later'}, {'schemaVersion': 1}):
            (self.root / 'config/jms_release_notes.json').write_text(json.dumps(policy), encoding='utf-8')
            with self.assertRaises(ValueError):
                self.render()

    def test_candidate_source_archive_carries_exact_english_and_policy(self):
        self.assertTrue(validate_source_name('CHANGELOG.en.md'))
        self.assertFalse(validate_source_name('CHANGELOG.fr.md'))
        for include_english in (True, False):
            with io.BytesIO() as stream:
                with zipfile.ZipFile(stream, 'w') as archive:
                    archive.writestr('JMS/CHANGELOG.md', CHINESE)
                    archive.writestr('JMS/config/jms_release_notes.json', json.dumps({
                        'schemaVersion': 1, 'englishRequiredFrom': VERSION,
                    }))
                    if include_english:
                        archive.writestr('JMS/CHANGELOG.en.md', ENGLISH)
                with zipfile.ZipFile(stream) as archive:
                    if include_english:
                        self.assertEqual(release_notes_from_archive(archive, VERSION), self.render())
                    else:
                        with self.assertRaises(ValueError):
                            release_notes_from_archive(archive, VERSION)
        with io.BytesIO() as stream:
            with zipfile.ZipFile(stream, 'w') as archive:
                archive.writestr('JMS/CHANGELOG.md', CHINESE)
            with zipfile.ZipFile(stream) as archive:
                self.assertEqual(release_notes_from_archive(archive, VERSION), CHINESE)

    def test_existing_canonical_source_consumer_uses_same_archived_notes_policy(self):
        source = self.root / 'source.zip'
        commit = '1' * 40
        for bilingual in (True, False):
            with zipfile.ZipFile(source, 'w') as archive:
                archive.writestr('JMS/source-manifest.json', json.dumps({'sourceCommit': commit, 'dirty': False}))
                archive.writestr('JMS/pubspec.yaml', f'version: {VERSION}+44\n')
                archive.writestr('JMS/CHANGELOG.md', CHINESE)
                if bilingual:
                    archive.writestr('JMS/CHANGELOG.en.md', ENGLISH)
                    archive.writestr('JMS/config/jms_release_notes.json', json.dumps({
                        'schemaVersion': 1, 'englishRequiredFrom': VERSION,
                    }))
            self.assertEqual(canonical_source_notes(source, VERSION, commit), self.render() if bilingual else CHINESE)


if __name__ == '__main__':
    unittest.main()
