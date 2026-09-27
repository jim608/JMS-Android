import unittest

from package_jms_linux import package_version


class LinuxPackageTests(unittest.TestCase):
    def test_real_version_order_is_encoded(self):
        self.assertEqual(package_version('0.11.1-jms.19', 21), '0.11.1_jms.19-21')

    def test_shell_and_path_values_rejected(self):
        for version in ('../bad', '1.2.3;cmd', '', '1.2.3$(cmd)'):
            with self.assertRaises(ValueError):
                package_version(version, 21)
        with self.assertRaises(ValueError):
            package_version('1.2.3', 0)
