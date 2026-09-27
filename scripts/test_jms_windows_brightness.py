import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'third_party/screen_brightness_windows/windows/src/screen_brightness_windows_plugin.cpp'


def body(source, signature):
    start = source.index('{', source.index(signature))
    depth = 1
    position = start + 1
    while depth:
        if source[position] == '{':
            depth += 1
        elif source[position] == '}':
            depth -= 1
        position += 1
    return source[start + 1:position - 1]


class BrightnessSourceContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SOURCE.read_text(encoding='utf-8')

    def test_registration_does_not_probe_monitor(self):
        constructor = body(self.source, 'ScreenBrightnessWindowsPlugin::ScreenBrightnessWindowsPlugin(')
        self.assertNotIn('GetScreenBrightness(', constructor)
        self.assertNotIn('SetScreenBrightness(', constructor)

    def test_idle_resume_does_not_probe_monitor(self):
        resume = body(self.source, 'void ScreenBrightnessWindowsPlugin::OnApplicationResume()')
        self.assertLess(resume.index('application_screen_brightness_ == -1'), resume.index('GetScreenBrightness('))
        self.assertLess(resume.index('return;'), resume.index('GetScreenBrightness('))

    def test_idle_pause_does_not_write_monitor(self):
        pause = body(self.source, 'void ScreenBrightnessWindowsPlugin::OnApplicationPause()')
        self.assertIn('system_screen_brightness_ == -1 || application_screen_brightness_ == -1', pause)
        self.assertLess(pause.index('return;'), pause.index('SetScreenBrightness('))

    def test_unused_reset_is_noop(self):
        reset = body(self.source, 'void ScreenBrightnessWindowsPlugin::HandleResetApplicationScreenBrightnessMethodCall(')
        self.assertLess(reset.index('application_screen_brightness_ == -1'), reset.index('SetScreenBrightness('))
        self.assertLess(reset.index('return;'), reset.index('SetScreenBrightness('))

    def test_explicit_brightness_operations_initialize(self):
        handler = body(self.source, 'void ScreenBrightnessWindowsPlugin::HandleMethodCall(')
        initialization = handler[:handler.index('if (method_call.method_name()')]
        for method in ('getSystemScreenBrightness', 'getApplicationScreenBrightness',
                       'setSystemScreenBrightness', 'setApplicationScreenBrightness'):
            self.assertIn(f'method == "{method}"', initialization)
        self.assertIn('GetScreenBrightness(', initialization)
        self.assertIn('result->Error(', initialization)

    def test_active_override_still_restores_and_reapplies(self):
        self.assertIn('SetScreenBrightness(system_screen_brightness_);',
                      body(self.source, 'void ScreenBrightnessWindowsPlugin::OnApplicationPause()'))
        self.assertIn('SetScreenBrightness(application_screen_brightness_);',
                      body(self.source, 'void ScreenBrightnessWindowsPlugin::OnApplicationResume()'))


if __name__ == '__main__':
    unittest.main()
