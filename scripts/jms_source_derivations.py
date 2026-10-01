"""Exact, bounded lineage for deliberately scoped native source materials.

This module does not approve removed data or privacy findings. Retained source
members still pass through the normal package scanner and exact public reviews.
"""

import gzip
import hashlib
import io
import json
from pathlib import Path
import tarfile
import time
import zipfile


ROOT = Path(__file__).resolve().parents[1]
MAX_BYTES = 512 * 1024**2
MAX_MEMBERS = 12000
MAX_SECONDS = 60


def digest(data):
    return hashlib.sha256(data).hexdigest()


def policy_entries(project=None):
    path = Path(project or ROOT) / 'config/jms_source_derivations.json'
    return json.loads(path.read_text(encoding='utf-8')) if path.is_file() else []


def lineage_cache_inputs(material_hashes, project=None):
    project = Path(project or ROOT)
    relevant = [entry for entry in policy_entries(project)
                if entry.get('archiveSha256') in material_hashes]
    if not relevant:
        return None
    originals = []
    for entry in relevant:
        name = entry['origin']['archive']
        candidates = [project / 'artifacts/checks/windows-release-closeout/native-ready' / name,
                      project / 'artifacts/checks/m32/msys' / name]
        path = next((item for item in candidates if item.is_file()), None)
        if path is None or path.stat().st_size > MAX_BYTES:
            raise ValueError('Pinned original source is unavailable for lineage cache')
        with path.open('rb') as stream:
            originals.append(hashlib.file_digest(stream, 'sha256').hexdigest())
    return {'policies': relevant, 'originals': originals,
            'validator': digest(Path(__file__).read_bytes()),
            'nativePins': digest((project / 'config/jms_windows_native.json').read_bytes())}


def tar_members(data, compression):
    """Return descriptors and payload hashes, rejecting incomplete containers."""
    import zstandard

    started = time.monotonic()
    source = io.BytesIO(data)
    stream = (zstandard.ZstdDecompressor().stream_reader(source)
              if compression == 'zstd' else gzip.GzipFile(fileobj=source))
    result = {}
    payloads = {}
    expanded = 0
    class Reader(io.RawIOBase):
        def readable(self):
            return True

        def read(self, size=-1):
            nonlocal expanded
            if time.monotonic() - started > MAX_SECONDS:
                raise ValueError('Source lineage inspection time limit exceeded')
            payload = stream.read(min(size if size >= 0 else 1024 * 1024,
                                      MAX_BYTES - expanded + 1))
            expanded += len(payload)
            if expanded > MAX_BYTES:
                raise ValueError('Source lineage expansion limit exceeded')
            return payload

    bounded = Reader()
    with stream, tarfile.open(fileobj=bounded, mode='r|') as archive:
        for member in archive:
            if (time.monotonic() - started > MAX_SECONDS
                    or len(result) >= MAX_MEMBERS or member.size > MAX_BYTES):
                raise ValueError('Source lineage resource limit exceeded')
            if member.name in result:
                raise ValueError('Duplicate source lineage member')
            if (member.name.startswith('/') or '..' in Path(member.name).parts
                    or member.isdev() or member.isfifo() or member.issparse()):
                raise ValueError('Unsupported source lineage member')
            payload = archive.extractfile(member).read() if member.isfile() else b''
            descriptor = {'type': member.type.decode('ascii'), 'size': member.size,
                          'mode': member.mode, 'uid': member.uid, 'gid': member.gid,
                          'uname': member.uname, 'gname': member.gname,
                          'mtime': member.mtime, 'linkname': member.linkname,
                          'pax': member.pax_headers,
                          'sha256': digest(payload) if member.isfile() else None}
            result[member.name] = descriptor
            if compression == 'zstd' and member.isfile():
                payloads[member.name] = payload
        # Reach the compression checksum/end rather than accepting a truncated
        # container merely because tar encountered its end-of-archive blocks.
        while bounded.read(1024 * 1024):
            pass
    return result, payloads


def derived_recipe(original, original_source_hash, derived_source_hash):
    """Adapt acquisition only; compile, tests and install functions stay intact."""
    text = original.decode('utf-8')
    source = '"https://github.com/openssl/openssl/releases/download/openssl-${pkgver}/openssl-${pkgver}.tar.gz"{,.asc}'
    if (text.count(source) != 1 or text.count(original_source_hash) != 1
            or text.count("            'SKIP'\n") != 1):
        raise ValueError('Original source recipe does not match reviewed form')
    text = text.replace(source, '"openssl-${pkgver}.tar.gz"')
    text = text.replace(original_source_hash, derived_source_hash)
    text = text.replace("            'SKIP'\n", '')
    return ('# JMS derived source acquisition; upstream signature applies only to the original archive.\n'
            '# Build with makepkg-mingw -p PKGBUILD.jms-derived; checksum and tests remain enabled.\n'
            + text).encode('utf-8')


def scope_text():
    return ('# OpenSSL 派生相應來源材料\n\n'
            '本材料保留固定上游來源的所有建置、安裝、授權及其餘測試內容，'
            '僅排除清單所列三個未參與隨包 DLL 建置、安裝或執行的舊私鑰測資。'
            '這是明確標示的派生材料，不是原始上游封存；被排除內容未取得隱私核可。\n\n'
            '原始 PKGBUILD、修補、來源網址、SHA256 與簽章原樣保留供追溯。'
            '原始簽章只適用於原始上游 tar.gz，不適用於派生 tar.gz。'
            'PKGBUILD.jms-derived 只變更來源取得與校驗值；prepare、build、check、package 函式原樣保留。'
            '在對應 MSYS2 MINGW64 建置環境，以 makepkg-mingw -p PKGBUILD.jms-derived 建置，'
            '仍執行來源 SHA256 校驗及原始測試，不使用略過校驗或測試選項。'
            '本輪隨包 DLL 未重新編譯，二進位仍綁定原始建置記錄。\n').encode('utf-8')


def removal_script():
    return b'''"""Reproduce only the recorded source-data exclusions; never run upstream code."""
import gzip, hashlib, io, json, sys, tarfile
from pathlib import Path

original, manifest_path, destination = map(Path, sys.argv[1:])
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
data = original.read_bytes()
assert hashlib.sha256(data).hexdigest() == manifest["originalSourceSha256"]
removed = {item["member"]: item["sha256"] for item in manifest["removed"]}
assert len(removed) == 3
seen = set()
output = io.BytesIO()
with gzip.GzipFile(fileobj=output, mode="wb", mtime=0, filename="", compresslevel=9) as compressed:
    with tarfile.open(fileobj=compressed, mode="w|", format=tarfile.PAX_FORMAT) as target:
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as source:
            for item in source:
                payload = source.extractfile(item).read() if item.isfile() else b""
                if item.name in removed:
                    assert item.isfile() and hashlib.sha256(payload).hexdigest() == removed[item.name]
                    seen.add(item.name)
                else:
                    target.addfile(item, io.BytesIO(payload) if item.isfile() else None)
assert seen == set(removed)
result = output.getvalue()
assert hashlib.sha256(result).hexdigest() == manifest["derivedSourceSha256"]
assert not destination.exists()
destination.write_bytes(result)
'''


def verify_lineage(data, policy, project=None):
    """Return only unchanged regular-member origin identities after full proof."""
    project = Path(project or ROOT)
    if digest(data) != policy['archiveSha256']:
        raise ValueError('Derived source archive fingerprint changed')
    origin = policy['origin']
    if (Path(origin['archive']).name != origin['archive']
            or '/' in origin['archive'] or '\\' in origin['archive']):
        raise ValueError('Unsafe original source archive name')
    native = json.loads((project / 'config/jms_windows_native.json').read_text(encoding='utf-8'))
    pin = native['sources'].get(origin['archive'])
    official_url = native['sourceBase'].rstrip('/') + '/' + origin['archive']
    if (not pin or pin['sha256'] != origin['sha256'] or official_url != origin['url']
            or not origin['url'].startswith('https://repo.msys2.org/mingw/sources/')):
        raise ValueError('Derived source origin is not pinned official material')
    candidates = [project / 'artifacts/checks/windows-release-closeout/native-ready' / origin['archive'],
                  project / 'artifacts/checks/m32/msys' / origin['archive']]
    source = next((path for path in candidates if path.is_file()), None)
    if source is None or source.stat().st_size > MAX_BYTES:
        raise ValueError('Pinned original source is unavailable for lineage verification')
    original = source.read_bytes()
    if digest(original) != origin['sha256']:
        raise ValueError('Pinned original source fingerprint changed')
    outer, original_files = tar_members(original, 'zstd')
    inner_name = policy['sourceMember']
    inner, _ = tar_members(original_files[inner_name], 'gzip')
    removed = policy['removed']
    if len(removed) != 3 or len({item['member'] for item in removed}) != 3:
        raise ValueError('Derived source scope is not the exact reviewed three members')
    for item in removed:
        if (inner.get(item['member'], {}).get('sha256') != item['sha256']
                or not item.get('reason') or not item.get('evidence')):
            raise ValueError('Excluded source member was not exactly identified')
        for reference in item['evidence']:
            if inner.get(reference['member'], {}).get('sha256') != reference['sha256']:
                raise ValueError('Source exclusion build evidence changed')
    extras = {'JMS_DERIVATION.json', 'JMS_SOURCE_SCOPE.md', 'PKGBUILD.jms-derived',
              'JMS_REMOVE_UNUSED_FIXTURES.py'}
    root = inner_name.rsplit('/', 1)[0]
    additions = {root + '/' + name for name in extras}
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        names = [item.filename for item in archive.infolist()]
        expected = set(original_files) | additions
        if len(names) != len(set(names)) or set(names) != expected:
            raise ValueError('Derived source contains added or missing unreviewed members')
        derived_files = {}
        total = 0
        for item in archive.infolist():
            if item.is_dir() or item.file_size > MAX_BYTES:
                raise ValueError('Invalid derived source container member')
            total += item.file_size
            if total > MAX_BYTES:
                raise ValueError('Derived source container expansion limit exceeded')
            derived_files[item.filename] = archive.read(item)
    derived_inner, _ = tar_members(derived_files[inner_name], 'gzip')
    expected_inner = {name: item for name, item in inner.items()
                      if name not in {item['member'] for item in removed}}
    if derived_inner != expected_inner:
        raise ValueError('Retained source bytes or metadata changed')
    for name, payload in original_files.items():
        if name != inner_name and derived_files[name] != payload:
            raise ValueError('Original source recipe, patch or signature changed')
    manifest_bytes = derived_files[root + '/JMS_DERIVATION.json']
    if digest(manifest_bytes) != policy['manifestSha256']:
        raise ValueError('Source derivation manifest fingerprint changed')
    manifest = json.loads(manifest_bytes)
    expected_manifest = {key: policy[key] for key in ('origin', 'sourceMember', 'removed')}
    expected_manifest.update({'schemaVersion': 1,
                             'derivedSourceSha256': digest(derived_files[inner_name]),
                             'originalSourceSha256': digest(original_files[inner_name]),
                             'retainedMembers': len(expected_inner),
                             'retainedRegularFiles': sum(item['sha256'] is not None
                                                         for item in expected_inner.values())})
    if manifest != expected_manifest or derived_files[root + '/JMS_SOURCE_SCOPE.md'] != scope_text():
        raise ValueError('Derived source scope or transformation record changed')
    if derived_files[root + '/JMS_REMOVE_UNUSED_FIXTURES.py'] != removal_script():
        raise ValueError('Source removal transformation changed')
    expected_recipe = derived_recipe(original_files[root + '/PKGBUILD'],
                                     digest(original_files[inner_name]),
                                     digest(derived_files[inner_name]))
    if derived_files[root + '/PKGBUILD.jms-derived'] != expected_recipe:
        raise ValueError('Derived build recipe changed outside reviewed acquisition')
    aliases = {}
    for name, descriptor in outer.items():
        if name in original_files and name != inner_name:
            aliases[(policy['archiveSha256'], name, descriptor['sha256'])] = (
                origin['sha256'], name, descriptor['sha256'])
    for name, descriptor in expected_inner.items():
        if descriptor['sha256'] is not None:
            member = inner_name + '/' + name
            aliases[(policy['archiveSha256'], member, descriptor['sha256'])] = (
                origin['sha256'], member, descriptor['sha256'])
    return aliases
