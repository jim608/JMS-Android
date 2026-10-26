"""Public CI metadata checks, executed on the host, never inside the runtime."""
import configparser
import hashlib
import json
import os
from pathlib import Path
import shlex
import sys

APP = 'com.jim608.jms'
ORIGIN = 'https://jim608.github.io/JMS-Linux/flatpak/repo/'


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def origin(name):
    assert name and name != 'flathub' and '\n' not in name
    config = configparser.ConfigParser(interpolation=None)
    config.read(Path(os.environ['XDG_DATA_HOME']) / 'flatpak/repo/config', encoding='utf-8')
    section = config[f'remote "{name}"']
    assert section['url'] == ORIGIN
    assert section.getboolean('gpg-verify')
    assert section.getboolean('gpg-verify-summary')
    print(json.dumps({'origin': name, 'url': ORIGIN, 'gpgVerify': True, 'gpgVerifySummary': True}))


def target(deployment):
    root = Path(deployment)
    receipt = json.loads((Path(os.environ['JMS_INPUT_DIR']) / 'target-verification.json').read_text())
    assert receipt['applicationId'] == APP and receipt['architecture'] == 'x86_64'
    assert receipt['branch'] == 'stable'
    assert receipt['ostreeCommit'] == os.environ['JMS_TARGET_COMMIT']
    expected = dict(receipt['members'])
    legacy_marker = 'files/.ref' in expected
    if legacy_marker:
        assert expected.pop('files/.ref') == hashlib.sha256(b'').hexdigest(), 'Unexpected legacy lock hash'
    files = [root / 'metadata'] + sorted((root / 'files').rglob('*'))
    actual = {}
    for path in files:
        name = path.relative_to(root).as_posix()
        if name == 'files/.ref':
            # Flatpak's deployment lock is not app payload. Never follow it.
            assert path.is_symlink() or (path.is_file() and path.stat().st_size == 0)
            continue
        if path.is_symlink():
            assert not path.readlink().is_absolute() and path.resolve().is_relative_to(root.resolve())
        elif path.is_file():
            actual[name] = sha(path)
    assert actual == expected, 'Installed members differ from exact CI target receipt'
    info = json.loads((root / 'files/share/jms/JMS_BUILD_INFO.json').read_text())
    fields = ('applicationId', 'platform', 'packageFormat', 'versionName', 'versionCode', 'sourceCommit', 'buildId')
    assert info == {key: receipt[key] for key in fields}
    print(json.dumps({'targetCommit': receipt['ostreeCommit'], 'sourceCommit': info['sourceCommit'],
                      'buildId': info['buildId'], 'installedMembersMatched': len(actual),
                      'legacyEmptyRefMarkerNormalized': legacy_marker}))


def launchers():
    directory = Path(os.environ['XDG_DATA_HOME']) / 'flatpak/exports/share/applications'
    for name, handheld in [(APP + '.desktop', False), (APP + '.SteamDeck.desktop', True)]:
        parser = configparser.ConfigParser(interpolation=None)
        parser.read(directory / name, encoding='utf-8')
        command = parser['Desktop Entry']['Exec']
        arguments = shlex.split(command)
        assert APP in arguments and 'run' in arguments
        assert arguments and Path(arguments[0]).name == 'flatpak'
        assert ('--handheld' in arguments) == handheld
    print(json.dumps({'oneAppId': APP, 'linuxAndDeckExportedLaunchers': True, 'launcherGuiExecuted': False}))


if __name__ == '__main__':
    if sys.argv[1] == 'origin':
        origin(sys.argv[2])
    elif sys.argv[1] == 'target':
        target(sys.argv[2])
    elif sys.argv[1] == 'launchers':
        launchers()
    else:
        raise SystemExit(2)
