"""Stage the hash-pinned MSYS2 MPV dependency closure without changing source bundles."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct


def imports(path):
    data = path.read_bytes()
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    count = struct.unpack_from('<H', data, pe + 6)[0]
    optional_size = struct.unpack_from('<H', data, pe + 20)[0]
    optional = pe + 24
    if struct.unpack_from('<H', data, optional)[0] != 0x20b:
        raise ValueError('Expected x64 PE')
    table = optional + optional_size
    image_base = struct.unpack_from('<Q', data, optional + 24)[0]
    def offset(rva):
        for index in range(count):
            size, address, rawsize, raw = struct.unpack_from('<IIII', data, table + index * 40 + 8)
            if address <= rva < address + max(size, rawsize):
                return raw + rva - address
        raise ValueError('PE RVA outside sections')
    result = []
    for directory, stride, name_position in ((1, 20, 12), (13, 32, 4)):
        rva = struct.unpack_from('<I', data, optional + 112 + directory * 8)[0]
        if not rva:
            continue
        cursor = offset(rva)
        while any(data[cursor:cursor + stride]):
            name_rva = struct.unpack_from('<I', data, cursor + name_position)[0]
            if directory == 13 and not struct.unpack_from('<I', data, cursor)[0] & 1:
                name_rva -= image_base
            start = offset(name_rva)
            result.append(data[start:data.index(b'\0', start)].decode('ascii').lower())
            cursor += stride
    return result


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def stage(materials, destination, manifest):
    record = json.loads(manifest.read_text(encoding='utf-8'))
    names = {entry['dll'].lower() for entry in record['libraries']}
    system = Path(os.environ['WINDIR']) / 'System32'
    for entry in record['libraries']:
        binary = materials / 'bin' / entry['dll']
        if digest(binary) != entry['sha256'] or digest(materials / entry['package']) != entry['packageSha256']:
            raise ValueError('Pinned native binary/package checksum mismatch')
        for dependency in imports(binary):
            if dependency not in names and not dependency.startswith(('api-ms-', 'ext-ms-')) and not (system / dependency).is_file():
                raise ValueError('Unresolved native dependency: ' + dependency)
    for name, entry in record['sources'].items():
        source = materials / name
        if source.stat().st_size != entry['size'] or digest(source) != entry['sha256']:
            raise ValueError('Pinned corresponding source checksum mismatch')
    if not destination.is_dir():
        raise ValueError('Fresh application staging directory is required')
    for entry in record['libraries']:
        shutil.copyfile(materials / 'bin' / entry['dll'], destination / entry['dll'])
    shutil.copyfile(manifest, destination / 'JMS_NATIVE_MATERIALS.json')
    print('Verified native DLLs, normal/delay imports, packages and corresponding sources:', len(names))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--materials', required=True, type=Path)
    parser.add_argument('--destination', required=True, type=Path)
    parser.add_argument('--manifest', type=Path, default=Path('config/jms_windows_native.json'))
    args = parser.parse_args()
    stage(args.materials, args.destination, args.manifest)
