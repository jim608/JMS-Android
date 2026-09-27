import argparse
import hashlib
import re

from jms_publication import execute, source_files, ReleaseError


def verify_snapshot(commit, inputs=None):
    if not re.fullmatch('[a-f0-9]{40}', commit):
        raise ReleaseError('Invalid snapshot commit')
    files = source_files() if inputs is None else {entry['path']: entry['sha256'] for entry in inputs}
    for name, digest in files.items():
        if name == 'docs/JMS_STATUS.md' and inputs is None:
            continue
        data = execute(['git', 'cat-file', 'blob', f'{commit}:{name}'])
        if hashlib.sha256(data).hexdigest() != digest:
            raise ReleaseError('Source snapshot drift: ' + name)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--commit', required=True)
    args = parser.parse_args()
    verify_snapshot(args.commit)
    print('Source snapshot matches reviewed worktree')
