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
require, digest, hex64, fetch = (getattr(common, name) for name in
    ('require', 'digest', 'hex64', 'fetch'))
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
FAILURE_STAGES = {'verify-inputs', 'prepare-session', 'install-bundle', 'installed-commit',
    'origin-name', 'origin-migration', 'origin-trust-check', 'remote-target-check',
    'launchers-before', 'permissions-before', 'synthetic-settings-fixture', 'portal-session',
    'after-update-origin-check', 'settings-preserved', 'after-update-commit-check',
    'permissions-preserved', 'launchers-after', 'target-contents-check', 'write-result'}
FAILURE_STAGES.update({'bootstrap', 'guard-isolation', 'guard-account', 'guard-home',
    'guard-mode', 'guard-paths', 'guard-empty-output', 'guard-not-installed'})
PORTAL_STAGES = {'bootstrap', 'guard-isolation', 'guard-account', 'guard-mode',
    'activation-environment', 'portal-daemon-start', 'portal-owner-check', 'consent-fixture', 'probe-run'}
PORTAL_CODES = {'expected-method-denial', 'method-denied', 'invalid-signal-signature',
    'unexpected-update-identity', 'invalid-progress', 'unexpected-install', 'terminal-done',
    'unexpected-empty-update', 'expected-progress-denial', 'terminal-failed',
    'deadline-update-outcome-uncertain', 'deadline-no-update-signal', 'portal-setup-failed'}
HOST_FAILURE_STAGES = {'fetch-public-fixtures', 'private-baseline-check', 'target-receipt-check',
    'copy-harness', 'probe-toolchain', 'probe-compile', 'environment-build', 'account-check',
    'account-create', 'account-verify', 'output-prepare', 'invocation-build', 'driver', 'case-result-check'}
HOST_CASE_MODES = {'fresh-target', 'trust-negative', 'unsigned-migration', 'denied-update'}
HOST_LOG_NAMES = {'compile.log',
    'fresh-target-account.log', 'fresh-target-output.log', 'fresh-target-driver.log',
    'trust-negative-account.log', 'trust-negative-output.log', 'trust-negative-driver.log',
    'unsigned-migration-account.log', 'unsigned-migration-output.log', 'unsigned-migration-driver.log',
    'denied-update-account.log', 'denied-update-output.log', 'denied-update-driver.log'}


def command(args, logfile, timeout=1200):
    """Same command/log/timeout and zero-exit gate; retain its actual failure code."""
    with logfile.open('xb') as log:
        result = subprocess.run(args, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
    if result.returncode != 0:
        raise subprocess.CalledProcessError(result.returncode, ())


def bounded_bytes(path, limit, tail=False):
    try:
        if not path.is_file() or path.is_symlink():
            return None
        with path.open('rb') as stream:
            if tail:
                size = path.stat().st_size
                stream.seek(max(0, size - limit))
                raw = stream.read(limit)
                return raw.split(b'\n', 1)[-1] if size > limit else raw
            raw = stream.read(limit + 1)
            return raw if len(raw) <= limit else None
    except OSError:
        return None


def diagnostic_json(raw):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('Duplicate diagnostic key')
            result[key] = value
        return result
    return json.loads(raw, object_pairs_hook=unique)


def bounded_json(path, limit=2048):
    raw = bounded_bytes(path, limit)
    try:
        return diagnostic_json(raw) if raw is not None else None
    except (ValueError, UnicodeError, RecursionError):
        return None


def commit_class(raw, baseline, target):
    if raw is None:
        return 'missing'
    try:
        value = raw.decode('ascii').strip()
    except UnicodeError:
        return 'invalid'
    if not hex64(value):
        return 'invalid'
    return 'baseline' if value == baseline else 'target' if value == target else 'other'


def safe_portal_events(path, baseline, target):
    """No raw lines, unknown strings, D-Bus messages, paths or arbitrary hashes."""
    raw = bounded_bytes(path, 65536, tail=True)
    result = {'evidence': 'missing' if raw is None else 'present', 'recognizedEvents': 0}
    if raw is None:
        return result
    for line in raw.splitlines()[-256:]:
        if len(line) > 2048:
            continue
        try:
            event = diagnostic_json(line)
        except (ValueError, UnicodeError, RecursionError):
            continue
        if type(event) is not dict:
            continue
        kind = event.get('event')
        valid = False
        if (kind == 'result' and set(event) == {'event', 'code', 'updateDispatched', 'success'}
                and type(event['code']) is str and event['code'] in PORTAL_CODES
                and type(event['updateDispatched']) is bool and type(event['success']) is bool):
            result['terminal'] = {key: event[key] for key in ('code', 'updateDispatched', 'success')}
            valid = True
        elif (kind == 'request' and set(event) in ({'event', 'acknowledged'},
                {'event', 'acknowledged', 'outcomeUncertain'})
                and type(event['acknowledged']) is bool
                and ('outcomeUncertain' not in event or type(event['outcomeUncertain']) is bool)):
            result['request'] = {key: event[key] for key in ('acknowledged', 'outcomeUncertain') if key in event}
            valid = True
        elif (kind == 'progress' and set(event) == {'event', 'status', 'percent', 'hasPercent'}
                and type(event['status']) is int and 0 <= event['status'] <= 3
                and type(event['percent']) is int and 0 <= event['percent'] <= 100
                and type(event['hasPercent']) is bool):
            result['lastProgress'] = {key: event[key] for key in ('status', 'percent', 'hasPercent')}
            valid = True
        elif (kind == 'update-available' and set(event) == {'event', 'running', 'local', 'remote'}
                and all(type(event[key]) is str and hex64(event[key]) for key in ('running', 'local', 'remote'))):
            result['availableVersions'] = {key: commit_class(event[key].encode(), baseline, target)
                                            for key in ('running', 'local', 'remote')}
            valid = True
        if valid:
            result['recognizedEvents'] += 1
    return result


def safe_stage(data, mode, stages, failure=False):
    keys = {'mode', 'stage', 'line', 'exitCode'} if failure else {'mode', 'stage'}
    if (type(data) is not dict or set(data) != keys or data['mode'] not in (mode, 'bootstrap')
            or type(data['stage']) is not str or data['stage'] not in stages):
        return None
    if failure and not (type(data['line']) is int and 0 < data['line'] < 10000
            and type(data['exitCode']) is int and 0 < data['exitCode'] <= 255):
        return None
    return {key: data[key] for key in keys if key != 'mode'}


def safe_log_categories(logfile):
    """Bounded best-effort input; diagnostic I/O cannot replace a real failure."""
    try:
        if logfile is None or not logfile.is_file() or logfile.is_symlink():
            return []
        with logfile.open('rb') as stream:
            stream.seek(max(0, logfile.stat().st_size - 65536))
            text = stream.read(65536).decode('utf-8', errors='replace')
    except OSError:
        return []
    rules = {'missing-summary-setting': r'NoOptionError:.*gpg-verify-summary',
        'missing-ref': r'No such ref|not installed',
        'session-bus-unavailable': r'Failed to connect to.*bus|Unable to autolaunch',
        'sandbox-unavailable': r'bwrap:.*(?:Operation not permitted|Permission denied)',
        'untrusted-signature': r'GPG signatures found, but none|no signatures found',
        'permission-denied': r'Permission denied', 'state-assertion': r'AssertionError'}
    return [name for name, pattern in rules.items() if re.search(pattern, text, re.I)]


def safe_host_failure(stage, mode, logfile, error):
    """Only source-defined enums/basenames and genuinely known numeric exits."""
    result = {'scope': 'host', 'stage': stage if stage in HOST_FAILURE_STAGES else 'host-validation',
              'categories': []}
    if mode in HOST_CASE_MODES:
        result['mode'] = mode
    if logfile is not None and logfile.name in HOST_LOG_NAMES:
        result['commandLog'] = logfile.name
        result['categories'] = safe_log_categories(logfile)
    if isinstance(error, subprocess.CalledProcessError) and type(error.returncode) is int and -255 <= error.returncode <= 255:
        result['exitCode'] = error.returncode
    if isinstance(error, PermissionError) and 'permission-denied' not in result['categories']:
        result['categories'].append('permission-denied')
    elif isinstance(error, subprocess.TimeoutExpired):
        result['categories'].append('operation-timeout')
    return result


def safe_case_failure(output, mode, logfile, error=None, baseline=None, target=None):
    """Only known stage enums/numbers/categories, never raw logs or exception text."""
    result = {'mode': mode, 'stage': 'case-driver', 'categories': []}
    current = safe_stage(bounded_json(output / 'case-stage.json'), mode, FAILURE_STAGES)
    failure = safe_stage(bounded_json(output / 'failure-stage.json'), mode, FAILURE_STAGES, True)
    # Bootstrap failures can occur before the output directory is verified. Only
    # the fixed sentinel schema is accepted from the bounded driver log tail.
    raw = bounded_bytes(logfile, 65536, tail=True)
    if raw is not None and failure is None:
        for line in raw.splitlines()[-256:]:
            if line.startswith(b'JMS_CASE_DIAGNOSTIC ') and len(line) <= 2048:
                try:
                    failure = safe_stage(diagnostic_json(line.split(b' ', 1)[1]), mode, FAILURE_STAGES, True)
                except (ValueError, UnicodeError, RecursionError):
                    pass
                if failure:
                    break
    if failure or current:
        result.update(failure or current)
    host = safe_host_failure('driver', mode, logfile, error)
    if 'exitCode' in host:
        result['driverExitCode'] = host['exitCode']
    result['driverTimedOut'] = isinstance(error, subprocess.TimeoutExpired)
    result['categories'] = safe_log_categories(logfile)
    for value in host['categories']:
        if value not in result['categories']:
            result['categories'].append(value)
    if not (hex64(baseline) and hex64(target) and baseline != target):
        return result
    portal = safe_stage(bounded_json(output / 'portal-stage.json'), mode, PORTAL_STAGES)
    portal_failure = safe_stage(bounded_json(output / 'portal-failure.json'), mode, PORTAL_STAGES, True)
    if raw is not None and portal_failure is None:
        for line in raw.splitlines()[-256:]:
            if line.startswith(b'JMS_PORTAL_DIAGNOSTIC ') and len(line) <= 2048:
                try:
                    portal_failure = safe_stage(diagnostic_json(line.split(b' ', 1)[1]), mode, PORTAL_STAGES, True)
                except (ValueError, UnicodeError, RecursionError):
                    pass
                if portal_failure:
                    break
    if portal_failure or portal:
        result['portalStage'] = portal_failure or portal
    case = bounded_json(output / 'result.json')
    if (type(case) is dict and set(case) == {'mode', 'passed', 'portalExit', 'inspectInstalledCommitBeforeRetry'}
            and case['mode'] == mode and case['passed'] is False
            and case['inspectInstalledCommitBeforeRetry'] is True
            and type(case['portalExit']) is int and 0 < case['portalExit'] <= 255):
        result['portalExitCode'] = case['portalExit']
        if result['stage'] == 'case-driver':
            result['stage'] = 'portal-session'
    result['portal'] = safe_portal_events(output / 'portal.jsonl', baseline, target)
    result['observedVersions'] = {
        'before': commit_class(bounded_bytes(output / 'observed-before-portal-commit.txt', 66), baseline, target),
        'afterPortal': commit_class(bounded_bytes(output / 'observed-after-failed-portal-commit.txt', 66), baseline, target),
        'atDriverExit': commit_class(bounded_bytes(output / 'observed-at-driver-exit-commit.txt', 66), baseline, target)}
    code = result['portal'].get('terminal', {}).get('code')
    if code in ('deadline-no-update-signal', 'deadline-update-outcome-uncertain'):
        result['timeoutStage'] = code
    elif result['driverTimedOut']:
        result['timeoutStage'] = 'driver-command'
    elif result.get('portalExitCode') == 124:
        result['timeoutStage'] = 'outer-probe-command'
    return result


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
    host_stage, host_mode, host_log = 'fetch-public-fixtures', None, None
    try:
        for name, limit in FILES.items():
            item = descriptor['fixtures'][name]
            (inputs / name).write_bytes(fetch(item['url'], item['sha256'], limit, item['bytes']))
            (inputs / name).chmod(0o444)
        record['publicInputSHA256'] = {name: item['sha256'] for name, item in descriptor['fixtures'].items()}
        if args.group == 'legacy-migration':
            host_stage = 'private-baseline-check'
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
        host_stage = 'target-receipt-check'
        receipt = json.loads((inputs / 'target-verification.json').read_text())
        require(receipt.get('applicationId') == 'com.jim608.jms' and receipt.get('architecture') == 'x86_64' and
                receipt.get('branch') == 'stable' and receipt.get('runtime') == RUNTIME and
                receipt.get('ostreeCommit') == descriptor['targetCommit'], 'Target CI receipt identity differs')
        host_stage = 'copy-harness'
        for name in SOURCES:
            shutil.copyfile(SOURCE / name, harness / name)
            (harness / name).chmod(0o444)
        host_stage = 'probe-toolchain'
        flags = subprocess.check_output(['pkg-config', '--cflags', '--libs', 'gio-2.0'], text=True).split()
        host_stage, host_log = 'probe-compile', root / 'compile.log'
        command(['cc', '-std=c11', '-O2', '-Wall', '-Wextra', str(harness / 'portal-probe.c'),
                 *flags, '-o', str(inputs / 'portal-probe')], host_log, timeout=120)
        (inputs / 'portal-probe').chmod(0o555)
        record['probeSHA256'] = digest(inputs / 'portal-probe')
        host_stage, host_log = 'environment-build', None
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
            host_stage, host_mode, host_log = 'account-check', mode, None
            name = f'jms-flatpak-cloud-{run_id}-' + ('p' if args.group == 'public-target' else 'l') + str(index)
            try:
                pwd.getpwnam(name)
                raise ValueError('CI account exists; refusing reuse')
            except KeyError:
                pass
            host_stage, host_log = 'account-create', results / (mode + '-account.log')
            try:
                command(['sudo', 'useradd', '--create-home', '--user-group', '--shell', '/bin/bash', name],
                        host_log, timeout=120)
            finally:
                try:
                    user = pwd.getpwnam(name)
                    if user.pw_uid != 0 and user.pw_dir == '/home/' + name:
                        accounts.append((name, user.pw_uid, user.pw_dir))
                except KeyError:
                    pass
            host_stage, host_log = 'account-verify', None
            user = pwd.getpwnam(name)
            require(user.pw_uid != 0 and user.pw_dir == '/home/' + name, 'New account identity differs')
            output = results / mode
            host_stage, host_log = 'output-prepare', results / (mode + '-output.log')
            command(['sudo', 'install', '-d', '-m755', '-o', name, '-g', name, str(output)],
                    host_log, timeout=30)
            host_stage, host_log = 'invocation-build', None
            environment = dict(public_env, JMS_OUTPUT_DIR=str(output))
            script = 'negative-origin.sh' if mode == 'trust-negative' else 'validate-private-case.sh'
            invocation = ['sudo', '-u', name, 'env', '-i', 'PATH=/usr/bin:/bin', 'HOME=' + user.pw_dir,
                *[key + '=' + value for key, value in environment.items()], 'bash', str(harness / script)]
            if mode != 'trust-negative':
                invocation.append(mode)
            driver_log = results / (mode + '-driver.log')
            host_stage, host_log = 'driver', driver_log
            try:
                command(invocation, driver_log)
            except Exception as error:
                record['failure'] = safe_case_failure(output, mode, driver_log, error,
                    binding['runtime']['ostreeCommit'], descriptor['targetCommit'])
                raise
            host_stage = 'case-result-check'
            result = json.loads((output / ('negative-result.json' if mode == 'trust-negative' else 'result.json')).read_text())
            if mode == 'trust-negative':
                require(all(result.get(key) is True for key in BOOLEANS[-3:]), 'Trust negatives incomplete')
            else:
                require(result.get('passed') is True, 'Case failed')
            record['cases'].append({'mode': mode, **{key: result[key] for key in BOOLEANS if type(result.get(key)) is bool}})
        record['status'] = 'passed'
    except Exception as error:
        record['status'] = 'failed-inspect-private-runner-state-before-retry'
        if 'failure' not in record:
            record['failure'] = safe_host_failure(host_stage, host_mode, host_log, error)
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
