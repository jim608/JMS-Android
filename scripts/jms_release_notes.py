import argparse
from pathlib import Path
import re


HEADINGS = ('新增', '調整', '修正', '移除', '已知問題', '更新注意事項')
FORBIDDEN = re.compile(
    r'我已完成|依照你的要求|接下來可以|本輪到此停止|不再輪詢|未操作手機|'
    r'\b(?:PASS|FAIL|BLOCKED|Codex|Goal|TODO|TBD)\b|待填|待補',
    re.IGNORECASE,
)
SENSITIVE = re.compile(
    r'(?<![A-Za-z])[A-Za-z]:[\\/]|https?://[^\s/@]+:[^\s/@]+@|'
    r'\b(?:Bearer\s+[A-Za-z0-9._-]+|Authorization\s*:\s*\S+|'
    r'ghp_[A-Za-z0-9]+|github_pat_[A-Za-z0-9_]+)\b',
    re.IGNORECASE,
)


def validate_release_notes(notes, version):
    lines = notes.strip().splitlines()
    if not lines or lines[0] != f'# JMS {version}':
        raise ValueError('Release notes title must match the actual APK version')
    if FORBIDDEN.search(notes) or SENSITIVE.search(notes) or re.search(r'<[^>]+>', notes):
        raise ValueError('Release notes contain a placeholder, internal report or sensitive detail')
    sections = []
    entries = 0
    for line in lines[1:]:
        if not line.strip():
            continue
        if line.startswith('## '):
            heading = line[3:]
            if heading not in HEADINGS or heading in sections or (sections and HEADINGS.index(heading) < HEADINGS.index(sections[-1])):
                raise ValueError('Release notes section is unexpected, duplicated or out of order')
            if sections and entries == 0:
                raise ValueError('Release notes contain an empty section')
            sections.append(heading)
            entries = 0
        elif line.startswith('- ') and sections and line.rstrip().endswith(('。', '！', '？')):
            entries += 1
        else:
            raise ValueError('Release notes must contain complete bullet sentences under approved sections')
    if not sections or entries == 0:
        raise ValueError('Release notes need at least one nonempty section')
    return notes.strip() + '\n'


def release_notes_for(changelog, version):
    text = Path(changelog).read_text(encoding='utf-8-sig')
    headings = list(re.finditer(r'^# JMS ([^\s]+)\s*$', text, re.MULTILINE))
    selected = [index for index, match in enumerate(headings) if match.group(1) == version]
    if len(selected) != 1:
        raise ValueError('Changelog must contain exactly one matching version')
    index = selected[0]
    start = headings[index].start()
    end = headings[index + 1].start() if index + 1 < len(headings) else len(text)
    return validate_release_notes(text[start:end], version)


def require_current_notes(changelog, notes_path, version):
    expected = release_notes_for(changelog, version)
    if Path(notes_path).read_text(encoding='utf-8-sig') != expected:
        raise ValueError('Current release notes differ from the matching changelog entry')
    return expected


def main():
    parser = argparse.ArgumentParser(description='Render or verify one JMS release note from CHANGELOG.md')
    parser.add_argument('--version', required=True)
    parser.add_argument('--changelog', type=Path, default=Path('CHANGELOG.md'))
    parser.add_argument('--output', type=Path, default=Path('docs/JMS_RELEASE_NOTES.zh-Hant.md'))
    parser.add_argument('--write', action='store_true')
    args = parser.parse_args()
    notes = release_notes_for(args.changelog, args.version)
    if args.write:
        args.output.write_text(notes, encoding='utf-8')
    else:
        require_current_notes(args.changelog, args.output, args.version)
    print(f'JMS {args.version} release notes verified')


if __name__ == '__main__':
    main()
