import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]
LLVM = ROOT / '.jms-tools/android-sdk/ndk/27.0.12077973/toolchains/llvm/prebuilt/windows-x86_64/bin'
ASS_SHA = '488ead8aec91f24cf5cf49fe3849cb7b83268e1474673b4f8cd85fb02240e1bf'
WRAPPER_SHA = '0a8a0c969e2684fc5ec453edbedafcebd0a1b4eaf945c9003a5fc7438d4c6a4a'
CPP_SHA = 'ad74bf43eb1fd576518168f664ad16a74e00eeda9595875c33dd87f6dd197869'
REMOVED = {'libmdk.so', 'libfvp_plugin.so', 'libffmpeg.so'}


def run(tool, *args):
    return subprocess.check_output(['rtk', 'proxy', str(LLVM / tool), *map(str, args)], text=True, encoding='utf-8')


def ndk_license_coverage(notice):
    normalized_notice = ' '.join(notice.decode('utf-8').split())
    coverage = []
    for component in ('libcxx', 'libcxxabi', 'libunwind'):
        path = ROOT / f'artifacts/native-materials-m13/ndk28-{component}-LICENSE.txt'
        content = path.read_text(encoding='utf-8')
        normalized = ' '.join(content.split())
        exact_text = normalized in normalized_notice
        matching_text = normalized.replace('The libunwind library is dual licensed', 'The libc++abi library is dual licensed')
        if not exact_text and matching_text not in normalized_notice:
            raise ValueError('APK lacks NDK 28 license clauses: ' + component)
        coverage.append({'component': component, 'sourceSha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                         'normalizedFullTextPresent': exact_text, 'allLicenseClausesPresent': True,
                         'difference': None if exact_text else 'Only explanatory component label libunwind/libc++abi differs; exact original accompanies Release'})
    return coverage


def inspect(apk, output):
    output.mkdir(parents=True, exist_ok=True)
    inventory = {}
    with zipfile.ZipFile(apk) as archive:
        names = archive.namelist()
        for name in names:
            if not name.startswith('lib/arm64-v8a/') or not name.endswith('.so') or name.endswith('/libapp.so'):
                continue
            basename = Path(name).name
            if basename in REMOVED:
                raise ValueError('Excluded MDK dependency still packaged: ' + basename)
            data = archive.read(name)
            path = output / basename
            path.write_bytes(data)
            elf = run('llvm-readelf.exe', '--dynamic', '--notes', path)
            needed = re.findall(r'Shared library: \[([^\]]+)\]', elf)
            if REMOVED.intersection(needed):
                raise ValueError('Remaining ELF still links excluded SDK: ' + basename)
            inventory[name] = {'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data), 'needed': needed,
                               'buildIds': re.findall(r'Build ID: (\w+)', elf)}
        if inventory['lib/arm64-v8a/libass.so']['sha256'] != ASS_SHA:
            raise ValueError('Native libass is not the locked ass-kt provider')
        if inventory['lib/arm64-v8a/libasskt.so']['sha256'] != WRAPPER_SHA:
            raise ValueError('Native subtitle wrapper changed unexpectedly')
        if inventory['lib/arm64-v8a/libc++_shared.so']['sha256'] != CPP_SHA:
            raise ValueError('C++ runtime is not the locked ass-kt NDK 28 provider')
        for name in names:
            if name.endswith('.dex') and b'Lcom/mediadevkit/fvp/FvpPlugin;' in archive.read(name):
                raise ValueError('Android fvp Java plugin still packaged')
        notice = archive.read('assets/flutter_assets/assets/licenses/JMS_NATIVE_NOTICES.txt')
        expected_notice = (ROOT / 'assets/licenses/JMS_NATIVE_NOTICES.txt').read_bytes()
        if notice != expected_notice:
            raise ValueError('APK lacks exact reviewed native notices')
        license_coverage = ndk_license_coverage(notice)
    undefined = run('llvm-nm.exe', '--dynamic', '--undefined-only', output / 'libasskt.so')
    defined = run('llvm-nm.exe', '--dynamic', '--defined-only', output / 'libass.so')
    required = set(re.findall(r'\b(ass_[A-Za-z0-9_]+)\b', undefined))
    provided = set(re.findall(r'\b(ass_[A-Za-z0-9_]+)\b', defined))
    if not required or required - provided:
        raise ValueError('Native subtitle symbol ABI is incomplete: ' + repr(sorted(required - provided)))
    original = json.loads((ROOT / 'docs/release-evidence/native-review.json').read_text(encoding='utf-8'))
    if inventory['lib/arm64-v8a/libmpv.so']['sha256'] != original['nativeHashes']['lib/arm64-v8a/libmpv.so']:
        raise ValueError('MPV binary changed unexpectedly')
    report = {'status': 'PASS', 'scope': 'static APK/provider/symbol ABI only; no device rendering claim',
              'apkSha256': hashlib.sha256(apk.read_bytes()).hexdigest(), 'inventory': inventory,
              'mdkAbsent': True, 'fvpAndroidClassAbsent': True, 'assRequiredSymbols': sorted(required),
              'ndk28LicenseCoverage': license_coverage,
              'nativeRendererDeviceTest': 'PENDING', 'mpvBinaryUnchanged': True}
    (output / 'native-review.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps({'status': 'PASS', 'libraries': len(inventory), 'assSymbolsResolved': len(required),
                      'mdkAbsent': True, 'mpvBinaryUnchanged': True, 'deviceTest': 'PENDING'}))
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--apk', required=True)
    parser.add_argument('--output', default='artifacts/checks/m13/candidate-native')
    options = parser.parse_args()
    inspect(Path(options.apk), ROOT / options.output)
