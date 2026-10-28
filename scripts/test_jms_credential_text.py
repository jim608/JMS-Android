"""Credential detection must not manufacture text across binary boundaries."""
import unittest

from check_jms_git_privacy import credential_url_or_header, findings


RULE = 'credential URL/header'


def url(user='fixture-user', password='fixture-password'):
    return 'https' + '://' + user + ':' + password + '@' + 'public.example.invalid/path'


def bearer(separator=' '):
    return 'Bearer' + separator + ('fixture-token-' * 2)


class CredentialTextTests(unittest.TestCase):
    def assert_credential(self, payload, expected=True, name='public.bin'):
        self.assertEqual(credential_url_or_header(name, payload), expected)
        self.assertEqual(RULE in findings(name, payload, []), expected)

    def test_contiguous_ascii_and_unicode_utf8_credentials_are_retained(self):
        for text in (url(), url('使用者', '密碼😀'), url('u', '\ufffd'), bearer(), bearer('\t')):
            with self.subTest(text_kind='unicode' if not text.isascii() else 'ascii'):
                self.assert_credential(text.encode('utf-8'))

    def test_real_wide_credentials_at_both_byte_alignments_are_retained(self):
        for encoding in ('utf-16-le', 'utf-16-be'):
            for alignment in (b'', b'\xff'):
                for text in (url(), url('使用者', '密碼😀'), bearer(), bearer('\t')):
                    with self.subTest(encoding=encoding, alignment=len(alignment), unicode=not text.isascii()):
                        self.assert_credential(alignment + text.encode(encoding) + b'\x00\x00')

    def test_wrapped_bearer_logs_remain_detected_in_all_encodings(self):
        for separator in ('\r\n  ', '\n\t', '\u2003'):
            text = bearer(separator)
            self.assert_credential(text.encode('utf-8'))
            for encoding in ('utf-16-le', 'utf-16-be'):
                for alignment in (b'', b'\xff'):
                    with self.subTest(separator=repr(separator), encoding=encoding, alignment=len(alignment)):
                        self.assert_credential(alignment + text.encode(encoding) + b'\x00\x00')

    def test_wide_bom_and_odd_trailing_binary_do_not_hide_real_credentials(self):
        for encoding, marker in (('utf-16-le', b'\xff\xfe'), ('utf-16-be', b'\xfe\xff')):
            for alignment in (b'', b'\xff'):
                with self.subTest(encoding=encoding, alignment=len(alignment)):
                    self.assert_credential(alignment + marker + url('使用者', '密碼😀').encode(encoding) + b'\x00\x00\xff')

    def test_nul_delimited_pool_fragments_are_not_concatenated(self):
        raw = url().encode()
        colon = raw.index(b':', len('https://'))
        fragments = raw[:colon] + b'\x00' + raw[colon:]
        self.assert_credential(fragments, False)
        # The same bytes without a boundary are an actual credential URL.
        self.assert_credential(fragments.replace(b'\x00', b''))
        token_boundary = bearer().encode().replace(b' ', b'\x00', 1)
        self.assert_credential(token_boundary, False)
        self.assert_credential(b'https' + b'\x00' * 7 + raw[len('https'):], False)

    def test_control_and_invalid_utf8_bytes_cannot_form_userinfo(self):
        for boundary in (b'\x00', b'\x01', b'\x0b', b'\x1f', b'\x7f', b'\x85', b'\xff', b'\xed\xa0\x80'):
            raw = url('fixture-user', 'fixture' + 'password').encode()
            split = raw.index(b'password')
            with self.subTest(boundary=boundary.hex()):
                self.assert_credential(raw[:split] + boundary + raw[split:], False)
        self.assert_credential(url('fixture-user', 'a\u0085b').encode(), False)
        self.assert_credential(bearer('\x0b').encode(), False)

    def test_utf16_terminators_controls_and_unpaired_surrogates_are_boundaries(self):
        for encoding in ('utf-16-le', 'utf-16-be'):
            for alignment in (b'', b'\xff'):
                for boundary in ('\x00', '\x01', '\x1f', '\x7f', '\u0085', '\ud800', '\udfff'):
                    raw = url('fixture-user', 'left' + boundary + 'right').encode(encoding, errors='surrogatepass')
                    with self.subTest(encoding=encoding, alignment=len(alignment), boundary=ascii(boundary)):
                        self.assert_credential(alignment + raw + b'\x00\x00', False)

    def test_real_credentials_inside_mixed_binary_are_still_detected(self):
        prefix, suffix = b'\xff\x00\x01\x02', b'\x00\x80\xff'
        self.assert_credential(prefix + url().encode() + suffix)
        for encoding in ('utf-16-le', 'utf-16-be'):
            for alignment in (b'', b'\xff'):
                self.assert_credential(alignment + prefix + url('使用者', '密碼😀').encode(encoding) + b'\x00\x00' + suffix)

    def test_name_and_payload_do_not_create_cross_source_bearer_text(self):
        self.assert_credential(('fixture-token-' * 2).encode(), False, name='Bearer')
        self.assert_credential(b'public data', name=url())

    def test_bearer_word_boundary_and_minimum_token_length_are_preserved(self):
        self.assert_credential(('X' + bearer()).encode(), False)
        self.assert_credential(('變數' + bearer()).encode(), False)
        self.assert_credential(('Bearer' + ' ' + 'x' * 15).encode(), False)
        for encoding in ('utf-16-le', 'utf-16-be'):
            self.assert_credential(('變數' + bearer()).encode(encoding), False)

    def test_other_privacy_rules_keep_existing_behavior(self):
        payload = ('https' + '://' + 'private.example.invalid').encode('utf-16-le')
        self.assertIn('private domain', findings('public.bin', payload, ['private.example.invalid']))
        path = ('C:' + '\\' + 'Users' + '\\' + 'fixture-user' + '\\' + 'source.dart').encode('utf-16-le')
        self.assertIn('personal filesystem path', findings('public.bin', path, []))
        assignment = ('api_key = ' + '"' + ('fixture-secret-' * 2) + '"').encode()
        self.assertIn('credential assignment', findings('public.txt', assignment.replace(b'fixture-', b'real-'), []))
        marker = ('-----BEGIN ' + 'PRIVATE KEY-----').encode('utf-16-be')
        self.assertIn('credential pattern', findings('public.bin', marker, []))
        network = ('http' + '://' + '192.' + '168.4.9').encode('utf-16-le')
        self.assertIn('private network endpoint', findings('public.bin', network, []))
        self.assertIn('private file type', findings('private.pem', b'public bytes', []))

    def test_empty_malformed_and_odd_length_inputs_are_bounded(self):
        for payload in (b'', b'\xff', b'\x00', b'\xff\x00\xd8', b'\x00h\x00t\x00t\x00p\x00:', b'http://'):
            with self.subTest(length=len(payload)):
                self.assert_credential(payload, False)


if __name__ == '__main__':
    unittest.main()
