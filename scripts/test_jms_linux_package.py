import hashlib
import json
import os
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from package_jms_linux import LINUX_DEPENDENCIES, main, package_version, write_aur_recipe


class LinuxPackageTests(unittest.TestCase):
    def test_real_version_order_is_encoded(self):
        self.assertEqual(package_version('0.11.1-jms.19', 21), '0.11.1_jms.19-21')

    def test_shell_and_path_values_rejected(self):
        for version in ('../bad', '1.2.3;cmd', '', '1.2.3$(cmd)'):
            with self.assertRaises(ValueError):
                package_version(version, 21)
        with self.assertRaises(ValueError):
            package_version('1.2.3', 0)
        with self.assertRaises(ValueError):
            package_version('1.2.3', True)

    def test_recipe_rejects_other_platform_or_unbound_installer(self):
        metadata = {'applicationId': 'com.jim608.jms', 'platform': 'linux-x64',
                    'versionName': '0.11.1-jms.29', 'versionCode': 31,
                    'packageVersion': '0.11.1_jms.29-31', 'sourceCommit': 'a' * 40,
                    'buildId': 'JMS-0.11.1-jms.29-linux-' + 'a' * 12}
        installer = {'name': 'JMS-Linux-0.11.1-jms.29-x86_64.pkg.tar.xz',
                     'size': 1, 'sha256': 'b' * 64}
        with tempfile.TemporaryDirectory() as directory:
            for change in ({'platform': 'windows-x64'}, {'versionCode': True},
                           {'sourceCommit': 'unknown'}, {'packageVersion': '0.11.1_jms.25-27'}):
                with self.subTest(change=change), self.assertRaises(ValueError):
                    write_aur_recipe(Path(directory), metadata | change, installer)
            for change in ({'name': '../installer.pkg.tar.xz'}, {'sha256': 'SKIP'},
                           {'name': 'JMS-Linux-0.11.1-jms.29-aarch64.pkg.tar.xz'}):
                with self.subTest(change=change), self.assertRaises(ValueError):
                    write_aur_recipe(Path(directory), metadata, installer | change)
            with self.assertRaises(ValueError):
                write_aur_recipe(Path(directory), metadata, installer, 'latest')

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
                self.assertIn('conflict = jms-bin', info)
                self.assertIn('pkgver = 0.11.1_jms.25-27', info)
                self.assertIn('arch = x86_64', info)
                build = json.load(archive.extractfile('opt/jms/JMS_BUILD_INFO.json'))
                self.assertEqual(build['sourceCommit'], commit)
                self.assertEqual(build['versionCode'], 27)
            with tarfile.open(output / 'JMS-Linux-0.11.1-jms.25-x64.tar.gz', 'r:gz') as archive:
                self.assertEqual(json.load(archive.extractfile('JMS/JMS_BUILD_INFO.json')), build)
            manifest = json.loads((output / 'build-manifest.json').read_text())
            installer = manifest['outputs'][0]
            recipe_record = manifest['outputs'][2]
            self.assertEqual(recipe_record['name'], 'JMS-Linux-0.11.1-jms.25-jms-bin-aur.tar.gz')
            self.assertEqual(hashlib.sha256((output / recipe_record['name']).read_bytes()).hexdigest(),
                             recipe_record['sha256'])
            with tarfile.open(output / recipe_record['name'], 'r:gz') as archive:
                self.assertEqual({item.name for item in archive if item.isfile()},
                                 {'jms-bin/PKGBUILD', 'jms-bin/.SRCINFO', 'jms-bin/README.zh-Hant.md'})
                recipe = archive.extractfile('jms-bin/PKGBUILD').read().decode()
                srcinfo = archive.extractfile('jms-bin/.SRCINFO').read().decode()
            self.assertIn(f"sha256sums=('{installer['sha256']}')", recipe)
            self.assertIn('/releases/download/v0.11.1-jms.25/' + installer['name'], recipe)
            self.assertIn("_source_commit='" + commit + "'", recipe)
            self.assertIn('options=(\'!strip\' \'!debug\')', recipe)
            self.assertIn('\tprovides = jms=0.11.1_jms.25-27\n', srcinfo)
            self.assertIn('\tconflicts = jms\n', srcinfo)
            self.assertEqual([line.split(' = ', 1)[1] for line in srcinfo.splitlines()
                              if line.startswith('\tdepends = ')], list(LINUX_DEPENDENCIES))
            with self.assertRaises(ValueError):
                write_aur_recipe(output, build | {'sourceCommit': 'b' * 40,
                    'buildId': 'JMS-0.11.1-jms.25-linux-' + 'b' * 12}, installer)
            package = output / installer['name']
            data = package.read_bytes()
            package.write_bytes(data[:-1] + bytes([data[-1] ^ 1]))
            with self.assertRaises(ValueError):
                write_aur_recipe(output, build, installer)
