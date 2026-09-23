import argparse
from pathlib import Path
import re

from jms_publication import Github, REPOSITORY, ReleaseError
from jms_release_notes import release_notes_for


ROOT = Path(__file__).resolve().parents[1]


def correct_description(github, version, notes, apply):
    tag = 'v' + version
    release = github.api(f'repos/{REPOSITORY}/releases/tags/{tag}')
    if release.get('tag_name') != tag or release.get('draft') or not release.get('prerelease'):
        raise ReleaseError('Expected an existing public JMS prerelease with the exact tag')
    assets = {(asset['id'], asset['name'], asset['size'], asset.get('digest')) for asset in release['assets']}
    expected_assets = {'update.json', f'JMS-Android-{version}-release-arm64-test-signed.apk'}
    if not expected_assets.issubset({asset[1] for asset in assets}):
        raise ReleaseError('Existing release is missing its immutable update assets')
    title = 'JMS ' + version
    if release.get('name') == title and release.get('body') == notes:
        return release['html_url'], False
    if not apply:
        return release['html_url'], True
    updated = github.api(f'repos/{REPOSITORY}/releases/{release["id"]}', 'PATCH', {'name': title, 'body': notes})
    updated_assets = {(asset['id'], asset['name'], asset['size'], asset.get('digest')) for asset in updated['assets']}
    if (updated.get('tag_name'), updated.get('prerelease'), updated_assets) != (tag, True, assets):
        raise ReleaseError('Release identity or assets changed unexpectedly')
    if updated.get('name') != title or updated.get('body') != notes:
        raise ReleaseError('Release description was not saved')
    return updated['html_url'], True


def main():
    parser = argparse.ArgumentParser(description='Correct title/body only; never mutate a released tag or asset')
    parser.add_argument('--version', required=True)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    if not re.fullmatch(r'[0-9A-Za-z][0-9A-Za-z._+-]*', args.version):
        raise ValueError('Unsafe release version')
    notes = release_notes_for(ROOT / 'CHANGELOG.md', args.version)
    github = Github()
    github.authenticate()
    url, changed = correct_description(github, args.version, notes, args.apply)
    print(f'{url}\nDescription {"updated" if changed and args.apply else "needs update" if changed else "already current"}')


if __name__ == '__main__':
    main()
