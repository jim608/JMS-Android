"""Record owned test containers and retire stopped containers with retained evidence.

Inspect output stays in the private evidence directory; console output contains IDs only.
This helper never stops a running container and never deletes images, mounts or volumes.
"""
import argparse
import base64
from datetime import datetime, timezone
import gzip
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import tarfile
import uuid
import urllib.parse

OWNER = 'com.jim608.jms.test-owner'
PURPOSE = 'com.jim608.jms.test-purpose'
IDENTITY = re.compile(r'[a-f0-9]{64}')
GO_MODE_SOCKET = 1 << 24
GO_MODE_TYPE = sum(1 << bit for bit in (31, 27, 26, 25, 24, 21, 19))
GO_MODE_KNOWN = sum(1 << bit for bit in range(19, 32)) | 0o777


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


def lifecycle(row):
    return {key: row.get('State', {}).get(key) for key in ('StartedAt', 'FinishedAt', 'ExitCode')}


def engine_request(method, path):
    """Read the same local Unix-socket daemon as the Docker CLI; never use TCP/TLS overrides."""
    context_host = lambda: json.loads(capture('context', 'inspect', '--format', '{{json .Endpoints.docker.Host}}'))
    host = context_host() if os.environ.get('DOCKER_CONTEXT') else os.environ.get('DOCKER_HOST') or context_host()
    endpoint = urllib.parse.urlparse(host)
    if (endpoint.scheme != 'unix' or endpoint.netloc or not endpoint.path.startswith('/')
            or endpoint.query or endpoint.fragment):
        raise ValueError('Socket metadata requires the same local Unix Docker endpoint; retained')

    class UnixConnection(http.client.HTTPConnection):
        def connect(self):
            self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.sock.settimeout(self.timeout)
            self.sock.connect(endpoint.path)

    connection = UnixConnection('localhost', timeout=30)
    try:
        connection.request(method, path)
        response = connection.getresponse()
        data = response.read(1024 * 1024 + 1)
        if response.status != 200 or len(data) > 1024 * 1024:
            raise ValueError('Docker socket metadata request failed; retained')
        return {key.lower(): value for key, value in response.getheaders()}, data
    finally:
        connection.close()


def archive_socket_metadata(container, paths, directory):
    """Preserve metadata for verified Unix sockets that tar cannot represent.

    HEAD /containers/{id}/archive supplies Docker's Go FileMode, not POSIX st_mode.
    Missing regular files, links, FIFOs, unknown modes or failed HEAD requests still fail.
    """
    expected = json.loads((directory / 'inspect.json').read_text(encoding='utf-8'))
    labels = expected.get('Config', {}).get('Labels') or {}
    entry = {'id': container, 'imageId': expected['Image'], 'purpose': labels[PURPOSE]}
    owner = labels[OWNER]
    baseline_lifecycle = lifecycle(expected)

    def identity(suffix):
        _, data = engine_request('GET', '/containers/' + container + '/json')
        row = json.loads(data)
        verify_identity(row, entry, owner)
        if not stopped(row) or lifecycle(row) != baseline_lifecycle:
            raise ValueError('Container lifecycle changed during socket metadata capture; retained')
        write_json(directory / ('socket-daemon-inspect-' + suffix + '.json'), row)

    def stat(path):
        if not path.startswith('/') or '\x00' in path:
            raise ValueError('Invalid diff member path; retained')
        headers, _ = engine_request('HEAD', '/containers/' + container + '/archive?' +
                                    urllib.parse.urlencode({'path': path}))
        value = json.loads(base64.b64decode(headers['x-docker-container-path-stat'], validate=True))
        mode = value.get('mode')
        if (type(mode) is not int or not 0 <= mode <= 0xffffffff
                or mode & ~GO_MODE_KNOWN or mode & GO_MODE_TYPE != GO_MODE_SOCKET
                or value.get('name') != path.rsplit('/', 1)[-1]
                or type(value.get('size')) is not int or value['size'] != 0
                or value.get('linkTarget') not in ('', None)
                or not isinstance(value.get('mtime'), str) or not value['mtime']):
            raise ValueError('Missing export member is not a verified zero-payload Unix socket; retained')
        return value

    identity('before')
    records = [{'path': path, 'stat': stat(path), 'payloadBytes': 0,
                'kind': 'unix-socket', 'archiveRepresentation': 'Docker Engine HEAD metadata'}
               for path in sorted(paths)]
    identity('after')
    for record in records:
        if stat(record['path']) != record['stat']:
            raise ValueError('Socket stat changed during capture; retained')
    write_json(directory / 'non-exportable-sockets.json', {
        'containerId': container, 'imageId': entry['imageId'], 'purpose': entry['purpose'],
        'lifecycle': baseline_lifecycle, 'allTypesVerified': True, 'records': records,
        'source': 'Docker Engine HEAD container archive X-Docker-Container-Path-Stat',
        'modeEncoding': 'Go io/fs FileMode; ModeType must equal ModeSocket (1<<24)',
        'containsFilePayload': False})
    return {record['path'] for record in records}


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
    manifest = {
        'containerId': container, 'diffPaths': sorted(changed), 'archivedPaths': sorted(archived),
        'deletedPaths': deleted,
        'notExportedPaths': sorted(changed - set(archived)),
        'metadataOnlyPaths': [], 'unpreservedPaths': sorted(changed - set(archived)),
        'deletionsPreservedIn': 'diff.txt', 'mountedDataIncluded': False}
    manifest_path = destination.with_name('changed-layer-manifest.json')
    write_json(manifest_path, manifest)
    if manifest['notExportedPaths']:
        preserved = archive_socket_metadata(container, manifest['notExportedPaths'], destination.parent)
        manifest['metadataOnlyPaths'] = sorted(preserved)
        manifest['unpreservedPaths'] = sorted(changed - set(archived) - preserved)
        manifest['specialFileMetadata'] = 'non-exportable-sockets.json'
        write_json(manifest_path, manifest)
    if manifest['unpreservedPaths']:
        raise ValueError('Changed-layer export missed unpreserved diff members; container retained')
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
            if lifecycle(row) != lifecycle(json.loads((directory / 'inspect.json').read_text(encoding='utf-8'))):
                raise ValueError('Container lifecycle changed after archive; retained')
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
