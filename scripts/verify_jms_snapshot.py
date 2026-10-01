import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import zipfile

from jms_publication import execute, source_files, ReleaseError


# These files cannot affect the recorded Windows application/native build.
# New paths require an explicit review; never allow whole scripts/config trees.
RECORDED_CANDIDATE_REVIEW_PATHS = frozenset({
    'config/jms_public_privacy_reviews.json',
    'scripts/jms_publication.py',
    'scripts/test_jms_publish.py',
    'scripts/jms_desktop_publication.py',
    'scripts/test_jms_desktop_publication.py',
    'scripts/verify_jms_snapshot.py',
    'scripts/test_jms_snapshot_batch.py',
    'scripts/prepare_jms_windows_update.ps1',
    'config/jms_source_derivations.json',
    'scripts/check_jms_git_privacy.py',
    'scripts/jms_source_derivations.py',
    'scripts/test_jms_source_derivations.py',
})


def verify_snapshot(commit, inputs=None):
    if not re.fullmatch('[a-f0-9]{40}', commit):
        raise ReleaseError('Invalid snapshot commit')
    files = source_files() if inputs is None else {entry['path']: entry['sha256'] for entry in inputs}
    selected = [(name, digest) for name, digest in files.items()
                if not (name == 'docs/JMS_STATUS.md' and inputs is None)]
    if any('\n' in name or '\r' in name for name, _ in selected):
        raise ReleaseError('Invalid source filename')
    stream = io.BytesIO(execute(['git', 'cat-file', '--batch'],
                               data=''.join(f'{commit}:{name}\n' for name, _ in selected).encode()))
    for name, digest in selected:
        header = stream.readline().split()
        if len(header) != 3 or header[1] != b'blob':
            raise ReleaseError('Source snapshot object missing: ' + name)
        size = int(header[2])
        data = stream.read(size)
        if len(data) != size or stream.read(1) != b'\n':
            raise ReleaseError('Truncated source snapshot object: ' + name)
        if hashlib.sha256(data).hexdigest() != digest:
            raise ReleaseError('Source snapshot drift: ' + name)
    if stream.read():
        raise ReleaseError('Unexpected source snapshot output')


def verify_recorded_windows_candidate(commit, manifest_path, *,
        source_remote='https://github.com/jim608/JMS-Android.git'):
    """Keep original source/binary identities while later reviews are committed."""
    if not re.fullmatch('[a-f0-9]{40}', commit):
        raise ReleaseError('Invalid recorded Windows source commit')
    from jms_git_release import committed_source
    committed_source(commit, allow_ancestor=True)
    remote = execute(['git', 'ls-remote', source_remote, 'refs/heads/jms']).decode().split()
    if len(remote) != 2 or remote[1] != 'refs/heads/jms':
        raise ReleaseError('Recorded candidate source branch is unavailable')
    execute(['git', 'merge-base', '--is-ancestor', commit, remote[0]])
    changed = execute(['git', 'diff', '--name-only', '-z', commit, 'HEAD']).decode().split('\0')
    if any(name and name not in RECORDED_CANDIDATE_REVIEW_PATHS for name in changed):
        raise ReleaseError('Recorded candidate application or build inputs changed')
    files = source_files()
    inputs = [{'path': name, 'sha256': digest} for name, digest in files.items()
              if name not in RECORDED_CANDIDATE_REVIEW_PATHS]
    verify_snapshot(commit, inputs)
    manifest_path = Path(manifest_path)
    record = json.loads(manifest_path.read_text(encoding='utf-8-sig'))
    build = record['build']
    if (build.get('sourceCommit') != commit or build.get('platform') != 'windows-x64'
            or build.get('privateConfiguration') is not False
            or build.get('signing') != 'unsigned'
            or build.get('application') != 'JMS'):
        raise ReleaseError('Recorded Windows candidate identity is invalid')
    version = re.search(rb'^version:\s*(\S+)', execute(['git', 'show', commit + ':pubspec.yaml']), re.M)
    if (not version or version[1].decode() != build['version'] + '+' + str(build['versionCode'])
            or build.get('buildId') != 'JMS-' + build['version'] + '-windows-' + commit[:12]):
        raise ReleaseError('Recorded Windows candidate version or build identity differs')
    expected = {f'JMS-Windows-{build["version"]}-x64-setup.exe',
                f'JMS-Windows-{build["version"]}-x64-portable.zip'}
    outputs = record['outputs']
    if len(outputs) != 2 or {item['file'] for item in outputs} != expected:
        raise ReleaseError('Recorded Windows candidate output set differs')
    for item in outputs:
        path = manifest_path.parent / item['file']
        if (path.is_symlink() or not path.is_file() or path.stat().st_size != item['size']
                or hashlib.sha256(path.read_bytes()).hexdigest() != item['sha256']):
            raise ReleaseError('Recorded Windows candidate output fingerprint differs')
    portable = manifest_path.parent / f'JMS-Windows-{build["version"]}-x64-portable.zip'
    native = json.loads(execute(['git', 'show', commit + ':config/jms_windows_native.json']))
    with zipfile.ZipFile(portable) as archive:
        if len(archive.namelist()) != len(set(archive.namelist())):
            raise ReleaseError('Recorded Windows portable has duplicate members')
        prefix = f'JMS-Windows-{build["version"]}-x64/'
        if json.loads(archive.read(prefix + 'JMS_BUILD_INFO.json')) != build:
            raise ReleaseError('Actual Windows portable build identity differs')
        for item in native['libraries']:
            if hashlib.sha256(archive.read(prefix + item['dll'])).hexdigest() != item['sha256']:
                raise ReleaseError('Actual Windows native binary differs from recorded sources')
    return {'sourceCommit': commit, 'buildId': build['buildId'], 'unchangedInputs': len(inputs),
            'inputFingerprint': hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest(),
            'manifestSha256': hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
            'nativeBinaries': len(native['libraries']), 'outputs': outputs,
            'laterReviewedPaths': sorted(name for name in changed if name)}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--commit', required=True)
    parser.add_argument('--recorded-windows-candidate')
    args = parser.parse_args()
    if args.recorded_windows_candidate:
        print(json.dumps(verify_recorded_windows_candidate(args.commit, args.recorded_windows_candidate), indent=2))
    else:
        verify_snapshot(args.commit)
        print('Source snapshot matches reviewed worktree')
