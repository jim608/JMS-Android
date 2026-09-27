"""Check staged Git blobs, without printing matching private content."""

import argparse
import ipaddress
from pathlib import Path
import re
import subprocess
import sys


def git(*arguments):
    return subprocess.check_output(['git', *arguments])


def findings(name, data, domains):
    problems = []
    path = Path(name)
    if (path.suffix.lower() in {'.jks', '.keystore', '.p12', '.pfx', '.pem'}
            or path.name in {'.env', 'key.properties', 'id_rsa', 'id_ed25519'}):
        problems.append('private file type')
    if b'\x00' in data:
        return problems
    text = data.decode('utf-8', errors='replace')
    for domain in domains:
        if re.search(r'(?<![a-z0-9-])' + re.escape(domain) + r'(?![a-z0-9.-])', text, re.I):
            problems.append('private domain')
            break
    if re.search(r'\b[A-Za-z]:[\\/](?:Users|home)[\\/][^\s\\/]+', text, re.I):
        problems.append('personal filesystem path')
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tree', help='Check an existing source snapshot instead of the index')
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
            print(f'{name}: {", ".join(problems)}', file=sys.stderr)
    print(f'Privacy check: {checked} files checked; {failures} rejected.')
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
