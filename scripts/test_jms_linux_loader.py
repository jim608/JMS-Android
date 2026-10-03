import unittest
from pathlib import Path


class LinuxLoaderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        script = Path(__file__).with_name('test_jms_linux_install.sh').read_text(encoding='utf-8')
        policy = script.split('# JMS_LOADER_POLICY_BEGIN\n', 1)[1].split('# JMS_LOADER_POLICY_END', 1)[0]
        namespace = {'__name__': 'synthetic_loader_test'}
        exec(compile(policy, 'isolated Linux loader policy', 'exec'), namespace)
        cls.verify = staticmethod(namespace['verified_loader_directory'])

    def test_exact_executable_context_supplies_bundled_flutter_to_plugins(self):
        description = ('0x0001 (NEEDED) Shared library: [libflutter_linux_gtk.so]\n'
                       '0x001d (RUNPATH) Library runpath: [$ORIGIN/lib]\n')
        self.assertEqual(self.verify(description), '/opt/jms/lib')

    def test_missing_or_external_loader_context_is_not_inferred(self):
        for value in ('', '.', '/tmp/unknown', '$ORIGIN/lib:/tmp/unknown', '$ORIGIN/other'):
            description = ('0x0001 (NEEDED) Shared library: [libflutter_linux_gtk.so]\n'
                           f'0x001d (RUNPATH) Library runpath: [{value}]\n')
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.verify(description)

    def test_without_engine_preload_the_plugin_context_cannot_be_assumed(self):
        with self.assertRaises(ValueError):
            self.verify('0x001d (RUNPATH) Library runpath: [$ORIGIN/lib]\n')

    def test_conflicting_loader_tags_are_rejected(self):
        description = ('0x0001 (NEEDED) Shared library: [libflutter_linux_gtk.so]\n'
                       '0x001d (RUNPATH) Library runpath: [$ORIGIN/lib]\n'
                       '0x000f (RPATH) Library rpath: [/tmp/unknown]\n')
        with self.assertRaises(ValueError):
            self.verify(description)


if __name__ == '__main__':
    unittest.main()
