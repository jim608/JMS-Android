"""Exercise the Android build driver with synthetic tools/APKs, never a key or build."""
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parent.parent
COMMIT = 'a' * 40
PWSH = shutil.which('pwsh') or shutil.which('powershell')
WRAPPER = r'''
param([string]$Fixture, [string]$DriverArguments)
Set-Location -LiteralPath $Fixture
function global:Test-Path {
    param([string]$LiteralPath, [string]$PathType)
    if ($LiteralPath -match '[\\/]\.android[\\/]debug\.keystore$') {
        Add-Content -LiteralPath (Join-Path $Fixture 'key-lookups.txt') -Value 'debug-key-presence'
        if ($env:JMS_FIXTURE_ALLOW_TEST_SIGNING -ne 'true') { throw 'Unexpected debug keystore lookup' }
        return $true
    }
    Microsoft.PowerShell.Management\Test-Path @PSBoundParameters
}
function global:rtk {
    $call = @($args | ForEach-Object { [string]$_ })
    [ordered]@{args=$call; unsigned=$env:JMS_UNSIGNED_CANDIDATE; testSigning=$env:JMS_TEST_SIGNING} |
        ConvertTo-Json -Compress -Depth 4 | Add-Content -LiteralPath (Join-Path $Fixture 'calls.jsonl')
    $global:LASTEXITCODE = 0
    if ($call[1] -eq 'git') {
        if ($call[2] -eq 'rev-parse') { return ('a' * 40) }
        if ($call[2] -eq 'ls-files') { return @('pubspec.yaml', 'scripts/build_jms_android.ps1', 'android/app/build.gradle') }
        throw 'Unexpected synthetic git command'
    }
    if ($call[1] -like '*python.exe') {
        if ($env:JMS_FIXTURE_FAIL_SOURCE -eq 'true') { $global:LASTEXITCODE = 1 }
        return
    }
    if ($call[1] -notlike '*flutter.bat') { throw 'Unexpected synthetic tool' }
    if ($call[2] -eq 'build') {
        $output = Join-Path $Fixture 'build/app/outputs/flutter-apk'
        New-Item -ItemType Directory -Force -Path $output | Out-Null
        Copy-Item -LiteralPath (Join-Path $Fixture 'fixture.apk') -Destination (Join-Path $output 'app-arm64-v8a-production-release.apk')
    }
}
$initialUnsigned = $env:JMS_UNSIGNED_CANDIDATE
$initialTest = $env:JMS_TEST_SIGNING
try {
    $parameters = ConvertFrom-Json -InputObject $DriverArguments -AsHashtable
    & (Join-Path $Fixture 'scripts/build_jms_android.ps1') @parameters
} catch {
    Write-Output $_.Exception.Message
    exit 11
} finally {
    [ordered]@{unsigned=$env:JMS_UNSIGNED_CANDIDATE; testSigning=$env:JMS_TEST_SIGNING;
        restored=($initialUnsigned -ceq $env:JMS_UNSIGNED_CANDIDATE -and $initialTest -ceq $env:JMS_TEST_SIGNING)} |
        ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $Fixture 'restored.json')
}
'''


@unittest.skipUnless(PWSH and 'pwsh' in Path(PWSH).name.lower(), 'PowerShell 7 required')
class UnsignedDriverTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='jms-unsigned-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for name in ('scripts', 'android/app', 'config', '.jms-tools/flutter/bin'):
            (self.root / name).mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / 'scripts/build_jms_android.ps1', self.root / 'scripts/build_jms_android.ps1')
        shutil.copyfile(ROOT / 'android/app/build.gradle', self.root / 'android/app/build.gradle')
        (self.root / '.jms-tools/flutter/bin/flutter.bat').touch()
        (self.root / 'pubspec.yaml').write_text('version: 0.11.1-jms.58+67\n', encoding='utf-8')
        (self.root / 'config/jms_updates.json').write_text(json.dumps({'owner': 'synthetic-owner', 'repo': 'synthetic-repo'}), encoding='utf-8')
        (self.root / 'wrapper.ps1').write_text(WRAPPER, encoding='utf-8')
        self.make_apk()

    def make_apk(self, signature=None):
        path = self.root / 'fixture.apk'
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr('AndroidManifest.xml', b'SYNTHETIC APK ONLY')
            archive.writestr('lib/arm64-v8a/libapp.so', b'SYNTHETIC ELF ONLY')
            if signature == 'v1':
                archive.writestr('META-INF/FAKE.RSA', b'NOT A REAL CERTIFICATE')
        if signature == 'v2':
            data = path.read_bytes()
            end = data.rfind(b'PK\x05\x06')
            directory = struct.unpack_from('<I', data, end + 16)[0]
            block = b'SYNTHETIC BLOCK' + b'APK Sig Block 42'
            changed = bytearray(data[:directory] + block + data[directory:])
            struct.pack_into('<I', changed, end + len(block) + 16, directory + len(block))
            path.write_bytes(changed)

    def run_driver(self, arguments=None, environment=None):
        arguments = arguments if arguments is not None else {'UnsignedCandidate': True, 'SourceCommit': COMMIT}
        for name in ('calls.jsonl', 'restored.json', 'key-lookups.txt'):
            (self.root / name).unlink(missing_ok=True)
        env = os.environ.copy()
        env.update({'JMS_UNSIGNED_CANDIDATE': 'inherited-unsigned', 'JMS_TEST_SIGNING': 'true'})
        env.update(environment or {})
        result = subprocess.run([PWSH, '-NoProfile', '-File', str(self.root / 'wrapper.ps1'),
                                 '-Fixture', str(self.root), '-DriverArguments', json.dumps(arguments)],
                                env=env, capture_output=True, text=True, timeout=30)
        calls_path = self.root / 'calls.jsonl'
        calls = [json.loads(row) for row in calls_path.read_text(encoding='utf-8-sig').splitlines()] if calls_path.exists() else []
        restored = json.loads((self.root / 'restored.json').read_text(encoding='utf-8-sig'))
        self.assertTrue(restored['restored'], result.stdout + result.stderr)
        return result, calls

    def test_unsigned_full_apk_keeps_source_checks_and_avoids_key_lookup(self):
        result, calls = self.run_driver()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('UNSIGNED CANDIDATE ONLY', result.stdout)
        self.assertFalse((self.root / 'key-lookups.txt').exists())
        output = self.root / 'artifacts/JMS-Android-0.11.1-jms.58-release-arm64-unsigned-candidate.apk'
        self.assertEqual(output.read_bytes(), (self.root / 'fixture.apk').read_bytes())
        record = json.loads((self.root / 'artifacts/checks/build-0.11.1-jms.58-unsigned-candidate-inputs.json').read_text(encoding='utf-8-sig'))
        self.assertEqual(record['signing'], 'none')
        self.assertFalse(record['publishable'])
        self.assertTrue(record['unsignedCandidate'])
        self.assertTrue(record['gitSourceVerified'])
        self.assertTrue(record['publicationSnapshot'])
        source_calls = [call for call in calls if any('jms_git_release.py' in a or 'verify_jms_snapshot.py' in a for a in call['args'])]
        self.assertEqual(len(source_calls), 2)
        build = next(call for call in calls if 'apk' in call['args'])
        self.assertEqual(build['unsigned'], 'true')
        self.assertNotEqual(build['testSigning'], 'true')
        for argument in ('--release', '--flavor', 'production', '--build-number=67', '--target-platform', 'android-arm64', '--split-per-abi'):
            self.assertIn(argument, build['args'])

    def test_signing_conflicts_fail_before_tools(self):
        for extra, message in (({'ProductionSigning': True}, 'conflicts'), ({'Mode': 'debug'}, 'release mode'), ({'SourceCommit': ''}, 'full SourceCommit')):
            with self.subTest(extra=extra):
                arguments = {'UnsignedCandidate': True, 'SourceCommit': COMMIT, **extra}
                result, calls = self.run_driver(arguments)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stdout)
                self.assertFalse(calls)

    def test_existing_properties_or_outputs_are_never_consumed(self):
        for name in ('android/app/key.properties', 'android/app/keystore.jks', 'build/app', 'android/app/build', 'android/.gradle'):
            with self.subTest(name=name):
                sentinel = self.root / name
                sentinel.parent.mkdir(parents=True, exist_ok=True)
                sentinel.write_text('SYNTHETIC SENTINEL: DO NOT READ', encoding='utf-8')
                result, calls = self.run_driver()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('fresh isolated checkout', result.stdout)
                self.assertFalse(calls)
                sentinel.unlink()

    def test_official_source_verification_failure_stops_before_apk_build(self):
        result, calls = self.run_driver(environment={'JMS_FIXTURE_FAIL_SOURCE': 'true'})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('clean jms commit', result.stdout)
        self.assertFalse(any('apk' in call['args'] for call in calls))

    def test_signed_apk_is_rejected_before_candidate_copy(self):
        for signature in ('v1', 'v2'):
            with self.subTest(signature=signature):
                self.make_apk(signature)
                result, _ = self.run_driver()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('signature' if signature == 'v1' else 'signing block', result.stdout)
                self.assertFalse((self.root / 'artifacts/JMS-Android-0.11.1-jms.58-release-arm64-unsigned-candidate.apk').exists())
                shutil.rmtree(self.root / 'build')

    def test_default_test_and_production_modes_ignore_inherited_unsigned_flag(self):
        unsigned, _ = self.run_driver()
        self.assertEqual(unsigned.returncode, 0, unsigned.stdout + unsigned.stderr)
        unsigned_record = json.loads((self.root / 'artifacts/checks/build-0.11.1-jms.58-unsigned-candidate-inputs.json').read_text(encoding='utf-8-sig'))
        for production in (False, True):
            with self.subTest(production=production):
                arguments = {'SourceCommit': COMMIT, 'ProductionSigning': production}
                result, calls = self.run_driver(arguments, {'JMS_FIXTURE_ALLOW_TEST_SIGNING': 'true'})
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                build = next(call for call in calls if 'apk' in call['args'])
                self.assertEqual(build['unsigned'], 'false')
                self.assertEqual(build['testSigning'] == 'true', not production)
                signed_record = json.loads((self.root / 'artifacts/checks/build-0.11.1-jms.58-inputs.json').read_text(encoding='utf-8-sig'))
                self.assertNotEqual(unsigned_record['buildId'], signed_record['buildId'])
                label = 'production-signed' if production else 'test-signed'
                self.assertTrue((self.root / f'artifacts/JMS-Android-0.11.1-jms.58-release-arm64-{label}.apk').exists())


if __name__ == '__main__':
    unittest.main()
