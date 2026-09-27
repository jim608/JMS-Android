import hashlib
import json
import pathlib
import re
import subprocess
import zipfile
import sys

if '--release' in sys.argv:
    from prepare_jms_release import main
    main()
    sys.exit(0)

root = pathlib.Path(__file__).resolve().parents[1]
version = re.search(r'(?m)^version:\s*([^\s+]+)\+\d+$', (root / 'pubspec.yaml').read_text(encoding='utf-8')).group(1)
destination = root / 'artifacts'
destination.mkdir(exist_ok=True)
paths = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=root).decode('utf-8').split('\0')
entries = {}
archive_path = destination / f'JMS-{version}-source.zip'
with zipfile.ZipFile(archive_path, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
    for name in sorted(set(paths)):
        if not name or not (root / name).is_file():
            continue
        path = root / name
        if path.name in {'key.properties', 'local.properties'} or path.suffix in {'.jks', '.keystore', '.apk'}:
            raise SystemExit(f'Refusing to package private or generated file: {name}')
        data = path.read_bytes()
        archive.writestr('JMS/' + name, data)
        entries[name] = hashlib.sha256(data).hexdigest()
commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
status = subprocess.check_output(['git', '-c', 'core.quotePath=false', 'status', '--porcelain=v1', '--untracked-files=all'], cwd=root, text=True)
(destination / 'source-worktree-status.txt').write_text(status, encoding='utf-8')
(destination / 'source-changes.patch').write_bytes(subprocess.check_output(['git', 'diff', '--binary', 'HEAD'], cwd=root))
manifest = {'base_commit': commit, 'uncommitted_changes': True, 'archive': archive_path.name, 'archive_sha256': hashlib.sha256(archive_path.read_bytes()).hexdigest(), 'files': entries, 'native_dependency_source_audit': 'BLOCKED; see docs/JMS_SOURCES.md'}
(destination / 'source-manifest.json').write_text(json.dumps(manifest, indent=2, ensure_ascii=False), encoding='utf-8')
print(f'{archive_path}: {len(entries)} source files, SHA-256 {manifest["archive_sha256"]}')
evidence_path = destination / f'JMS-{version}-verification.zip'
with zipfile.ZipFile(evidence_path, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
    for directory in ('baseline', 'checks', 'subtitles'):
        for path in sorted((destination / directory).rglob('*')):
            if path.is_file():
                archive.write(path, path.relative_to(destination).as_posix())
    for name in ('source-worktree-status.txt', 'source-manifest.json', 'source-changes.patch'):
        archive.write(destination / name, name)
delivery = {}
for path in (archive_path, evidence_path, destination / f'JMS-Android-{version}-release-arm64-test-signed.apk'):
    delivery[path.name] = {'bytes': path.stat().st_size, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
(destination / 'delivery-manifest.json').write_text(json.dumps(delivery, indent=2), encoding='utf-8')
print(json.dumps(delivery, indent=2))
