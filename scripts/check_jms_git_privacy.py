"""Check staged Git blobs, without printing matching private content."""

import argparse
import ipaddress
from pathlib import Path
import re
import subprocess
import sys
import io
import zipfile


def git(*arguments):
    return subprocess.check_output(['git', *arguments])


def findings(name, data, domains):
    problems = []
    path = Path(name)
    if (path.suffix.lower() in {'.jks', '.keystore', '.p12', '.pfx', '.pem'}
            or path.name in {'.env', 'key.properties', 'id_rsa', 'id_ed25519'}):
        problems.append('private file type')
    text = data.replace(b'\x00', b'').decode('utf-8', errors='replace')
    for domain in domains:
        if re.search(r'(?<![a-z0-9-])' + re.escape(domain) + r'(?![a-z0-9.-])', text, re.I):
            problems.append('private domain')
            break
    if re.search(r'\b[A-Za-z]:[\\/](?:Users|home)[\\/][^\s\\/]+', text, re.I):
        problems.append('personal filesystem path')
    if re.search(r'/(?:Users|home)/[A-Za-z0-9_.-]+/', text):
        problems.append('personal filesystem path')
    if re.search(r'https?://[^\s/:]+:[^\s/@]+@|\bBearer\s+[A-Za-z0-9_.-]{16,}', text, re.I):
        problems.append('credential URL/header')
    if re.search(r'''(?i)["']?(?:password|passwd|api[_-]?key|access[_-]?token|refresh[_-]?token|cookie|set-cookie)["']?\s*[:=]\s*["'][^"'\r\n]{16,}["']''', text):
        problems.append('credential assignment')
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
        for raw in set(names) - {b''}:
            name = raw.decode()
            results.append((commit + '/' + name, findings(name, git('show', commit + ':' + name), domains)))
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
        names = git('ls-tree', '-r', '--name-only', '-z', tree).split(b'\0')
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
    sys.exit(main())
