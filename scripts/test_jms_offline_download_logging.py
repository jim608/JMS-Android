import re
import unittest
from pathlib import Path


class OfflineDownloadLoggingTest(unittest.TestCase):
    def test_download_setup_only_logs_constant_messages(self):
        # Even an enqueue exception can contain the entire authenticated URL.
        source = (Path(__file__).resolve().parents[1] / 'lib/providers/sync_provider.dart').read_text(encoding='utf-8')
        method = source.split('Future<bool?> syncFile(', 1)[1].split('\n  Future<', 1)[0]
        for call in re.finditer(r'\b(?:log|print|debugPrint)\s*\(([^;]*?)\);', method):
            with self.subTest(call=call.group(0)):
                self.assertRegex(call[1], r"""^\s*(?:'[^'$]*'|"[^"$]*")\s*$""")
