"""Unexecuted JMS-Android CI candidate. Public target plus private old fixture.

The old public-baseline candidate stays historical. No app rebuild, signing,
publishing, CLI update, host credentials in sandbox, or old-bit upload occurs.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import pwd
import re
import shutil
import subprocess
import time

SOURCE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('public_helpers', SOURCE / 'run-cloud-validation.py')
common = importlib.util.module_from_spec(spec)
spec.loader.exec_module(common)  # Helpers only; the historical main is not run.
require, digest, hex64, fetch, command = (getattr(common, name) for name in
    ('require', 'digest', 'hex64', 'fetch', 'command'))
ORIGIN, REF, RUNTIME = common.ORIGIN, common.REF, common.RUNTIME
DESCRIPTOR_URL = ORIGIN + 'ci-fixtures/private-baseline-validation.json'
FILES = {name: limit for name, limit in common.FILES.items() if not name.startswith('baseline-')}
SOURCES = ('portal-probe.c', 'validate-private-case.sh', 'portal-session.sh',
           'check-state.py', 'negative-origin.sh')
TOOLS = (*SOURCES, 'run-cloud-validation.py', 'run-private-baseline-validation.py',
         'baseline47-private-binding.json')
GROUPS = {'public-target': ('fresh-target', 'trust-negative'),
          'legacy-migration': ('unsigned-migration', 'denied-update')}
BOOLEANS = ('passed', 'realPortalUpdate', 'consentPermissionStoreFixture', 'realConsentUiTested',
            'signedOriginAndInstalledCommitChecked', 'syntheticFixtureRetained',
            'launcherMetadataOnly', 'realAuthenticatedMediaTested', 'wrongPublicKeyRejected',
            'tamperedSummaryRejected', 'targetRefNotAcceptedByNegatives')


def descriptor_check(data, binding):
    require(set(data) == {'schemaVersion', 'origin', 'ref', 'runtime', 'baselineBinding',
                         'targetCommit', 'targetPublicReleaseGateReceiptSHA256', 'fixtures'},
            'Descriptor schema differs')
    require(type(data['schemaVersion']) is int and data['schemaVersion'] == 2 and
            data['origin'] == ORIGIN and data['ref'] == REF and data['runtime'] == RUNTIME,
            'Descriptor fixed identity differs')
    require(data['baselineBinding'] == binding and hex64(data['targetCommit']) and
            data['targetCommit'] != binding['runtime']['ostreeCommit'] and
            hex64(data['targetPublicReleaseGateReceiptSHA256']), 'Frozen release/baseline pins required')
    require(set(data['fixtures']) == set(FILES), 'Only approved public target fixtures are allowed')
    for name, limit in FILES.items():
        item = data['fixtures'][name]
        url = ORIGIN + (name if name in ('summary', 'summary.sig') else 'ci-fixtures/' + name)
        require(set(item) == {'url', 'sha256', 'bytes'} and item['url'] == url and
                hex64(item['sha256']) and type(item['bytes']) is int and 0 < item['bytes'] <= limit,
                'Frozen public target URL, SHA and byte count required')
    require(data['fixtures']['jms-release.gpg']['sha256'] != data['fixtures']['wrong-public-key.gpg']['sha256'],
            'Wrong public key must differ')


def run(args):
    require(hex64(args.descriptor_sha256), 'Unready descriptor pin; no action performed')
    require(platform.system() == 'Linux' and platform.machine() == 'x86_64', 'Linux x86_64 required')
    require(os.environ.get('GITHUB_ACTIONS') == 'true' and
            os.environ.get('GITHUB_REPOSITORY') == 'jim608/JMS-Android', 'Own-repository CI required')
    require(not os.environ.get('GH_TOKEN') and not os.environ.get('GITHUB_TOKEN'),
            'Download token must not be available in validation steps')
    run_id = os.environ.get('GITHUB_RUN_ID', '')
    require(re.fullmatch('[1-9][0-9]{0,11}', run_id) and
            re.fullmatch('[a-f0-9]{40}', os.environ.get('GITHUB_SHA', '')), 'Pinned CI identity required')
    require(os.getuid() != 0, 'Normal GitHub runner identity required')
    root = args.work_root
    require(root.is_absolute() and root.parent.resolve() == Path('/var/tmp') and
            root.name == 'jms-private-portal-' + run_id + '-' + args.group and
            not root.exists() and not root.is_symlink(), 'Fresh exact run/group output root required')
    binding = json.loads((SOURCE / 'baseline47-private-binding.json').read_text())
    raw = fetch(DESCRIPTOR_URL, args.descriptor_sha256, 64 * 1024)
    descriptor = json.loads(raw)
    descriptor_check(descriptor, binding)
    require(all((SOURCE / name).is_file() for name in TOOLS), 'Reviewed harness files missing')
    root.mkdir(mode=0o755)
    root.chmod(0o755)
    inputs, harness, results, safe = (root / name for name in ('inputs', 'harness', 'results', 'safe-evidence'))
    for path in (inputs, harness, results, safe):
        path.mkdir(mode=0o755)
        path.chmod(0o755)
    record = {'status': 'started', 'group': args.group, 'descriptorSHA256': args.descriptor_sha256,
        'workflowCommit': os.environ['GITHUB_SHA'], 'workflowRunId': run_id,
        'origin': ORIGIN, 'ref': REF, 'runtime': RUNTIME, 'targetCommit': descriptor['targetCommit'],
        'targetPublicReleaseGateReceiptSHA256': descriptor['targetPublicReleaseGateReceiptSHA256'],
        'targetGateReceiptHashReferencedOnly': True,
        'targetGateReplacedOrWaived': False, 'originalFullPublicGatePassed': False,
        'oldBitsPubliclyRepublishedOrSigned': False, 'appRebuilt': False,
        'signedToSignedUpgradeTested': False, 'legacyUiSelfMigrationTested': False,
        'realConsentUiTested': False, 'productionRefChanged': False,
        'sourceHashes': {name: digest(SOURCE / name) for name in TOOLS}, 'cases': []}
    accounts = []
    try:
        for name, limit in FILES.items():
            item = descriptor['fixtures'][name]
            (inputs / name).write_bytes(fetch(item['url'], item['sha256'], limit, item['bytes']))
            (inputs / name).chmod(0o444)
        record['publicInputSHA256'] = {name: item['sha256'] for name, item in descriptor['fixtures'].items()}
        if args.group == 'legacy-migration':
            private = args.private_fixture_root
            require(private == Path('/var/tmp/jms-private-baseline-' + run_id) and
                    private.is_dir() and not private.is_symlink(), 'Exact private fixture directory required')
            proof = json.loads((private / 'private-fixture-proof.json').read_text())
            require(proof == {'binding': binding, 'authenticatedOwnActionsMetadataVerified': True,
                'exactOriginalZipAndSelectedRuntimeVerified': True, 'sourceOrNativeArchivesExtracted': False,
                'runtimeSignedOrPubliclyRepublished': False}, 'Authenticated private fixture proof differs')
            old = private / 'baseline-unsigned.flatpak'
            require(old.is_file() and not old.is_symlink() and old.stat().st_size == binding['runtime']['size'] and
                    digest(old) == binding['runtime']['sha256'], 'Accepted old runtime bytes differ')
            shutil.copyfile(old, inputs / 'baseline-unsigned.flatpak')
            (inputs / 'baseline-unsigned.flatpak').chmod(0o444)
            record['privateBaselineSHA256'] = binding['runtime']['sha256']
            record['privateOriginalZipSHA256'] = binding['ci']['zipSHA256']
        else:
            require(args.private_fixture_root is None, 'Fresh target checks cannot depend on the old fixture')
        receipt = json.loads((inputs / 'target-verification.json').read_text())
        require(receipt.get('applicationId') == 'com.jim608.jms' and receipt.get('architecture') == 'x86_64' and
                receipt.get('branch') == 'stable' and receipt.get('runtime') == RUNTIME and
                receipt.get('ostreeCommit') == descriptor['targetCommit'], 'Target CI receipt identity differs')
        for name in SOURCES:
            shutil.copyfile(SOURCE / name, harness / name)
            (harness / name).chmod(0o444)
        flags = subprocess.check_output(['pkg-config', '--cflags', '--libs', 'gio-2.0'], text=True).split()
        command(['cc', '-std=c11', '-O2', '-Wall', '-Wextra', str(harness / 'portal-probe.c'),
                 *flags, '-o', str(inputs / 'portal-probe')], root / 'compile.log', timeout=120)
        (inputs / 'portal-probe').chmod(0o555)
        record['probeSHA256'] = digest(inputs / 'portal-probe')
        f = descriptor['fixtures']
        public_env = {'JMS_ISOLATED_UPDATE_TEST': '1', 'JMS_INPUT_DIR': str(inputs),
            'JMS_BASELINE_COMMIT': binding['runtime']['ostreeCommit'], 'JMS_TARGET_COMMIT': descriptor['targetCommit'],
            'JMS_UNSIGNED_BASELINE_SHA256': binding['runtime']['sha256'],
            'JMS_SIGNED_TARGET_SHA256': f['target-signed.flatpak']['sha256'],
            'JMS_PUBLIC_KEY_SHA256': f['jms-release.gpg']['sha256'],
            'JMS_TARGET_RECEIPT_SHA256': f['target-verification.json']['sha256'],
            'JMS_PORTAL_PROBE_SHA256': record['probeSHA256'], 'JMS_PORTAL_TIMEOUT_SECONDS': '600',
            'JMS_WRONG_PUBLIC_KEY_SHA256': f['wrong-public-key.gpg']['sha256'],
            'JMS_SUMMARY_SHA256': f['summary']['sha256'], 'JMS_SUMMARY_SIG_SHA256': f['summary.sig']['sha256']}
        for index, mode in enumerate(GROUPS[args.group]):
            name = f'jms-flatpak-cloud-{run_id}-' + ('p' if args.group == 'public-target' else 'l') + str(index)
            try:
                pwd.getpwnam(name)
                raise ValueError('CI account exists; refusing reuse')
            except KeyError:
                pass
            try:
                command(['sudo', 'useradd', '--create-home', '--user-group', '--shell', '/bin/bash', name],
                        results / (mode + '-account.log'), timeout=30)
            finally:
                try:
                    user = pwd.getpwnam(name)
                    if user.pw_uid != 0 and user.pw_dir == '/home/' + name:
                        accounts.append((name, user.pw_uid, user.pw_dir))
                except KeyError:
                    pass
            user = pwd.getpwnam(name)
            require(user.pw_uid != 0 and user.pw_dir == '/home/' + name, 'New account identity differs')
            output = results / mode
            command(['sudo', 'install', '-d', '-m755', '-o', name, '-g', name, str(output)],
                    results / (mode + '-output.log'), timeout=30)
            environment = dict(public_env, JMS_OUTPUT_DIR=str(output))
            script = 'negative-origin.sh' if mode == 'trust-negative' else 'validate-private-case.sh'
            invocation = ['sudo', '-u', name, 'env', '-i', 'PATH=/usr/bin:/bin', 'HOME=' + user.pw_dir,
                *[key + '=' + value for key, value in environment.items()], 'bash', str(harness / script)]
            if mode != 'trust-negative':
                invocation.append(mode)
            command(invocation, results / (mode + '-driver.log'))
            result = json.loads((output / ('negative-result.json' if mode == 'trust-negative' else 'result.json')).read_text())
            if mode == 'trust-negative':
                require(all(result.get(key) is True for key in BOOLEANS[-3:]), 'Trust negatives incomplete')
            else:
                require(result.get('passed') is True, 'Case failed')
            record['cases'].append({'mode': mode, **{key: result[key] for key in BOOLEANS if type(result.get(key)) is bool}})
        record['status'] = 'passed'
    except Exception:
        record['status'] = 'failed-inspect-private-runner-state-before-retry'
        raise
    finally:
        removed = []
        for name, uid, home in reversed(accounts):
            try:
                user = pwd.getpwnam(name)
                require(user.pw_uid == uid and user.pw_dir == home and home == '/home/' + name,
                        'Cleanup identity differs')
                subprocess.run(['sudo', 'pkill', '-TERM', '-u', str(uid)], capture_output=True, timeout=10)
                time.sleep(1)
                status = subprocess.run(['sudo', 'userdel', '--remove', name], capture_output=True, timeout=30)
                removed.append(status.returncode == 0)
            except Exception:
                removed.append(False)
        record['disposableAccountsCreated'] = len(accounts)
        record['disposableAccountsRemoved'] = sum(removed)
        record['cleanupComplete'] = all(removed)
        # Only this whitelist-built record is uploaded. Inputs, private ZIP,
        # runtime, full result files, paths and subprocess logs remain excluded.
        (safe / 'sanitized-results.json').write_text(json.dumps(record, indent=2) + '\n')
        require(record['status'] != 'passed' or record['cleanupComplete'], 'Account cleanup incomplete')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--descriptor-sha256', required=True)
    parser.add_argument('--group', choices=GROUPS, required=True)
    parser.add_argument('--work-root', type=Path, required=True)
    parser.add_argument('--private-fixture-root', type=Path)
    try:
        run(parser.parse_args())
    except Exception:
        raise SystemExit('Validation incomplete; only sanitized evidence may be uploaded. Inspect isolated state before retry.')
