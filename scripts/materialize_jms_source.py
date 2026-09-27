"""Normalize only clean checkout line endings to exact committed source bytes."""
import argparse
from pathlib import Path
import subprocess


def materialize(apply=False):
    if subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=all']).strip():
        raise ValueError('Commit reviewed work before materializing source')
    names = subprocess.check_output(['git', 'ls-files', '-z']).decode().split('\0')
    changes = []
    process = subprocess.Popen(['git', 'cat-file', '--batch'], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    try:
        for name in filter(None, names):
            path = Path(name)
            if not path.is_file() or path.is_symlink():
                continue
            process.stdin.write(('HEAD:' + name + '\n').encode())
            process.stdin.flush()
            header = process.stdout.readline().split()
            if len(header) != 3 or header[1] != b'blob':
                raise ValueError('Unexpected source object')
            content = process.stdout.read(int(header[2]))
            process.stdout.read(1)
            original = path.read_bytes()
            if original != content:
                if original.replace(b'\r\n', b'\n') != content.replace(b'\r\n', b'\n'):
                    raise ValueError('Non-line-ending source drift: ' + name)
                changes.append((path, content))
    finally:
        process.stdin.close()
        process.stdout.close()
        process.wait()
    if apply:
        for path, content in changes:
            path.write_bytes(content)
        if changes:
            subprocess.run(['git', 'add', '--pathspec-from-file=-', '--pathspec-file-nul'],
                           input=b'\0'.join(path.as_posix().encode() for path, _ in changes) + b'\0',
                           check=True, capture_output=True)
            if subprocess.check_output(['git', 'diff', '--cached', '--name-only']).strip():
                raise ValueError('Normalization unexpectedly changed the index; stop before building')
    print(f'Committed byte normalization: {len(changes)} files; applied={apply}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    materialize(parser.parse_args().apply)
