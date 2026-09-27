"""Exercise the release path policy against actual Rust compiler output."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.name == 'nt' and shutil.which('pwsh') and shutil.which('rustc'),
                     'Windows PowerShell and Rust compiler are required')
class RustPathPolicyTests(unittest.TestCase):
    def test_actual_compiler_output_remaps_paths_and_preserves_flags(self):
        with tempfile.TemporaryDirectory(prefix='jms rust policy ') as directory:
            root = Path(directory)
            source = root / 'probe.rs'
            source.write_text('pub fn source_path() -> &\'static str { file!() }', encoding='utf-8')
            script = root / 'probe.ps1'
            script.write_text('''$ErrorActionPreference = 'Stop'
. $env:JMS_POLICY_SCRIPT
$flags = (Get-JmsWindowsRustFlags -ProjectRoot $env:JMS_PROBE_ROOT).Split([char]31)
if ($flags[0] -ne '--cfg' -or $flags[1] -ne 'jms_policy_probe') { throw 'Original flags lost' }
& rustc @flags --crate-type lib --emit llvm-ir -o $env:JMS_PROBE_OUTPUT $env:JMS_PROBE_SOURCE
if ($LASTEXITCODE -ne 0) { throw 'Rust probe failed' }
''', encoding='utf-8')
            for encoded in (False, True):
                output = root / f'probe-{encoded}.ll'
                env = dict(os.environ, JMS_POLICY_SCRIPT=str(ROOT / 'scripts/jms_windows_rust_flags.ps1'),
                           JMS_PROBE_ROOT=str(root), JMS_PROBE_SOURCE=str(source),
                           JMS_PROBE_OUTPUT=str(output))
                env.pop('CARGO_ENCODED_RUSTFLAGS', None)
                env['RUSTFLAGS'] = '--cfg jms_policy_probe'
                if encoded:
                    env['CARGO_ENCODED_RUSTFLAGS'] = '--cfg\x1fjms_policy_probe'
                    env['RUSTFLAGS'] = '--invalid-ignored-flag'
                result = subprocess.run(['pwsh', '-NoProfile', '-File', str(script)],
                                        env=env, capture_output=True)
                self.assertEqual(result.returncode, 0, 'Rust path policy probe failed')
                data = output.read_bytes()
                self.assertIn(b'/jms-build/source', data)
                self.assertNotIn(str(root).encode(), data)
                self.assertNotIn(root.as_posix().encode(), data)
                profile = os.environ.get('USERPROFILE', '')
                if profile:
                    self.assertNotIn(profile.encode(), data)
                    self.assertNotIn(profile.replace('\\', '/').encode(), data)


if __name__ == '__main__':
    unittest.main()
