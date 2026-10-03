"""Validate Windows AOT bundles and preserve exact packaging corrections."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil


DEBUG_ARTIFACTS = (
    'data/flutter_assets/kernel_blob.bin',
    'data/flutter_assets/vm_snapshot_data',
    'data/flutter_assets/isolate_snapshot_data',
)


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def bundle_files(directory):
    directory = Path(directory).resolve(strict=True)
    if not directory.is_dir():
        raise ValueError('Windows bundle directory is missing')
    result = {}
    for path in directory.rglob('*'):
        if path.is_symlink():
            raise ValueError('Windows bundle contains a symbolic link')
        if path.is_file():
            if not path.resolve().is_relative_to(directory):
                raise ValueError('Windows bundle file escapes its directory')
            result[path.relative_to(directory).as_posix()] = digest(path)
    for name in ('jms.exe', 'flutter_windows.dll', 'data/app.so'):
        path = directory / name
        if name not in result or path.stat().st_size == 0:
            raise ValueError('Windows release bundle requires complete AOT inputs')
    return result


def validate_release_bundle(directory):
    files = bundle_files(directory)
    if any(name in files for name in DEBUG_ARTIFACTS):
        raise ValueError('Windows AOT release bundle contains debug-only Flutter artifacts')
    return files


def copy_without_verified_debug_kernel(source, destination, kernel_sha256):
    """Remove only a reviewed exact debug member; keep the failed source intact."""
    source = Path(source).resolve(strict=True)
    destination = Path(destination).resolve()
    if destination.exists() or destination == source or destination.is_relative_to(source):
        raise ValueError('A new distinct Windows packaging directory is required')
    if len(kernel_sha256) != 64 or any(char not in '0123456789abcdef' for char in kernel_sha256):
        raise ValueError('Exact reviewed debug-kernel SHA256 is required')
    files = bundle_files(source)
    kernel = DEBUG_ARTIFACTS[0]
    if files.get(kernel) != kernel_sha256:
        raise ValueError('Debug kernel differs from the reviewed packaging correction')
    if any(name in files for name in DEBUG_ARTIFACTS[1:]):
        raise ValueError('Additional unreviewed debug artifacts remain in the bundle')
    destination.mkdir(parents=True)
    for name in files:
        if name == kernel:
            continue
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / name, target)
    retained = validate_release_bundle(destination)
    expected = {name: value for name, value in files.items() if name != kernel}
    if retained != expected or bundle_files(source) != files:
        raise ValueError('Windows packaging correction changed retained or original files')
    return {'removedMember': kernel, 'removedSha256': kernel_sha256,
            'retainedFiles': retained, 'retainedFileCount': len(retained),
            'sourceFilesUnchanged': True, 'aotSha256': retained['data/app.so']}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--bundle', required=True)
    args = parser.parse_args()
    files = validate_release_bundle(args.bundle)
    print(json.dumps({'releaseAotBundle': True, 'files': len(files),
                      'debugOnlyArtifacts': 0, 'aotSha256': files['data/app.so']}))


if __name__ == '__main__':
    main()
