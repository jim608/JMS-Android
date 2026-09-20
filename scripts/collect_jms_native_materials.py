import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import time
import urllib.parse
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
MAX_BYTES = 192 * 1024 * 1024


def digest(path):
    checksum = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            checksum.update(chunk)
    return checksum.hexdigest()


class HttpsRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, url):
        if urllib.parse.urlsplit(url).scheme != 'https':
            raise ValueError('Non-HTTPS material redirect rejected')
        return super().redirect_request(request, response, code, message, headers, url)


def collect(record, directory, previous):
    name = record['file']
    if Path(name).name != name or '/' in name or '\\' in name or name in ('.', '..'):
        raise ValueError('Unsafe material filename')
    url = record['url']
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != 'https' or parsed.username or parsed.password:
        raise ValueError('Material URL must be public HTTPS')
    destination = directory / name
    if destination.exists():
        if not previous or previous.get('url') != url or digest(destination) != previous.get('sha256'):
            raise ValueError('Existing material is not bound to its manifest')
        return dict(previous)
    pending = destination.with_suffix(destination.suffix + '.part')
    try:
        request = urllib.request.Request(url, headers={'User-Agent': 'JMS-corresponding-source-audit'})
        opener = urllib.request.build_opener(HttpsRedirect())
        started = time.monotonic()
        with opener.open(request, timeout=45) as response, pending.open('wb') as output:
            total = 0
            while chunk := response.read(1024 * 1024):
                total += len(chunk)
                if total > MAX_BYTES or time.monotonic() - started > 300:
                    raise ValueError('Material download exceeds size/time limit')
                output.write(chunk)
        if record.get('encoding') == 'base64':
            pending.write_bytes(base64.b64decode(pending.read_bytes(), validate=True))
        if name.endswith('.zip'):
            with zipfile.ZipFile(pending) as archive:
                if not archive.namelist():
                    raise ValueError('Empty source archive')
        pending.replace(destination)
    finally:
        pending.unlink(missing_ok=True)
    return dict(record, bytes=destination.stat().st_size, sha256=digest(destination), status='ACQUIRED')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--plan', default='config/jms_native_materials.json')
    args = parser.parse_args()
    plan = json.loads((ROOT / args.plan).read_text(encoding='utf-8'))
    directory = ROOT / 'artifacts/native-materials-m13'
    directory.mkdir(parents=True, exist_ok=True)
    manifest_path = directory / 'manifest.json'
    previous = json.loads(manifest_path.read_text(encoding='utf-8')) if manifest_path.exists() else []
    index = {record['file']: record for record in previous}
    results = []
    for record in plan:
        try:
            result = collect(record, directory, index.get(record['file']))
        except Exception as error:
            result = dict(record, status='MISSING', error=type(error).__name__)
        results.append(result)
        temporary = manifest_path.with_suffix('.pending')
        temporary.write_text(json.dumps(results + [item for item in previous if item['file'] not in {entry['file'] for entry in results}], indent=2), encoding='utf-8')
        temporary.replace(manifest_path)
        print(record['file'], result['status'], result.get('bytes', result.get('error')), flush=True)
    raise SystemExit(1 if any(record['status'] != 'ACQUIRED' for record in results) else 0)


if __name__ == '__main__':
    main()
