"""Archive exact committed source, including pinned submodules, without local data."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
import sys
import zipfile


def committed_archive(commit, destination, root=None, build_record=None):
    root = Path(root or Path(__file__).resolve().parents[1]).resolve()
    destination = Path(destination)
    if not re.fullmatch(r'[a-f0-9]{40}', commit):
        raise ValueError('Full source commit required')
    if destination.exists():
        raise ValueError('Source archive already exists; refusing replacement')
    files = {}

    def command(repository, *args):
        return subprocess.check_output(['git', '-C', str(repository), *args], stderr=subprocess.PIPE)

    def export(archive, repository, revision, prefix='', depth=0):
        if depth > 8:
            raise ValueError('Submodule nesting limit exceeded')
        top = Path(command(repository, 'rev-parse', '--show-toplevel').decode().strip()).resolve()
        if top != repository.resolve():
            raise ValueError('Pinned submodule checkout is missing')
        entries = []
        for entry in filter(None, command(repository, 'ls-tree', '-rz', revision).split(b'\0')):
            meta, name = entry.split(b'\t', 1)
            mode, kind, oid = meta.decode().split()
            entries.append((mode, kind, oid, name.decode()))
        blobs = [entry for entry in entries if entry[1] == 'blob']
        stream = io.BytesIO(subprocess.check_output(
            ['git', '-C', str(repository), 'cat-file', '--batch'],
            input=('\n'.join(entry[2] for entry in blobs) + '\n').encode()))
        for mode, _, oid, relative in blobs:
            header = stream.readline().split()
            if len(header) != 3 or header[0].decode() != oid or header[1] != b'blob':
                raise ValueError('Invalid committed source object')
            size = int(header[2])
            if size > 64 * 1024 * 1024:
                raise ValueError('Unexpectedly large source member')
            data = stream.read(size)
            if len(data) != size or stream.read(1) != b'\n':
                raise ValueError('Truncated committed source object')
            name = prefix + relative
            if Path(name).name == 'AGENTS.md':
                raise ValueError('Local-only instructions found in committed source')
            item = zipfile.ZipInfo('JMS/' + name)
            item.create_system = 3
            item.external_attr = int(mode, 8) << 16
            item.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(item, data)
            files[name] = hashlib.sha256(data).hexdigest()
        for _, kind, oid, relative in entries:
            if kind != 'commit':
                continue
            export(archive, repository / relative, oid, prefix + relative + '/', depth + 1)
            archive.writestr('JMS/' + prefix + relative + '/JMS_SUBMODULE_SOURCE.json',
                             json.dumps({'commit': oid, 'path': prefix + relative}))

    destination.parent.mkdir(parents=True, exist_ok=True)
    pending = destination.with_name(destination.name + '.pending')
    if pending.exists():
        raise ValueError('Incomplete source preparation exists; inspect before resuming')
    with zipfile.ZipFile(pending, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        export(archive, root, commit)
        if build_record is not None:
            if build_record.get('sourceCommit') != commit:
                raise ValueError('Build record belongs to another source commit')
            for entry in build_record.get('inputs', []):
                if files.get(entry['path']) != entry['sha256']:
                    raise ValueError('Build input differs from committed source')
            archive.writestr('JMS/build-inputs.json', json.dumps(build_record, indent=2))
        archive.writestr('JMS/source-manifest.json', json.dumps(
            {'sourceCommit': commit, 'dirty': False, 'files': files}, indent=2))
    pending.rename(destination)
    return files


def main():
    if '--release' in sys.argv:
        from prepare_jms_release import main as prepare
        prepare()
        return
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--commit', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    files = committed_archive(args.commit, args.output)
    print(f'Committed source archive: {len(files)} files, including pinned submodule contents')


if __name__ == '__main__':
    main()
