import subprocess
import unittest
from unittest.mock import patch

import jms_flatpak_window as window


class FlatpakProductWindowTests(unittest.TestCase):
    actual = ('  0x400040 "jms": ()  10x10+-100+-100  +-100+-100\n'
              '  0x400003 "Fladder": ("jms" "Jms")  1280x720+0+152  +0+152\n'
              '  0x400001 "jms": ("jms" "Jms")  10x10+10+10  +10+10\n')

    def test_actual_ci_window_is_found_despite_upstream_title(self):
        self.assertEqual(window.product_windows(self.actual), ['0x400003'])
        self.assertEqual(window.product_windows(self.actual.replace('"Fladder"', '"JMS"')), ['0x400003'])

    def test_only_helper_or_foreign_window_is_not_product_launch(self):
        self.assertEqual(window.product_windows(self.actual.replace('1280x720', '10x10')), [])
        self.assertEqual(window.product_windows(self.actual.replace('("jms" "Jms")', '("other" "Other")')), [])

    def test_mapped_product_window_is_verified_with_xwininfo(self):
        completed = subprocess.CompletedProcess([], 0, stdout='  Map State: IsViewable\n')
        with patch.object(window.subprocess, 'run', return_value=completed) as run:
            self.assertEqual(window.mapped_product_window(self.actual), '0x400003')
        self.assertEqual(run.call_args.args[0], ['xwininfo', '-id', '0x400003'])

    def test_unmapped_or_disappeared_window_is_rejected(self):
        for code, state in [(0, 'IsUnMapped'), (1, 'IsViewable')]:
            with self.subTest(code=code, state=state):
                completed = subprocess.CompletedProcess([], code, stdout='  Map State: ' + state + '\n')
                with patch.object(window.subprocess, 'run', return_value=completed):
                    self.assertIsNone(window.mapped_product_window(self.actual))


if __name__ == '__main__':
    unittest.main()
