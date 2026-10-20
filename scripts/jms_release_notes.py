import argparse
import ipaddress
import json
from pathlib import Path
import re
import tempfile
from urllib.parse import urlsplit


HEADINGS = ('新增', '調整', '修正', '移除', '已知問題', '更新注意事項')
ENGLISH_HEADINGS = ('Added', 'Changed', 'Fixed', 'Removed', 'Known issues', 'Update notes')
LANGUAGES = ('繁體中文 / Traditional Chinese', 'English')
FORBIDDEN = re.compile(
    r'我已完成|依照你的要求|接下來可以|本輪到此停止|不再輪詢|未操作手機|'
    r'\b(?:PASS|FAIL|BLOCKED|Codex|Goal|TODO|TBD)\b|待填|待補|'
    r'\b(?:I have completed|as you requested|test results?|local worktree|next I will)\b',
    re.IGNORECASE,
)
SENSITIVE = re.compile(
    r'(?<![A-Za-z])[A-Za-z]:[\\/]|https?://[^\s/@]+:[^\s/@]+@|'
    r'\b(?:Bearer\s+[A-Za-z0-9._-]+|Authorization\s*:\s*\S+|'
    r'ghp_[A-Za-z0-9]+|github_pat_[A-Za-z0-9_]+)\b',
    re.IGNORECASE,
)


def _validate_content(notes, version):
    lines = notes.strip().splitlines()
    if not lines or lines[0] != f'# JMS {version}':
        raise ValueError('Release notes title must match the actual candidate version')
    if FORBIDDEN.search(notes) or SENSITIVE.search(notes) or re.search(r'<[^>]+>', notes):
        raise ValueError('Release notes contain a placeholder, internal report or sensitive detail')
    for url in re.findall(r'https?://[^\s)]+', notes):
        host = urlsplit(url).hostname or ''
        if host == 'localhost' or host.endswith(('.localhost', '.local', '.internal')):
            raise ValueError('Release notes contain a private service address')
        try:
            address = ipaddress.ip_address(host)
        except ValueError:
            continue
        if not address.is_global:
            raise ValueError('Release notes contain a private service address')
    return lines


def _sections(lines, headings, prefix, punctuation):
    sections = {}
    current = None
    for line in lines:
        if not line.strip():
            continue
        if line.startswith(prefix):
            heading = line[len(prefix):]
            if heading not in headings or heading in sections or (
                    current is not None and headings.index(heading) < headings.index(current)):
                raise ValueError('Release notes section is unexpected, duplicated or out of order')
            if current is not None and sections[current] == 0:
                raise ValueError('Release notes contain an empty section')
            current = heading
            sections[current] = 0
        elif line.startswith('- ') and current is not None and line.rstrip().endswith(punctuation):
            sections[current] += 1
        else:
            raise ValueError('Release notes must contain complete bullet sentences under approved sections')
    if current is None or sections[current] == 0:
        raise ValueError('Release notes need at least one nonempty section')
    return sections


def validate_release_notes(notes, version, *, require_english=False):
    lines = _validate_content(notes, version)
    language_rows = [i for i, line in enumerate(lines) if line.startswith('## ') and line[3:] in LANGUAGES]
    if language_rows:
        if [lines[i][3:] for i in language_rows] != list(LANGUAGES) or language_rows[0] != 2:
            raise ValueError('Bilingual release notes require Chinese followed by English exactly once')
        split = language_rows[1]
        chinese = _sections(lines[3:split], HEADINGS, '### ', ('。', '！', '？'))
        english = _sections(lines[split + 1:], ENGLISH_HEADINGS, '### ', ('.', '!', '?'))
        expected = {ENGLISH_HEADINGS[HEADINGS.index(key)]: count for key, count in chinese.items()}
        if english != expected:
            raise ValueError('Chinese and English sections and bullet counts must align')
    else:
        if require_english:
            raise ValueError('This version requires matching English release notes')
        _sections(lines[1:], HEADINGS, '## ', ('。', '！', '？'))
    return notes.strip() + '\n'


def _version_block(path, version):
    text = Path(path).read_text(encoding='utf-8-sig')
    headings = list(re.finditer(r'^# JMS ([^\s]+)\s*$', text, re.MULTILINE))
    selected = [index for index, match in enumerate(headings) if match.group(1) == version]
    if len(selected) != 1:
        raise ValueError('Changelog must contain exactly one matching version')
    index = selected[0]
    end = headings[index + 1].start() if index + 1 < len(headings) else len(text)
    return text[headings[index].start():end].strip() + '\n'


def _version_key(version):
    match = re.fullmatch(r'(\d+)\.(\d+)\.(\d+)-jms\.(\d+)', version)
    if not match:
        raise ValueError('Bilingual policy requires a complete JMS version')
    return tuple(map(int, match.groups()))


def release_notes_for(changelog, version, *, english_changelog=None, require_english=False):
    changelog = Path(changelog)
    chinese = validate_release_notes(_version_block(changelog, version), version)
    policy_path = changelog.parent / 'config/jms_release_notes.json'
    if policy_path.is_file():
        policy = json.loads(policy_path.read_text(encoding='utf-8-sig'))
        if set(policy) != {'schemaVersion', 'englishRequiredFrom'} or policy['schemaVersion'] != 1:
            raise ValueError('Invalid bilingual release notes policy')
        required_for_version = _version_key(version) >= _version_key(policy['englishRequiredFrom'])
        require_english = require_english or required_for_version
    english_path = Path(english_changelog) if english_changelog is not None else changelog.with_name('CHANGELOG.en.md')
    if not require_english and english_changelog is None:
        return chinese
    if not english_path.is_file():
        raise ValueError('Matching English changelog is required')
    english = _version_block(english_path, version)
    lines = _validate_content(english, version)
    _sections(lines[1:], ENGLISH_HEADINGS, '## ', ('.', '!', '?'))
    combined = f'# JMS {version}\n\n## {LANGUAGES[0]}\n\n'
    combined += '\n'.join('### ' + line[3:] if line.startswith('## ') else line for line in chinese.splitlines()[1:]).strip()
    combined += f'\n\n## {LANGUAGES[1]}\n\n'
    combined += '\n'.join('### ' + line[3:] if line.startswith('## ') else line for line in lines[1:]).strip() + '\n'
    return validate_release_notes(combined, version, require_english=True)


def require_current_notes(changelog, notes_path, version, **options):
    expected = release_notes_for(changelog, version, **options)
    if Path(notes_path).read_text(encoding='utf-8-sig') != expected:
        raise ValueError('Current release notes differ from the matching changelog entry')
    return expected


def release_notes_from_archive(archive, version):
    """Validate the canonical notes against the candidate's complete source ZIP."""
    with tempfile.TemporaryDirectory(prefix='jms-canonical-notes-') as temporary:
        root = Path(temporary)
        names = archive.namelist()
        for name in ('CHANGELOG.md', 'CHANGELOG.en.md', 'config/jms_release_notes.json'):
            member = 'JMS/' + name
            if member not in names and name != 'CHANGELOG.md':
                continue
            if names.count(member) != 1:
                raise ValueError('Candidate source contains missing or duplicate canonical notes')
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(archive.read(member))
        return release_notes_for(root / 'CHANGELOG.md', version)


def release_body_for_candidate(notes, version, source_commit, build_id):
    canonical = validate_release_notes(notes, version)
    if not re.fullmatch(r'[a-f0-9]{40}', source_commit):
        raise ValueError('Release body requires the complete candidate source commit')
    if not re.fullmatch(re.escape('JMS-' + version + '-') + r'(?:[a-z]+-)?[a-f0-9]{12}', build_id):
        raise ValueError('Release body Build ID differs from the candidate version')
    return canonical.rstrip() + (
        f'\n\n來源：[jim608/JMS-Android](https://github.com/jim608/JMS-Android/tree/{source_commit})\n\n'
        f'來源提交：`{source_commit}`\n\n建置識別：`{build_id}`\n')


def main():
    parser = argparse.ArgumentParser(description='Render or verify one version of JMS release notes')
    parser.add_argument('--version', required=True)
    parser.add_argument('--changelog', type=Path, default=Path('CHANGELOG.md'))
    parser.add_argument('--english-changelog', type=Path)
    parser.add_argument('--require-english', action='store_true')
    parser.add_argument('--output', type=Path, default=Path('docs/JMS_RELEASE_NOTES.zh-Hant.md'))
    parser.add_argument('--write', action='store_true')
    args = parser.parse_args()
    options = {'english_changelog': args.english_changelog, 'require_english': args.require_english}
    notes = release_notes_for(args.changelog, args.version, **options)
    if args.write:
        args.output.write_text(notes, encoding='utf-8', newline='\n')
    else:
        require_current_notes(args.changelog, args.output, args.version, **options)
    print(f'JMS {args.version} release notes verified')


if __name__ == '__main__':
    main()
