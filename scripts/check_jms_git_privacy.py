"""Check staged Git blobs, without printing matching private content."""

import argparse
import ipaddress
from pathlib import Path
import re
import subprocess
import sys
import io
import zipfile
import tarfile


def git(*arguments):
    return subprocess.check_output(['git', *arguments], stderr=subprocess.PIPE)


def tree_entries(tree):
    result = {}
    for entry in git('ls-tree', '-r', '-z', tree).split(b'\0'):
        if entry:
            meta, name = entry.split(b'\t', 1)
            mode, kind, oid = meta.decode().split()
            result[name.decode()] = (kind, oid)
    return result


def blob_findings(entries, domains):
    blobs = [(name, oid) for name, (kind, oid) in entries.items() if kind == 'blob']
    if not blobs:
        return []
    output = subprocess.run(['git', 'cat-file', '--batch'],
                            input=('\n'.join(oid for _, oid in blobs) + '\n').encode(),
                            capture_output=True, check=True).stdout
    stream = io.BytesIO(output)
    result = []
    for name, oid in blobs:
        header = stream.readline().split()
        if len(header) != 3 or header[0].decode() != oid or header[1] != b'blob':
            raise ValueError('Git blob verification failed')
        data = stream.read(int(header[2]))
        stream.read(1)
        result.append((name, findings(name, data, domains)))
    return result


def findings(name, data, domains):
    problems = []
    path = Path(name)
    if (path.suffix.lower() in {'.jks', '.keystore', '.p12', '.pfx', '.pem', '.key'}
            or path.name.startswith('.env.')
            or path.name in {'.env', 'key.properties', 'id_rsa', 'id_ed25519'}):
        problems.append('private file type')
    text = name + '\n' + data.replace(b'\x00', b'').decode('utf-8', errors='replace')
    for domain in domains:
        if re.search(r'(?<![a-z0-9-])' + re.escape(domain) + r'(?![a-z0-9.-])', text, re.I):
            problems.append('private domain')
            break
    if re.search(r'\b[A-Za-z]:[\\/](?:Users|home)[\\/][^\s\\/]+', text, re.I):
        problems.append('personal filesystem path')
    if re.search(r'/home/[A-Za-z0-9_.-]+/|/Users/[A-Za-z0-9_.-]+/(?:Documents|Desktop|Library|Downloads|\.ssh|\.config)/', text):
        problems.append('personal filesystem path')
    if re.search(r'https?://[^\s/:]+:[^\s/@]+@|\bBearer\s+[A-Za-z0-9_.-]{16,}', text, re.I):
        problems.append('credential URL/header')
    assignments = re.findall(r'''(?i)(?<![A-Za-z0-9_])["']?(?:password|passwd|api[_-]?key|access[_-]?token|refresh[_-]?token|sessionCookie|cookie|set-cookie)["']?\s*[:=]\s*["']([A-Za-z0-9_./+=:;-]{16,})["']''', text)
    for value in assignments:
        # Explicitly synthetic credentials are permitted in public tests, never private policy matches.
        if not re.fullmatch(r'(?:connect\.sid=)?(?:fixture[-_][A-Za-z0-9_-]+|[A-Z_]*(?:ONLY|LEGACY))', value):
            problems.append('credential assignment')
            break
    if re.search(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|\bgh[pousr]_[A-Za-z0-9]{30,}\b|\bgithub_pat_[A-Za-z0-9_]{40,}\b', text):
        problems.append('credential pattern')
    for address in re.findall(r'https?://(\d{1,3}(?:\.\d{1,3}){3})(?=[:/\s]|$)', text):
        try:
            parsed = ipaddress.ip_address(address)
        except ValueError:
            continue
        if any(parsed in subnet for subnet in (
                ipaddress.ip_network('10.0.0.0/8'),
                ipaddress.ip_network('172.16.0.0/12'),
                ipaddress.ip_network('192.168.0.0/16'))):
            problems.append('private network endpoint')
            break
    return problems


def load_policy():
    policy = Path(git('rev-parse', '--git-path', 'jms-private-domains').decode().strip())
    values = [line.strip().lower() for line in policy.read_text(encoding='utf-8').splitlines()
              if line.strip() and not line.lstrip().startswith('#')]
    if not values:
        raise ValueError('Local privacy policy is empty')
    return values


def scan_archive(name, data, domains, depth=0):
    results = [(name, findings(name, data, domains))]
    if name.lower().endswith(('.zip', '.apk', '.jar', '.aar')):
        if depth >= 6:
            raise ValueError('Archive nesting limit exceeded')
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            for member in archive.infolist():
                if not member.is_dir():
                    results.extend(scan_archive(name + '/' + member.filename, archive.read(member), domains, depth + 1))
    elif name.lower().endswith(('.tar.gz', '.tgz', '.tar.xz', '.tar', '.tar.bz2')):
        if depth >= 6:
            raise ValueError('Archive nesting limit exceeded')
        with tarfile.open(fileobj=io.BytesIO(data), mode='r:*') as archive:
            for member in archive:
                if member.isfile():
                    results.extend(scan_archive(name + '/' + member.name, archive.extractfile(member).read(), domains, depth + 1))
    return results


def outgoing_findings(head, bases, domains):
    commits = git('rev-list', head, '--not', *bases).decode().splitlines()
    results = []
    for commit in commits:
        metadata = git('show', '-s', '--format=%B', commit)
        results.append((commit + '/message', findings('message', metadata, domains)))
        emails = git('show', '-s', '--format=%ae%n%ce', commit).decode().splitlines()
        if any(not re.fullmatch(r'[A-Za-z0-9+_.-]+@users\.noreply\.github\.com', value) for value in emails):
            results.append((commit + '/identity', ['non-noreply identity']))
        # Every newly introduced version, including secrets removed in a later commit.
        names = git('diff-tree', '--root', '-m', '--no-commit-id', '--name-only', '-r', '-z', '--diff-filter=ACMR', commit).split(b'\0')
        entries = tree_entries(commit)
        changed = {raw.decode() for raw in names if raw}
        results.extend((commit + '/' + name, problems) for name, problems in
                       blob_findings({name: value for name, value in entries.items() if name in changed}, domains))
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tree', help='Check an existing source snapshot instead of the index')
    parser.add_argument('--outgoing')
    parser.add_argument('--base', action='append', default=[])
    parser.add_argument('--package', action='append', default=[])
    parser.add_argument('--message-file')
    arguments = parser.parse_args()
    policy = Path(git('rev-parse', '--git-path', 'jms-private-domains').decode().strip())
    if not policy.is_file():
        print('Privacy policy missing: configure the local Git jms-private-domains file.', file=sys.stderr)
        return 1
    domains = [line.strip().lower() for line in policy.read_text(encoding='utf-8').splitlines()
               if line.strip() and not line.lstrip().startswith('#')]
    if not domains:
        print('Privacy domain policy is empty; review local deployment domains first.', file=sys.stderr)
        return 1
    if arguments.outgoing or arguments.package or arguments.message_file:
        results = []
        if arguments.outgoing:
            results.extend(outgoing_findings(arguments.outgoing, arguments.base, domains))
        for filename in arguments.package:
            path = Path(filename)
            results.extend(scan_archive(path.name, path.read_bytes(), domains))
        if arguments.message_file:
            results.append(('commit message', findings('message', Path(arguments.message_file).read_bytes(), domains)))
            emails = git('var', 'GIT_AUTHOR_IDENT') + git('var', 'GIT_COMMITTER_IDENT')
            if any(not re.fullmatch(r'[A-Za-z0-9+_.-]+@users\.noreply\.github\.com', value)
                   for value in re.findall(r'<([^>]+)>', emails.decode())):
                results.append(('commit identity', ['non-noreply identity']))
        rejected = [(name, problems) for name, problems in results if problems]
        for name, problems in rejected:
            # Paths themselves can contain a private value.
            safe = name if not findings('name', name.encode(), domains) else '[redacted location]'
            print(f'{safe}: {", ".join(problems)}', file=sys.stderr)
        print(f'Privacy check: {len(results)} items checked; {len(rejected)} rejected.')
        return int(bool(rejected))
    if arguments.tree:
        tree = git('rev-parse', '--verify', arguments.tree + '^{tree}').decode().strip()
        entries = tree_entries(tree)
        results = blob_findings(entries, domains)
        failures = 0
        for name, problems in results:
            if problems:
                failures += 1
                safe = name if not findings('name', name.encode(), domains) else '[redacted location]'
                print(f'{safe}: {", ".join(problems)}', file=sys.stderr)
        external = sum(kind == 'commit' for kind, _ in entries.values())
        print(f'Privacy check: {len(results)} blobs checked; {failures} rejected; {external} external gitlinks not expanded.')
        return int(bool(failures))
    else:
        if git('branch', '--show-current').decode().strip() != 'jms':
            print('New JMS commits must be made on the jms branch.', file=sys.stderr)
            return 1
        tree = ''
        names = git('diff', '--cached', '--name-only', '--diff-filter=ACMR', '-z').split(b'\0')
    failures = 0
    checked = 0
    for raw_name in names:
        if not raw_name:
            continue
        name = raw_name.decode('utf-8')
        if git('ls-files', '--stage', '--', name).startswith(b'160000 '):
            continue  # Only the external commit pointer is stored in this repository.
        data = git('show', f'{tree}:{name}')
        problems = findings(name, data, domains)
        checked += 1
        if problems:
            failures += 1
            safe = name if not findings('name', name.encode(), domains) else '[redacted location]'
            print(f'{safe}: {", ".join(problems)}', file=sys.stderr)
    print(f'Privacy check: {checked} files checked; {failures} rejected.')
    return 1 if failures else 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.CalledProcessError, zipfile.BadZipFile):
        print('Privacy check could not complete; inspect local policy, Git objects or archive integrity.', file=sys.stderr)
        sys.exit(1)
