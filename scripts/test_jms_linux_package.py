import json
import os
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from package_jms_linux import main, package_version


class LinuxPackageTests(unittest.TestCase):
    def test_real_version_order_is_encoded(self):
        self.assertEqual(package_version('0.11.1-jms.19', 21), '0.11.1_jms.19-21')

    def test_shell_and_path_values_rejected(self):
        for version in ('../bad', '1.2.3;cmd', '', '1.2.3$(cmd)'):
            with self.assertRaises(ValueError):
                package_version(version, 21)
        with self.assertRaises(ValueError):
            package_version('1.2.3', 0)

    def test_generated_package_declares_startup_service_and_keeps_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            bundle = workspace / 'build/linux/x64/release/bundle'
            bundle.mkdir(parents=True)
            (bundle / 'jms').write_bytes(b'fixture executable')
            (bundle / 'lib').mkdir()
            (bundle / 'lib/libapp.so').write_bytes(b'fixture application')
            (workspace / 'pubspec.yaml').write_text('version: 0.11.1-jms.25+27\n')
            (workspace / 'LICENSE').write_text('fixture license')
            icon = workspace / 'icons/jms/icon.png'
            icon.parent.mkdir(parents=True)
            icon.write_bytes(b'fixture icon')
            output = workspace / 'output'
            commit = 'a' * 40

            def package_tar(arguments, **_):
                destination = arguments[arguments.index('-cJf') + 1]
                stage = Path(arguments[arguments.index('-C') + 1])
                with tarfile.open(destination, 'w:xz') as archive:
                    for name in ('.PKGINFO', 'opt', 'usr'):
                        archive.add(stage / name, arcname=name)

            previous = Path.cwd()
            try:
                os.chdir(workspace)
                with mock.patch('sys.argv', ['package', '--source-commit', commit,
                        '--build-id', 'JMS-0.11.1-jms.25-linux-' + commit[:12],
                        '--output', str(output)]), \
                        mock.patch('package_jms_linux.subprocess.run', side_effect=package_tar), \
                        mock.patch('package_jms_linux.subprocess.check_output', return_value=b'fixture\t1\n'), \
                        mock.patch.object(Path, 'symlink_to', lambda path, target: path.write_text(target)):
                    main()
            finally:
                os.chdir(previous)
            with tarfile.open(output / 'JMS-Linux-0.11.1-jms.25-x86_64.pkg.tar.xz', 'r:xz') as archive:
                info = archive.extractfile('.PKGINFO').read().decode().splitlines()
                self.assertIn('depend = networkmanager', info)
                self.assertIn('pkgver = 0.11.1_jms.25-27', info)
                self.assertIn('arch = x86_64', info)
                build = json.load(archive.extractfile('opt/jms/JMS_BUILD_INFO.json'))
                self.assertEqual(build['sourceCommit'], commit)
                self.assertEqual(build['versionCode'], 27)
            with tarfile.open(output / 'JMS-Linux-0.11.1-jms.25-x64.tar.gz', 'r:gz') as archive:
                self.assertEqual(json.load(archive.extractfile('JMS/JMS_BUILD_INFO.json')), build)
