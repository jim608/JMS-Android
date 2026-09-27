import json
import pathlib
import re
import subprocess

root = pathlib.Path(__file__).resolve().parents[1]
paths = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard'], cwd=root, text=True).splitlines()
records = []
for name in paths:
    path = root / name
    if not path.is_file():
        continue
    if path.suffix not in {'.dart', '.arb', '.xml', '.json', '.yaml', '.yml', '.plist', '.rc', '.cpp', '.cc', '.gradle', '.md', '.html', '.iss', '.desktop', '.txt', '.swift', '.pbxproj', '.kt', '.sh'}:
        continue
    if any(part in name for part in ('.g.dart', '.freezed.dart', '.mapper.dart', '.gr.dart', '.swagger.dart', '.g.kt')):
        continue
    try:
        lines = path.read_text(encoding='utf-8').splitlines()
    except UnicodeError:
        continue
    for number, line in enumerate(lines, 1):
        if path.suffix == '.dart':
            if line.startswith(('import ', 'export ', 'part ')):
                continue
            matches = [value for value in re.findall(r'''["']([^"'\n]*)["']''', line) if re.search('fladder|tjilp|donutware', value, re.I)]
        elif path.suffix == '.arb':
            matches = [line] if re.search(r':\s*"[^\n]*(fladder|tjilp|donutware)', line, re.I) else []
        else:
            matches = [line.strip()] if re.search('fladder|tjilp|donutware', line, re.I) else []
        if matches:
            records.append({'path': name, 'line': number, 'values': matches})
destination = root / 'artifacts' / 'brand-inventory.json'
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text(json.dumps(records, ensure_ascii=False, indent=2), encoding='utf-8')
print(f'{len(records)} occurrence lines -> {destination}')
for record in records:
    if record['path'].startswith('lib/') and not record['path'].endswith('.arb'):
        print(f"{record['path']}:{record['line']}: {record['values']}")
