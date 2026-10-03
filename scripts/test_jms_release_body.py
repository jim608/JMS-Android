"""Candidate provenance and safe resume checks for the existing publisher."""
import copy
import unittest

from jms_release_notes import release_body_for_candidate
from publish_jms_release import bind_release_body
from jms_publication import ReleaseError

VERSION = '0.11.1-jms.33'
SOURCE = '1' * 40
BUILD = 'JMS-0.11.1-jms.33-' + '2' * 12
NOTES = '# JMS 0.11.1-jms.33\n\n## 修正\n- 修正播放狀態顯示。\n'


class CandidateBodyTests(unittest.TestCase):
    def state(self):
        return {'sourceCommit': SOURCE, 'version': VERSION, 'notes': NOTES, 'canonicalNotes': NOTES}

    def record(self):
        return {'sourceCommit': SOURCE, 'version': VERSION, 'buildId': BUILD}

    def test_body_uses_candidate_source_and_build_not_tool_head(self):
        body = release_body_for_candidate(NOTES, VERSION, SOURCE, BUILD)
        self.assertIn('https://github.com/jim608/JMS-Android/tree/' + SOURCE, body)
        self.assertIn('來源提交：`' + SOURCE + '`', body)
        self.assertIn('建置識別：`' + BUILD + '`', body)
        self.assertTrue(body.startswith(NOTES.rstrip()))

    def test_binding_is_repeatable_without_duplicate_appendix(self):
        state, record = self.state(), self.record()
        bind_release_body(state, record)
        expected = state['notes']
        bind_release_body(state, record)
        self.assertEqual(state['notes'], expected)
        self.assertEqual(expected.count('來源提交：'), 1)

    def test_legacy_published_state_is_not_automatically_changed(self):
        state = self.state()
        del state['canonicalNotes']
        state.update(releaseId=1, published=True)
        before = copy.deepcopy(state)
        bind_release_body(state, self.record())
        self.assertEqual(state, before)

    def test_resumed_draft_with_different_body_is_rejected(self):
        state = self.state()
        state['releaseId'] = 1
        before = copy.deepcopy(state)
        with self.assertRaises(ReleaseError):
            bind_release_body(state, self.record())
        self.assertEqual(state, before)

    def test_resumed_draft_with_exact_body_is_retained(self):
        state = self.state()
        bind_release_body(state, self.record())
        state['releaseId'] = 1
        before = copy.deepcopy(state)
        bind_release_body(state, self.record())
        self.assertEqual(state, before)

    def test_source_or_version_mismatch_is_rejected(self):
        for field, value in [('sourceCommit', '3' * 40), ('version', '0.11.1-jms.31')]:
            with self.subTest(field=field):
                state, record = self.state(), self.record()
                record[field] = value
                with self.assertRaises(ReleaseError):
                    bind_release_body(state, record)

    def test_invalid_identity_and_build_version_are_rejected(self):
        for source, build in [('short', BUILD), (SOURCE, 'JMS-0.11.1-jms.31-' + '2' * 12),
                              (SOURCE, '../TEST_ONLY_FILENAME')]:
            with self.subTest(source=source, build=build):
                with self.assertRaises(ValueError):
                    release_body_for_candidate(NOTES, VERSION, source, build)

    def test_internal_report_cannot_become_canonical_body(self):
        with self.assertRaises(ValueError):
            release_body_for_candidate(NOTES + '\n## 已知問題\n- PASS。\n', VERSION, SOURCE, BUILD)


if __name__ == '__main__':
    unittest.main()
