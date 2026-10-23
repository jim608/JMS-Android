"""Record owned test containers and retire stopped containers with retained evidence.

Inspect output stays in the private evidence directory; console output contains IDs only.
This helper never stops a running container and never deletes images, mounts or volumes.
"""
import argparse
from datetime import datetime, timezone
import gzip
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import uuid

OWNER = 'com.jim608.jms.test-owner'
PURPOSE = 'com.jim608.jms.test-purpose'
IDENTITY = re.compile(r'[a-f0-9]{64}')


def docker(*args, **kwargs):
    return subprocess.run(['docker', *map(str, args)], check=True, **kwargs)


def capture(*args):
    return docker(*args, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    pending = path.with_suffix(path.suffix + '.pending')
    pending.write_text(json.dumps(value, indent=2) + '\n', encoding='utf-8')
    pending.chmod(0o600)
    pending.replace(path)


def load_ledger(path):
    if path.exists():
        return json.loads(path.read_text(encoding='utf-8'))
    return {'schemaVersion': 1, 'owner': uuid.uuid4().hex, 'containers': []}


def inspect(container):
    rows = json.loads(capture('container', 'inspect', container))
    if len(rows) != 1:
        raise ValueError('Ambiguous container identity')
    return rows[0]


def verify_identity(row, entry, owner):
    labels = row.get('Config', {}).get('Labels') or {}
    if (row.get('Id') != entry['id'] or row.get('Image') != entry['imageId']
            or labels.get(OWNER) != owner or labels.get(PURPOSE) != entry['purpose']):
        raise ValueError('Owned full container ID, image or purpose changed')


def stopped(row):
    state = row.get('State', {})
    return (state.get('Status') in ('created', 'exited', 'dead')
            and state.get('Running') is False and not state.get('Paused')
            and not state.get('Restarting'))


def create(path, image, purpose, arguments):
    if not re.fullmatch('[a-z0-9][a-z0-9-]{0,79}', purpose):
        raise ValueError('Use a short explicit test purpose')
    if not arguments or '--rm' in arguments:
        raise ValueError('Create arguments must preserve the container for evidence')
    ledger = load_ledger(path)
    if any(item['purpose'] == purpose for item in ledger['containers']):
        raise ValueError('Purpose already registered; inspect the existing transaction')
    image_id = capture('image', 'inspect', '--format', '{{.Id}}', image).decode().strip()
    if not re.fullmatch(r'sha256:[a-f0-9]{64}', image_id):
        raise ValueError('Expected a full image identity')
    # Persist intent before creation so a failed client response can be recovered by labels.
    entry = {'id': None, 'imageId': image_id, 'purpose': purpose,
             'status': 'CREATING', 'createdAtUtc': datetime.now(timezone.utc).isoformat()}
    ledger['containers'].append(entry)
    write_json(path, ledger)
    container = capture('create', '--label', OWNER + '=' + ledger['owner'],
                        '--label', PURPOSE + '=' + purpose, *arguments).decode().strip()
    if not IDENTITY.fullmatch(container):
        raise ValueError('Docker did not return a full container ID; inspect the ledger')
    entry['id'] = container
    write_json(path, ledger)
    verify_identity(inspect(container), entry, ledger['owner'])
    entry['status'] = 'CREATED'
    write_json(path, ledger)
    return container


def changed_layer(container, diff, destination):
    changed = {line[2:].strip() for line in diff.decode('utf-8').splitlines()
               if line.startswith(('A ', 'C '))}
    deleted = sorted(line[2:].strip() for line in diff.decode('utf-8').splitlines()
                     if line.startswith('D '))
    if not changed:
        write_json(destination.with_name('changed-layer-manifest.json'), {
            'containerId': container, 'diffPaths': [], 'archivedPaths': [], 'deletedPaths': deleted,
            'notExportedPaths': [], 'deletionsPreservedIn': 'diff.txt', 'mountedDataIncluded': False})
        return False
    archived = []
    # Docker export excludes mounted data. Keep only exact diff members, not entire
    # changed parent directories or the unchanged multi-GB build image baseline.
    error_path = destination.with_suffix('.stderr')
    with error_path.open('wb') as errors:
        process = subprocess.Popen(['docker', 'export', container], stdout=subprocess.PIPE, stderr=errors)
        try:
            with gzip.open(destination, 'wb') as compressed, \
                    tarfile.open(fileobj=compressed, mode='w|') as output, \
                    tarfile.open(fileobj=process.stdout, mode='r|') as source:
                for member in source:
                    if '/' + member.name.removeprefix('./').rstrip('/') in changed:
                        stream = source.extractfile(member) if member.isfile() else None
                        output.addfile(member, stream)
                        archived.append('/' + member.name.removeprefix('./').rstrip('/'))
            if process.wait() != 0:
                raise RuntimeError('Changed-layer export failed; container retained')
        finally:
            # Drain/reap the export client only. Never signal the container.
            if process.stdout:
                process.stdout.close()
            process.wait()
    write_json(destination.with_name('changed-layer-manifest.json'), {
        'containerId': container, 'diffPaths': sorted(changed), 'archivedPaths': sorted(archived),
        'deletedPaths': deleted,
        'notExportedPaths': sorted(changed - set(archived)),
        'deletionsPreservedIn': 'diff.txt', 'mountedDataIncluded': False})
    if changed - set(archived):
        raise ValueError('Changed-layer export missed diff members; container retained')
    return True


def evidence_hashes(directory):
    result = {}
    for path in sorted(directory.iterdir()):
        if path.is_file():
            path.chmod(0o600)
            with path.open('rb') as stream:
                result[path.name] = {'bytes': path.stat().st_size,
                                     'sha256': hashlib.file_digest(stream, 'sha256').hexdigest()}
    return result


def retire(path):
    ledger = load_ledger(path)
    root = path.parent / (path.stem + '-evidence')
    root.mkdir(parents=True, exist_ok=True)
    root.chmod(0o700)
    for entry in ledger['containers']:
        if entry.get('status') == 'REMOVED_VERIFIED':
            continue
        try:
            if not entry['id']:
                matches = capture('ps', '--all', '--no-trunc', '--quiet',
                                  '--filter', 'label=' + OWNER + '=' + ledger['owner'],
                                  '--filter', 'label=' + PURPOSE + '=' + entry['purpose']).decode().split()
                if len(matches) != 1 or not IDENTITY.fullmatch(matches[0]):
                    raise ValueError('Creation outcome unknown; owned full CID requires review')
                entry['id'] = matches[0]
                write_json(path, ledger)
            container = entry['id']
            try:
                row = inspect(container)
            except Exception:
                # Recover an interrupted rm/absence response only after the saved
                # evidence is still hash-identical and a fresh inventory succeeds.
                if not entry.get('removalRequestedAtUtc') or not entry.get('evidence'):
                    raise
                evidence = entry['evidence']
                if evidence_hashes(Path(evidence['directory'])) != evidence['files']:
                    raise ValueError('Saved removal evidence changed')
                current = capture('ps', '--all', '--no-trunc', '--format', '{{.ID}}').decode().split()
                if container in current:
                    raise ValueError('Container identity is unknown; retained')
                entry.update(status='REMOVED_VERIFIED', absenceVerifiedAtUtc=datetime.now(timezone.utc).isoformat())
                entry.pop('reason', None)
                continue
            verify_identity(row, entry, ledger['owner'])
            directory = root / container
            directory.mkdir(exist_ok=True)
            directory.chmod(0o700)
            write_json(directory / 'inspect.json', row)
            with (directory / 'logs.txt').open('wb') as stream:
                docker('logs', container, stdout=stream, stderr=subprocess.STDOUT)
            diff = capture('diff', container)
            (directory / 'diff.txt').write_bytes(diff)
            if not stopped(row):
                entry.update(status='RETAINED', reason='Container running or state unknown; no stop requested')
                continue
            changed_layer(container, diff, directory / 'changed-layer.tar.gz')
            entry['evidence'] = {'directory': str(directory), 'files': evidence_hashes(directory)}
            entry['status'] = 'EVIDENCE_SAVED'
            write_json(path, ledger)
            # Recheck immediately before ordinary rm; fail closed if it restarted.
            row = inspect(container)
            verify_identity(row, entry, ledger['owner'])
            if not stopped(row):
                raise ValueError('Container restarted; no stop requested')
            entry['removalRequestedAtUtc'] = datetime.now(timezone.utc).isoformat()
            write_json(path, ledger)
            capture('rm', container)
            # A failed inspect alone could mean daemon failure. Require a fresh,
            # successful complete-ID inventory before claiming absence.
            current = capture('ps', '--all', '--no-trunc', '--format', '{{.ID}}').decode().split()
            if container in current:
                raise ValueError('Container remains after ordinary rm')
            entry.update(status='REMOVED_VERIFIED', absenceVerifiedAtUtc=datetime.now(timezone.utc).isoformat())
            entry.pop('reason', None)
        except Exception as error:
            entry.update(status='RETAINED', reason=type(error).__name__ + ': ' + str(error))
        finally:
            write_json(path, ledger)
    remaining = [item for item in ledger['containers'] if item['status'] != 'REMOVED_VERIFIED']
    receipt = {'status': 'INCOMPLETE' if remaining else 'COMPLETE',
               'checkedAtUtc': datetime.now(timezone.utc).isoformat(), 'ledger': str(path),
               'containers': [{key: item.get(key) for key in ('id', 'imageId', 'purpose', 'status', 'reason')}
                              for item in ledger['containers']]}
    write_json(path.with_name(path.stem + '-receipt.json'), receipt)
    print(json.dumps(receipt))
    return 1 if remaining else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ledger', type=Path, required=True)
    commands = parser.add_subparsers(dest='operation', required=True)
    commands.add_parser('cleanup')
    for name in ('create', 'run'):
        command = commands.add_parser(name)
        command.add_argument('--image', required=True)
        command.add_argument('--purpose', required=True)
        command.add_argument('arguments', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.operation == 'cleanup':
        return retire(args.ledger)
    arguments = args.arguments[1:] if args.arguments[:1] == ['--'] else args.arguments
    container = create(args.ledger, args.image, args.purpose, arguments)
    if args.operation == 'create':
        print(container)
        return 0
    result = subprocess.run(['docker', 'start', '--attach', container])
    row = inspect(container)
    if not stopped(row):
        return result.returncode or 1
    return result.returncode or row['State'].get('ExitCode', 1)


if __name__ == '__main__':
    sys.exit(main())
