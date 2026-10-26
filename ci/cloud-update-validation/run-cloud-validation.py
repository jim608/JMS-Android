"""Future GitHub Linux CI runner: public fixtures and disposable accounts only.

Does not sign, rebuild the app, publish, or invoke Docker. An unset fixture pin
fails before any download, subprocess, account creation, or filesystem mutation.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import pwd
import re
import shutil
import subprocess
import time
import urllib.request

ORIGIN = 'https://jim608.github.io/JMS-Linux/flatpak/repo/'
REF = 'app/com.jim608.jms/x86_64/stable'
RUNTIME = 'org.gnome.Platform/x86_64/50'
DESCRIPTOR_URL = ORIGIN + 'ci-fixtures/signed-update-fixtures.json'
FILES = {
    'baseline-unsigned.flatpak': 512 * 1024**2,
    'baseline-signed.flatpak': 512 * 1024**2,
    'target-signed.flatpak': 512 * 1024**2,
    'target-verification.json': 8 * 1024**2,
    'jms-release.gpg': 256 * 1024,
    'wrong-public-key.gpg': 256 * 1024,
    'summary': 64 * 1024**2,
    'summary.sig': 1024**2,
}
SOURCES = ('portal-probe.c', 'validate-case.sh', 'portal-session.sh',
           'check-state.py', 'negative-origin.sh')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def hex64(value):
    return isinstance(value, str) and re.fullmatch('[a-f0-9]{64}', value) is not None


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        raise ValueError('Public fixture redirect refused; review the fixed descriptor URL')


def fetch(url, expected_sha, limit, expected_size=None):
    # No authentication handler, inherited proxy credentials, token or netrc.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    request = urllib.request.Request(url, headers={'User-Agent': 'JMS-public-portal-validation/1'})
    with opener.open(request, timeout=60) as response:
        require(response.status == 200, 'Public fixture HTTP status differs')
        data = response.read(limit + 1)
    require(len(data) <= limit, 'Public fixture exceeds its bound')
    if expected_size is not None:
        require(len(data) == expected_size, 'Public fixture size differs')
    require(hashlib.sha256(data).hexdigest() == expected_sha, 'Public fixture SHA256 differs')
    return data


def validate_descriptor(data):
    require(set(data) == {'schemaVersion', 'origin', 'ref', 'runtime', 'baselineCommit', 'targetCommit', 'fixtures'},
            'Descriptor fields differ from the reviewed schema')
    require(type(data['schemaVersion']) is int and data['schemaVersion'] == 1 and
            data['origin'] == ORIGIN and data['ref'] == REF and data['runtime'] == RUNTIME,
            'Descriptor origin/ref/runtime differs')
    require(hex64(data['baselineCommit']) and hex64(data['targetCommit']) and
            data['baselineCommit'] != data['targetCommit'], 'Different pinned OSTree commits are required')
    require(set(data['fixtures']) == set(FILES), 'Public fixture set is incomplete or unexpected')
    for name, maximum in FILES.items():
        item = data['fixtures'][name]
        expected_url = ORIGIN + (name if name in ('summary', 'summary.sig') else 'ci-fixtures/' + name)
        require(set(item) == {'url', 'sha256', 'bytes'} and item['url'] == expected_url,
                'Public fixture URL/fields escape the approved origin scope')
        require(hex64(item['sha256']) and type(item['bytes']) is int and 0 < item['bytes'] <= maximum,
                'Fixture hashes and exact positive sizes must be frozen before dispatch')
    require(data['fixtures']['jms-release.gpg']['sha256'] != data['fixtures']['wrong-public-key.gpg']['sha256'],
            'Wrong-key fixture cannot be the approved exported public key')


def command(args, logfile, timeout=1200):
    with logfile.open('xb') as log:
        result = subprocess.run(args, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
    require(result.returncode == 0, 'CI stage failed; preserve public log: ' + logfile.name)


def run(args):
    require(hex64(args.descriptor_sha256), 'Unready descriptor pin; no action performed')
    require(platform.system() == 'Linux' and platform.machine() == 'x86_64', 'Linux x86_64 CI is required')
    require(os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('GITHUB_REPOSITORY') == 'jim608/JMS-Linux',
            'This candidate runs only in the approved repository CI')
    run_id = os.environ.get('GITHUB_RUN_ID', '')
    require(re.fullmatch('[1-9][0-9]{0,11}', run_id), 'Unexpected GitHub run identity')
    require(re.fullmatch('[a-f0-9]{40}', os.environ.get('GITHUB_SHA', '')), 'Exact workflow source commit required')
    require(os.getuid() != 0, 'Use the normal GitHub runner user; only scoped setup uses sudo')
    root = args.work_root
    require(root.is_absolute() and root.parent.resolve() == Path('/var/tmp') and
            root.name == 'jms-cloud-update-' + run_id and not root.exists() and not root.is_symlink(),
            'A fresh run-scoped /var/tmp output root is required')
    source = Path(__file__).resolve().parent
    require(all((source / name).is_file() for name in SOURCES), 'Reviewed harness sources are missing')
    raw = fetch(DESCRIPTOR_URL, args.descriptor_sha256, 64 * 1024)
    descriptor = json.loads(raw)
    validate_descriptor(descriptor)  # Validate every placeholder before downloading any bundle.
    root.mkdir(mode=0o755)
    root.chmod(0o755)
    inputs, harness, results = (root / name for name in ('inputs', 'harness', 'results'))
    for directory in (inputs, harness, results):
        directory.mkdir(mode=0o755)
        directory.chmod(0o755)
    (root / 'fixture-descriptor.json').write_bytes(raw)
    record = {'status': 'started', 'descriptorSha256': args.descriptor_sha256,
              'workflowCommit': os.environ['GITHUB_SHA'], 'workflowRunId': run_id,
              'origin': ORIGIN, 'ref': REF, 'runtime': RUNTIME, 'cases': [],
              'sourceHashes': {name: digest(source / name) for name in SOURCES},
              'runnerSha256': digest(Path(__file__)), 'privateSigningMaterialUsed': False,
              'appRebuilt': False, 'productionRefChanged': False, 'realConsentUiTested': False}
    accounts = []
    try:
        for name, maximum in FILES.items():
            item = descriptor['fixtures'][name]
            (inputs / name).write_bytes(fetch(item['url'], item['sha256'], maximum, item['bytes']))
            (inputs / name).chmod(0o444)
        receipt = json.loads((inputs / 'target-verification.json').read_text())
        require(receipt.get('applicationId') == 'com.jim608.jms' and receipt.get('architecture') == 'x86_64' and
                receipt.get('branch') == 'stable' and receipt.get('runtime') == RUNTIME and
                receipt.get('ostreeCommit') == descriptor['targetCommit'], 'Target CI receipt identity differs')
        for name in SOURCES:
            shutil.copyfile(source / name, harness / name)
            (harness / name).chmod(0o444)
        flags = subprocess.check_output(['pkg-config', '--cflags', '--libs', 'gio-2.0'], text=True).split()
        command(['cc', '-std=c11', '-O2', '-Wall', '-Wextra', str(harness / 'portal-probe.c'),
                 *flags, '-o', str(inputs / 'portal-probe')], root / 'compile.log', timeout=120)
        (inputs / 'portal-probe').chmod(0o555)
        record['probeSha256'] = digest(inputs / 'portal-probe')
        f = descriptor['fixtures']
        public_env = {'JMS_ISOLATED_UPDATE_TEST': '1', 'JMS_INPUT_DIR': str(inputs),
            'JMS_BASELINE_COMMIT': descriptor['baselineCommit'], 'JMS_TARGET_COMMIT': descriptor['targetCommit'],
            'JMS_SIGNED_BASELINE_SHA256': f['baseline-signed.flatpak']['sha256'],
            'JMS_UNSIGNED_BASELINE_SHA256': f['baseline-unsigned.flatpak']['sha256'],
            'JMS_SIGNED_TARGET_SHA256': f['target-signed.flatpak']['sha256'],
            'JMS_PUBLIC_KEY_SHA256': f['jms-release.gpg']['sha256'],
            'JMS_TARGET_RECEIPT_SHA256': f['target-verification.json']['sha256'],
            'JMS_PORTAL_PROBE_SHA256': record['probeSha256'], 'JMS_PORTAL_TIMEOUT_SECONDS': '600',
            'JMS_WRONG_PUBLIC_KEY_SHA256': f['wrong-public-key.gpg']['sha256'],
            'JMS_SUMMARY_SHA256': f['summary']['sha256'], 'JMS_SUMMARY_SIG_SHA256': f['summary.sig']['sha256']}
        modes = ('fresh-target', 'signed-update', 'unsigned-migration', 'denied-update', 'trust-negative')
        for index, mode in enumerate(modes):
            name = f'jms-flatpak-cloud-{run_id}-{index}'
            try:
                pwd.getpwnam(name)
                raise ValueError('CI account already exists; refusing reuse')
            except KeyError:
                pass
            try:
                command(['sudo', 'useradd', '--create-home', '--user-group', '--shell', '/bin/bash', name],
                        results / (mode + '-account.log'), timeout=30)
            finally:
                # Even a useradd which fails while preparing its home may have
                # created the account. Track only this verified new identity.
                try:
                    created = pwd.getpwnam(name)
                except KeyError:
                    created = None
                if created and created.pw_uid != 0 and created.pw_dir == '/home/' + name:
                    accounts.append((name, created.pw_uid, created.pw_dir))
            user = pwd.getpwnam(name)
            require(user.pw_uid != 0 and user.pw_dir == '/home/' + name, 'Unexpected newly created account identity')
            output = results / mode
            command(['sudo', 'install', '-d', '-m755', '-o', name, '-g', name, str(output)],
                    results / (mode + '-output.log'), timeout=30)
            environment = dict(public_env, JMS_OUTPUT_DIR=str(output))
            script = 'negative-origin.sh' if mode == 'trust-negative' else 'validate-case.sh'
            invocation = ['sudo', '-u', name, 'env', '-i', 'PATH=/usr/bin:/bin', 'HOME=' + user.pw_dir,
                          *[key + '=' + value for key, value in environment.items()],
                          'bash', str(harness / script)]
            if mode != 'trust-negative':
                invocation.append(mode)
            command(invocation, results / (mode + '-driver.log'))
            result_path = output / ('negative-result.json' if mode == 'trust-negative' else 'result.json')
            result = json.loads(result_path.read_text())
            if mode == 'trust-negative':
                require(all(result.get(key) is True for key in
                    ('wrongPublicKeyRejected', 'tamperedSummaryRejected', 'targetRefNotAcceptedByNegatives')),
                    'Trust-negative result is incomplete')
            else:
                require(result.get('passed') is True, 'Case did not pass')
            record['cases'].append({'mode': mode, 'result': result})
        record['status'] = 'all-public-ci-cases-passed'
    except Exception as error:
        record['status'] = 'failed-preserve-evidence-before-retry'
        record['failure'] = str(error)
        raise
    finally:
        cleanup = []
        for name, uid, home in reversed(accounts):
            try:
                user = pwd.getpwnam(name)
                require(user.pw_uid == uid and user.pw_dir == home and home == '/home/' + name,
                        'Account identity changed; cleanup refused')
                subprocess.run(['sudo', 'pkill', '-TERM', '-u', str(uid)], capture_output=True, timeout=10)
                time.sleep(1)
                result = subprocess.run(['sudo', 'userdel', '--remove', name], capture_output=True, timeout=30)
                cleanup.append({'account': name, 'removed': result.returncode == 0})
            except Exception:
                cleanup.append({'account': name, 'removed': False})
        record['disposableAccountCleanup'] = cleanup
        record['cleanupComplete'] = all(item['removed'] for item in cleanup)
        (root / 'HARNESS_RUN.json').write_text(json.dumps(record, indent=2) + '\n')
        if record['status'] == 'all-public-ci-cases-passed' and not record['cleanupComplete']:
            raise ValueError('Disposable account cleanup incomplete; public CI is not complete')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--descriptor-sha256', required=True)
    parser.add_argument('--work-root', type=Path, required=True)
    run(parser.parse_args())
