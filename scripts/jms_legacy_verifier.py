"""Run the installed Android .8 checker without modifying its source bytes."""
import hashlib
import json
from pathlib import Path
from urllib.parse import urljoin
import zipfile


def prepare_legacy_verifier(root, baseline):
    root = Path(root).resolve()
    directory = root / 'artifacts/publication/legacy-checker'
    source = root / 'artifacts/releases' / baseline['buildId'] / 'JMS-0.11.1-jms.8-source.zip'
    expected = {entry['path']: entry['sha256'] for entry in baseline['inputs']}
    names = ['lib/util/update_checker.dart', 'lib/util/update_source.dart', 'lib/util/brand.dart']
    with zipfile.ZipFile(source) as archive:
        for name in names:
            content = archive.read('JMS/' + name)
            if hashlib.sha256(content).hexdigest() != expected.get(name):
                raise ValueError('Frozen .8 source does not match installed baseline: ' + name)
            output = directory / name
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_bytes(content)
    current = root / '.dart_tool/package_config.json'
    config = json.loads(current.read_text(encoding='utf-8'))
    for package in config['packages']:
        package['rootUri'] = (directory.as_uri() + '/' if package['name'] == 'fladder'
                              else urljoin(current.as_uri(), package['rootUri']))
    target = directory / 'package_config.json'
    target.write_text(json.dumps(config), encoding='utf-8')
    return target
