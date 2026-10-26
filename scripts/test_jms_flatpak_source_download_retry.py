"""Deterministic transport retry contracts; all URL opens and waits are mocked."""
import hashlib
import http.client
import inspect
import io
import socket
import ssl
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest.mock import call, patch
import urllib.error

import collect_jms_flatpak_sources as collector

URL = 'https://fixture.invalid/pinned/source.tar.gz'
DATA = b'synthetic exact corresponding source archive'
SHA = hashlib.sha256(DATA).hexdigest()


class _Response(io.BytesIO):
    def __init__(self, data, url=URL):
        super().__init__(data)
        self.url = url

    def geturl(self):
        return self.url


class _PartialTimeout(_Response):
    def __init__(self):
        super().__init__(b'partial')
        self.reads = 0

    def read(self, size=-1):
        self.reads += 1
        if self.reads > 1:
            raise TimeoutError('synthetic read timeout')
        return super().read(size)


class DownloadRetryTests(unittest.TestCase):
    def test_committed_uchardet_source_matches_pin_without_network(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            committed = collector.ROOT / 'flatpak/uchardet-0.0.8.tar.xz'
            shutil.copyfile(committed, root / committed.name)
            output = root / 'source.archive'
            source = {'url': collector.UCHARDET_URL, 'sha256': collector.UCHARDET_SHA}
            with patch.object(collector, 'download') as network:
                collector.pinned_archive(source, output, root)
            network.assert_not_called()
            self.assertEqual(hashlib.sha256(output.read_bytes()).hexdigest(), collector.UCHARDET_SHA)

    def test_committed_uchardet_mismatch_fails_without_network(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'uchardet-0.0.8.tar.xz').write_bytes(b'wrong')
            source = {'url': collector.UCHARDET_URL, 'sha256': collector.UCHARDET_SHA}
            with patch.object(collector, 'download') as network:
                with self.assertRaisesRegex(ValueError, 'Committed pinned uchardet archive differs'):
                    collector.pinned_archive(source, root / 'source.archive', root)
            network.assert_not_called()
            self.assertFalse((root / 'source.archive').exists())

    def test_other_archive_still_uses_pinned_network_download(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = {'url': URL, 'sha256': SHA}
            with patch.object(collector, 'download') as network:
                collector.pinned_archive(source, root / 'source.archive', root)
            network.assert_called_once_with(URL, root / 'source.archive', SHA)

    def test_transient_timeout_then_exact_success_uses_identical_pin(self):
        failures = [
            TimeoutError('synthetic connect timeout'),
            urllib.error.URLError(TimeoutError('synthetic wrapped timeout')),
            ConnectionResetError('synthetic connection reset'),
            urllib.error.URLError(socket.gaierror(socket.EAI_AGAIN, 'synthetic temporary DNS')),
            urllib.error.HTTPError(URL, 503, 'synthetic unavailable', {}, None),
            http.client.IncompleteRead(b'partial'),
        ]
        for failure in failures:
            with self.subTest(kind=type(failure).__name__), tempfile.TemporaryDirectory() as directory:
                destination = Path(directory) / 'source.archive'
                response = _Response(DATA)
                with patch.object(collector.urllib.request, 'urlopen', side_effect=[failure, response]) as opened, \
                        patch.object(collector.time, 'sleep') as slept:
                    collector.download(URL, destination, SHA)
                self.assertEqual(destination.read_bytes(), DATA)
                self.assertEqual(opened.call_args_list, [call(URL, timeout=60)] * 2)
                slept.assert_called_once_with(1)
                self.assertTrue(response.closed)
                self.assertEqual(list(Path(directory).iterdir()), [destination])

    def test_exhaustion_is_three_attempts_and_preserves_original_last_error(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / 'source.archive'
            failures = [TimeoutError('synthetic timeout ' + str(i)) for i in range(3)]
            with patch.object(collector.urllib.request, 'urlopen', side_effect=failures) as opened, \
                    patch.object(collector.time, 'sleep') as slept:
                with self.assertRaises(TimeoutError) as caught:
                    collector.download(URL, destination, SHA)
            self.assertIs(caught.exception, failures[-1])
            self.assertEqual(opened.call_args_list, [call(URL, timeout=60)] * 3)
            self.assertEqual(slept.call_args_list, [call(1), call(2)])
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_integrity_mismatch_fails_without_retry_or_destination_replacement(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / 'source.archive'
            destination.write_bytes(b'previous verified file')
            with patch.object(collector.urllib.request, 'urlopen', return_value=_Response(b'wrong archive')) as opened, \
                    patch.object(collector.time, 'sleep') as slept:
                with self.assertRaisesRegex(ValueError, 'SHA256 differs'):
                    collector.download(URL, destination, SHA)
            opened.assert_called_once_with(URL, timeout=60)
            slept.assert_not_called()
            self.assertEqual(destination.read_bytes(), b'previous verified file')
            self.assertEqual(list(Path(directory).iterdir()), [destination])

    def test_oversize_fails_without_retry_or_retained_partial(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / 'source.archive'
            with patch.object(collector.urllib.request, 'urlopen', return_value=_Response(DATA)) as opened, \
                    patch.object(collector.time, 'sleep') as slept:
                with self.assertRaisesRegex(ValueError, 'exceeds bounded'):
                    collector.download(URL, destination, SHA, limit=len(DATA) - 1)
            opened.assert_called_once_with(URL, timeout=60)
            slept.assert_not_called()
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_partial_read_is_discarded_before_retry_and_hash_restarts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            destination = root / 'source.archive'
            first = _PartialTimeout()
            second = _Response(DATA)
            calls = 0

            def open_mock(url, timeout):
                nonlocal calls
                self.assertEqual((url, timeout), (URL, 60))
                self.assertEqual(list(root.rglob('*.partial')), [])
                calls += 1
                return first if calls == 1 else second

            def sleep_mock(seconds):
                self.assertEqual(seconds, 1)
                self.assertEqual(list(root.iterdir()), [])

            with patch.object(collector.urllib.request, 'urlopen', side_effect=open_mock), \
                    patch.object(collector.time, 'sleep', side_effect=sleep_mock):
                collector.download(URL, destination, SHA)
            self.assertEqual(calls, 2)
            self.assertTrue(first.closed)
            self.assertTrue(second.closed)
            self.assertEqual(destination.read_bytes(), DATA)
            self.assertEqual(list(root.iterdir()), [destination])

    def test_permanent_http_tls_and_schema_errors_are_not_retried(self):
        failures = [
            urllib.error.HTTPError(URL, 404, 'synthetic not found', {}, None),
            urllib.error.URLError(ssl.SSLCertVerificationError(1, 'synthetic certificate verification')),
            urllib.error.URLError(socket.gaierror(socket.EAI_NONAME, 'synthetic permanent DNS')),
            ValueError('synthetic response schema failure'),
        ]
        for failure in failures:
            with self.subTest(kind=type(failure).__name__), tempfile.TemporaryDirectory() as directory:
                with patch.object(collector.urllib.request, 'urlopen', side_effect=failure) as opened, \
                        patch.object(collector.time, 'sleep') as slept:
                    with self.assertRaises(type(failure)) as caught:
                        collector.download(URL, Path(directory) / 'source.archive', SHA)
                self.assertIs(caught.exception, failure)
                opened.assert_called_once_with(URL, timeout=60)
                slept.assert_not_called()
                self.assertEqual(list(Path(directory).iterdir()), [])

    def test_invalid_pin_or_limit_fails_before_network_and_keeps_signature(self):
        self.assertEqual(list(inspect.signature(collector.download).parameters),
                         ['url', 'destination', 'expected', 'limit'])
        self.assertEqual(inspect.signature(collector.download).parameters['limit'].default,
                         256 * 1024 * 1024)
        for url, expected, limit in [
                ('http://fixture.invalid/source', SHA, 1024),
                (URL, 'not-a-sha256', 1024),
                (URL, SHA, 0), (URL, SHA, -1), (URL, SHA, True), (URL, SHA, '1024')]:
            with self.subTest(url=url, limit=limit), tempfile.TemporaryDirectory() as directory:
                with patch.object(collector.urllib.request, 'urlopen') as opened, \
                        patch.object(collector.time, 'sleep') as slept:
                    with self.assertRaises(ValueError):
                        collector.download(url, Path(directory) / 'source.archive', expected, limit)
                opened.assert_not_called()
                slept.assert_not_called()
                self.assertEqual(list(Path(directory).iterdir()), [])

    def test_https_downgrade_is_never_accepted_or_retried(self):
        with tempfile.TemporaryDirectory() as directory:
            response = _Response(DATA, url='http://fixture.invalid/downgraded-source')
            with patch.object(collector.urllib.request, 'urlopen', return_value=response) as opened, \
                    patch.object(collector.time, 'sleep') as slept:
                with self.assertRaisesRegex(ValueError, 'left pinned HTTPS'):
                    collector.download(URL, Path(directory) / 'source.archive', SHA)
            opened.assert_called_once_with(URL, timeout=60)
            slept.assert_not_called()
            self.assertTrue(response.closed)
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_local_file_timeout_is_not_reclassified_as_network_retry(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / 'source.archive'
            error = TimeoutError('synthetic local file timeout')
            with patch.object(collector.urllib.request, 'urlopen', return_value=_Response(DATA)) as opened, \
                    patch.object(collector.time, 'sleep') as slept, \
                    patch.object(Path, 'open', side_effect=error):
                with self.assertRaises(TimeoutError) as caught:
                    collector.download(URL, destination, SHA)
            self.assertIs(caught.exception, error)
            opened.assert_called_once_with(URL, timeout=60)
            slept.assert_not_called()
            self.assertEqual(list(Path(directory).iterdir()), [])


if __name__ == '__main__':
    unittest.main()
