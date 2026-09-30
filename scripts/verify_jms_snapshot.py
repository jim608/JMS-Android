import argparse
import hashlib
import io
import re

from jms_publication import execute, source_files, ReleaseError


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


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--commit', required=True)
    args = parser.parse_args()
    verify_snapshot(args.commit)
    print('Source snapshot matches reviewed worktree')
