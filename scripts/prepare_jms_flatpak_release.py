"""Prepare a reviewed Flatpak-only candidate for the existing Linux publisher."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import tarfile
import tempfile
import zipfile

from jms_publication import ReleaseError, sha256
from jms_release_notes import release_notes_for, release_body_for_candidate
from jms_desktop_publication import verify_flatpak_payload, verify_source_archive


def item(path):
    return {'name': path.name, 'size': path.stat().st_size, 'sha256': sha256(path)}


def canonical_source_notes(source, version, commit):
    with zipfile.ZipFile(source) as archive:
        manifest = json.loads(archive.read('JMS/source-manifest.json'))
        if manifest.get('sourceCommit') != commit or manifest.get('dirty') is not False:
            raise ReleaseError('Flatpak source archive is not bound to the committed candidate')
        changelog = archive.read('JMS/CHANGELOG.md')
        version_line = re.search(rb'^version:\s*(\S+)\s*$', archive.read('JMS/pubspec.yaml'), re.M)
        if not version_line or version_line[1].decode().split('+')[0] != version:
            raise ReleaseError('Flatpak source archive version differs from candidate')
    with tempfile.TemporaryDirectory(prefix='jms-flatpak-notes-') as temporary:
        path = Path(temporary) / 'CHANGELOG.md'
        path.write_bytes(changelog)
        return release_notes_for(path, version)


def native_source_materials(directory, build, material):
    evidence = json.loads((directory / 'flatpak-native-sources.json').read_text(encoding='utf-8'))
    if evidence.get('build') != build or not evidence.get('sources'):
        raise ReleaseError('Flatpak corresponding source identity or component inventory missing')
    with tarfile.open(directory / material, 'r:gz') as archive:
        if json.load(archive.extractfile('source-materials.json')) != evidence:
            raise ReleaseError('Flatpak native source archive differs from evidence manifest')
        names = archive.getnames()
        if len(names) != len(set(names)):
            raise ReleaseError('Flatpak native source archive has duplicate members')
        for source in evidence['sources']:
            digest = source.get('sha256', '')
            if (not re.fullmatch('[a-f0-9]{64}', digest)
                    or not source.get('url', '').startswith('https://')):
                raise ReleaseError('Flatpak native source lacks pinned origin/hash')
            if 'member' in source:
                name = source['member']
            elif source.get('module') == 'unchanged-native-plugins':
                name = 'unchanged-native-plugins/' + source['url'].rsplit('/', 1)[-1]
            else:
                raise ReleaseError('Flatpak native source archive binding missing')
            member = archive.getmember(name)
            if not member.isfile() or member.size > 512 * 1024 * 1024:
                raise ReleaseError('Flatpak native source member is missing or too large')
            with archive.extractfile(member) as stream:
                if hashlib.file_digest(stream, 'sha256').hexdigest() != digest:
                    raise ReleaseError('Flatpak native source member differs from pinned source')
    return evidence


def prepare(directory, run_id):
    directory = Path(directory).resolve()
    if type(run_id) is not int or run_id <= 0:
        raise ReleaseError('Successful Flatpak CI run ID required')
    manifest = json.loads((directory / 'flatpak-build-manifest.json').read_text(encoding='utf-8'))
    build = manifest['build']
    commit = build.get('sourceCommit', '')
    version = build.get('versionName')
    code = build.get('versionCode')
    if (not re.fullmatch('[a-f0-9]{40}', commit) or not isinstance(version, str)
            or not re.fullmatch(r'[A-Za-z0-9._-]+', version) or type(code) is not int or code < 0
            or build.get('applicationId') != 'com.jim608.jms'
            or build.get('platform') != 'linux-x64' or build.get('packageFormat') != 'flatpak'
            or build.get('buildId') != f'JMS-{version}-flatpak-{commit[:12]}'):
        raise ReleaseError('Flatpak CI build identity is invalid')
    material = f'JMS-Linux-{version}-flatpak-native-materials.tar.gz'
    native_source_materials(directory, build, material)
    receipt = json.loads((directory / 'flatpak-verification.json').read_text(encoding='utf-8'))
    runtime = json.loads((directory / 'validation/runtime-validation.json').read_text(encoding='utf-8'))
    if runtime != receipt.get('validation'):
        raise ReleaseError('Flatpak installed runtime verification differs from receipt')
    source = f'JMS-{version}-source.zip'
    notes = canonical_source_notes(directory / source, version, commit)
    body = release_body_for_candidate(notes, version, commit, build['buildId'])
    record = {
        **build, 'repository': 'jim608/JMS-Linux', 'sourceRepository': 'jim608/JMS-Android',
        'releaseTag': 'v' + version, 'validation': runtime,
        'canonicalNotes': notes, 'canonicalNotesCommit': commit,
        'nativeReview': {'platform': 'linux-x64', 'missing': [], 'materials': [material],
                         'binaries': manifest['binaries'],
                         'evidence': 'flatpak-native-sources.json'},
        'flatpak': {
            'bundle': f'JMS-Linux-{version}-x86_64.flatpak',
            'payload': f'JMS-Linux-{version}-flatpak-payload.tar.gz',
            'receipt': 'flatpak-verification.json', 'buildManifest': 'flatpak-build-manifest.json',
            'nativeSources': 'flatpak-native-sources.json', 'source': source,
            'ci': {'runId': run_id, 'artifactName': 'jms-flatpak-' + commit}},
    }
    public_names = {record['flatpak'][field] for field in
                    ('bundle', 'payload', 'receipt', 'buildManifest', 'nativeSources', 'source')}
    public_names.add(material)
    entries = [item(directory / name) for name in sorted(public_names)]
    files = {entry['name']: {'path': str(directory / entry['name']),
                            'size': entry['size'], 'sha256': entry['sha256']} for entry in entries}
    verify_flatpak_payload(directory, record, files)
    verify_source_archive(directory / source, commit)
    notes_entry = {'name': 'RELEASE_NOTES.md', 'size': len(body.encode()),
                   'sha256': hashlib.sha256(body.encode()).hexdigest()}
    entries.append(notes_entry)
    checksum_text = ''.join(entry['sha256'] + '  ' + entry['name'] + '\n'
                            for entry in sorted(entries, key=lambda entry: entry['name']))
    entries.append({'name': 'SHA256SUMS.txt', 'size': len(checksum_text.encode('ascii')),
                    'sha256': hashlib.sha256(checksum_text.encode('ascii')).hexdigest()})
    record['assets'] = sorted(entries, key=lambda entry: entry['name'])
    pending = {'RELEASE_NOTES.md': body.encode(), 'SHA256SUMS.txt': checksum_text.encode('ascii'),
               'desktop-publication.json': (json.dumps(record, indent=2, ensure_ascii=False) + '\n').encode()}
    for name, content in pending.items():
        path = directory / name
        if path.exists() and path.read_bytes() != content:
            raise ReleaseError('Prepared candidate already differs; refusing replacement: ' + name)
    for name, content in pending.items():
        path = directory / name
        if not path.exists():
            path.write_bytes(content)
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate-directory', type=Path, required=True)
    parser.add_argument('--run-id', type=int, required=True)
    args = parser.parse_args()
    try:
        record = prepare(args.candidate_directory, args.run_id)
    except (OSError, ValueError, KeyError, ReleaseError) as error:
        parser.exit(1, 'FLATPAK PREPARATION STOPPED: ' + str(error) + '\n')
    print(json.dumps({'version': record['versionName'], 'sourceCommit': record['sourceCommit'],
                      'buildId': record['buildId'], 'assets': len(record['assets'])}))


if __name__ == '__main__':
    main()
