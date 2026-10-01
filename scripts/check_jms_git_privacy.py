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
import hashlib
import json
import time
import struct


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
        result.append((name, git_blob_findings(name, data, domains)))
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


def load_public_reviews():
    registry = Path(__file__).resolve().parents[1] / 'config/jms_public_privacy_reviews.json'
    return json.loads(registry.read_text(encoding='utf-8')) if registry.is_file() else []


def matching_reviews(data, contexts, reviews):
    digest = hashlib.sha256(data).hexdigest()
    return [review for review in reviews
            if review.get('sha256') == digest
            and ((review.get('archiveSha256'), review.get('member')) in contexts
                 or any((item.get('archiveSha256'), item.get('member')) in contexts
                        for item in review.get('distributions', [])))
            and review.get('source', '').startswith('https://')
            and review.get('explanation') and valid_evidence(review)]


def valid_evidence(review):
    evidence = review.get('evidence')
    if not isinstance(evidence, dict):
        return False
    if not all(isinstance(evidence.get(field), str) and evidence[field]
               for field in ('kind', 'member', 'sha256')):
        return False
    if not re.fullmatch(r'[0-9a-f]{64}', evidence['sha256']):
        return False
    for item in review.get('additionalEvidence', []):
        if (not isinstance(item, dict) or not item.get('member')
                or not re.fullmatch(r'[0-9a-f]{64}', item.get('sha256', ''))):
            return False
    if review.get('inspection') == 'raw-public-test-sample':
        return (evidence['kind'] == 'upstream-test-reference'
                and evidence['member'] != review.get('member')
                and isinstance(review.get('testReference'), str)
                and bool(review.get('testReference'))
                and isinstance(review.get('rawContentReview'), dict)
                and review['rawContentReview'].get('scope') == 'raw-bytes-only'
                and bool(review['rawContentReview'].get('method'))
                and bool(review['rawContentReview'].get('conclusion')))
    return True


def verified_registry_member(review, project=None):
    """Verify a relative review path against locally pinned official materials.

    This inspects only the selected origin/reference bytes. Complete release
    container inspection remains the responsibility of ArchiveScan.
    """
    project = Path(project or Path(__file__).resolve().parents[1])
    allowed = {'source', 'archiveSha256', 'member', 'sha256', 'rules',
               'explanation', 'testReference', 'evidence', 'additionalEvidence'}
    if (set(review) - allowed or not valid_evidence(review)
            or review.get('rules') != ['personal filesystem path']
            or not isinstance(review.get('explanation'), str) or not review['explanation']):
        return False
    source = review.get('source', '')
    prefixes = ('https://repo.msys2.org/mingw/sources/',
                'https://mirror.msys2.org/mingw/sources/')
    prefix = next((value for value in prefixes if source.startswith(value)), None)
    if prefix is None:
        return False
    filename = source[len(prefix):]
    if not filename or '/' in filename or '\\' in filename or ':' in filename:
        return False
    targets = {}
    for item in [review, review['evidence']] + review.get('additionalEvidence', []):
        member = item.get('member', '')
        digest = item.get('sha256', '')
        if (not isinstance(member, str) or member.startswith('/') or '\\' in member
                or ':' in member or any(part in ('', '.', '..') for part in member.split('/'))
                or not re.fullmatch(r'[0-9a-f]{64}', digest)
                or item.get('archiveSha256', review.get('archiveSha256')) != review.get('archiveSha256')):
            return False
        if member in targets and targets[member] != digest:
            return False
        targets[member] = digest
    try:
        manifest = json.loads((project / 'config/jms_windows_native.json').read_text(encoding='utf-8'))
        binding = manifest['sources'][filename]
        if binding['sha256'] != review['archiveSha256']:
            return False
        locations = (project / 'artifacts/checks/windows-release-closeout/native-ready',
                     project / 'artifacts/checks/m32/msys')
        material = next((folder / filename for folder in locations
                         if (folder / filename).is_file()), None)
        if material is None or material.stat().st_size != binding['size']:
            return False
        with material.open('rb') as payload:
            if hashlib.file_digest(payload, 'sha256').hexdigest() != binding['sha256']:
                return False
        if material.stat().st_size > MAX_ARCHIVE_MEMBER_BYTES:
            return False
        budget = {'bytes': 0, 'members': 0}
        started = time.monotonic()

        def inspect(name, data, parent='', depth=0):
            if depth > 6 or time.monotonic() - started > 60:
                raise ValueError('Registry evidence inspection limit')
            raw = io.BytesIO(data)
            if name.endswith('.zip'):
                archive = zipfile.ZipFile(raw)
                members = ((entry.filename, entry.file_size, not entry.is_dir(),
                            lambda entry=entry: archive.open(entry)) for entry in archive.infolist())
            else:
                if name.endswith('.zst'):
                    import zstandard
                    raw = zstandard.ZstdDecompressor().stream_reader(raw)
                archive = tarfile.open(fileobj=raw, mode='r|*')
                members = ((entry.name.removeprefix('./'), entry.size, entry.isfile(),
                            lambda entry=entry: archive.extractfile(entry)) for entry in archive)
            with raw, archive:
                for member, size, regular, opener in members:
                    budget['members'] += 1
                    if budget['members'] > 200000 or time.monotonic() - started > 60:
                        raise ValueError('Registry evidence inspection limit')
                    full = parent + member
                    if not regular or not any(target == full or target.startswith(full + '/') for target in targets):
                        continue
                    budget['bytes'] += size
                    if size > MAX_ARCHIVE_MEMBER_BYTES or budget['bytes'] > 1024**3:
                        raise ValueError('Registry evidence inspection limit')
                    with opener() as payload:
                        value = payload.read(size + 1)
                    if len(value) != size:
                        raise ValueError('Incomplete registry evidence member')
                    if full in targets:
                        if hashlib.sha256(value).hexdigest() != targets.pop(full):
                            raise ValueError('Registry evidence member mismatch')
                    elif any(target.startswith(full + '/') for target in targets):
                        inspect(member, value, full + '/', depth + 1)
                    if not targets:
                        return

        inspect(filename, material.read_bytes())
        return not targets
    except (OSError, ValueError, KeyError, TypeError, zipfile.BadZipFile, tarfile.TarError):
        return False


def git_blob_findings(name, data, domains, project=None):
    """Recognize only proven public relative member fields in the review file."""
    original = findings(name, data, domains)
    if name != 'config/jms_public_privacy_reviews.json' or 'personal filesystem path' not in original:
        return original
    try:
        reviews = json.loads(data)
        if not isinstance(reviews, list):
            return original
        for review in reviews:
            if not isinstance(review, dict):
                return original
            member = review.get('member', '')
            if ('personal filesystem path' in findings('member', str(member).encode(), domains)
                    and verified_registry_member(review, project)):
                review['member'] = '[verified public relative archive member]'
        checked = findings(name, json.dumps(reviews, ensure_ascii=False).encode(), domains)

        def inspect_fields(value, depth=0):
            if depth > 20:
                raise ValueError('Registry metadata nesting limit')
            if isinstance(value, str):
                for reason in findings('registry string', value.encode(), domains):
                    if reason not in checked:
                        checked.append(reason)
            elif isinstance(value, list):
                for entry in value:
                    inspect_fields(entry, depth + 1)
            elif isinstance(value, dict):
                for key, entry in value.items():
                    inspect_fields(key, depth + 1)
                    inspect_fields(entry, depth + 1)
                    if isinstance(entry, str):
                        for reason in findings('registry assignment', (key + '=\"' + entry + '\"').encode(), domains):
                            if reason not in checked:
                                checked.append(reason)

        inspect_fields(reviews)
        # Private policy is checked against the original bytes, including fields
        # whose public relative archive path has been verified above.
        for problem in original:
            if problem != 'personal filesystem path' and problem not in checked:
                checked.append(problem)
        return checked
    except (ValueError, TypeError):
        return original


def reviewed_archive_findings(name, data, domains, contexts=(), reviews=None):
    problems = findings(name, data, domains)
    for review in matching_reviews(data, contexts, load_public_reviews() if reviews is None else reviews):
        permitted = review.get('rules', [review.get('reason')])
        # The local private policy always wins, including for byte-identical public fixtures.
        problems = [reason for reason in problems
                    if reason == 'private domain' or reason not in permitted]
    return problems


MAX_ARCHIVE_MEMBER_BYTES = 512 * 1024 * 1024


class ArchiveScan:
    def __init__(self, domains, reviews=None, *, max_bytes=4 * 1024**3,
                 max_members=200000, max_seconds=1800, max_depth=6):
        import time
        self.domains = domains
        self.reviews = load_public_reviews() if reviews is None else reviews
        self.max_bytes = max_bytes
        self.max_members = max_members
        self.max_seconds = max_seconds
        self.max_depth = max_depth
        self.started = time.monotonic()
        self.expanded = 0
        self.members = 0
        self.raw_samples = []
        self.seen = set()
        self.used_reviews = []
        self.stream_bytes = 0
        self.current_member = None
        self.expected_evidence = set()
        for review in self.reviews:
            for evidence in [review.get('evidence', {})] + review.get('additionalEvidence', []):
                if isinstance(evidence, dict):
                    self.expected_evidence.add((evidence.get('archiveSha256', review.get('archiveSha256')),
                                               evidence.get('member'), evidence.get('sha256')))
            self.expected_evidence.add((review.get('archiveSha256'), review.get('member'), review.get('sha256')))

    def finish(self):
        for review in self.used_reviews:
            origin = (review['archiveSha256'], review['member'], review['sha256'])
            if origin not in self.seen:
                raise ValueError('Public review origin was not verified in inspected materials')
            for evidence in [review['evidence']] + review.get('additionalEvidence', []):
                identity = (evidence.get('archiveSha256', review['archiveSha256']),
                            evidence['member'], evidence['sha256'])
                if identity not in self.seen:
                    raise ValueError('Public review reference was not verified in inspected materials')

    def bounded_stream(self, stream):
        owner = self

        class Reader(io.RawIOBase):
            def readable(self):
                return True

            def read(self, size=-1):
                owner.check_budget()
                remaining = owner.max_bytes - owner.stream_bytes
                if size < 0:
                    size = min(remaining + 1, 1024 * 1024)
                content = stream.read(min(size, remaining + 1))
                owner.stream_bytes += len(content)
                if owner.stream_bytes > owner.max_bytes:
                    raise ValueError('Archive decompression limit exceeded')
                owner.check_budget()
                return content

        return Reader()

    def check_budget(self, size=0):
        import time
        if size > MAX_ARCHIVE_MEMBER_BYTES:
            raise ValueError('Archive member exceeds privacy inspection limit')
        if self.expanded + size > self.max_bytes or self.members + 1 > self.max_members:
            raise ValueError('Archive aggregate privacy inspection limit exceeded')
        if time.monotonic() - self.started > self.max_seconds:
            raise ValueError('Archive privacy inspection time limit exceeded')

    def scan(self, name, data, depth=0, contexts=()):
        self.current_member = name
        self.check_budget(len(data))
        self.expanded += len(data)
        self.members += 1
        problems = reviewed_archive_findings(name, data, self.domains, contexts, self.reviews)
        results = [(name, problems)]
        approvals = matching_reviews(data, contexts, self.reviews)
        digest = hashlib.sha256(data).hexdigest()
        self.seen.update(identity for archive, member in contexts
                         if (identity := (archive, member, digest)) in self.expected_evidence)
        self.used_reviews.extend(approvals)
        raw = [r for r in approvals if r.get('inspection') == 'raw-public-test-sample'
               and r.get('testReference') and r.get('rawContentReview')]
        if raw and not problems:
            self.raw_samples.append({'member': name, 'sha256': hashlib.sha256(data).hexdigest(),
                                     'scope': 'raw bytes only; nested content not expanded'})
            return results
        lower = name.lower()
        is_zip = lower.endswith(('.zip', '.apk', '.jar', '.aar'))
        is_tar = lower.endswith(('.tar.gz', '.tgz', '.tar.xz', '.tar', '.tar.bz2', '.tar.zst'))
        if not (is_zip or is_tar):
            return results
        if depth >= self.max_depth:
            raise ValueError('Archive nesting limit exceeded')
        parent_hash = hashlib.sha256(data).hexdigest()

        def child(member, content):
            ancestry = tuple((digest, path + '/' + member) for digest, path in contexts)
            ancestry += ((parent_hash, member),)
            return self.scan(name + '/' + member, content, depth + 1, ancestry)

        if is_zip:
            with zipfile.ZipFile(io.BytesIO(data)) as archive:
                payload_ranges = []
                for member in archive.infolist():
                    self.current_member = name + '/' + member.filename
                    self.check_budget()
                    if not member.is_dir():
                        self.check_budget(member.file_size)
                        results.extend(child(member.filename, archive.read(member)))
                    else:
                        if member.file_size or archive.read(member):
                            raise ValueError('ZIP directory contains uninspected payload')
                        self.members += 1
                        results.append((self.current_member, findings(member.filename, b'', self.domains)))
                    # Only exclude payload bytes after the member was fully decoded,
                    # CRC-checked and inspected with its exact member identity.
                    offset = member.header_offset
                    if offset < 0 or data[offset:offset + 4] != b'PK\x03\x04':
                        raise ValueError('Invalid ZIP local header')
                    name_size, extra_size = struct.unpack_from('<HH', data, offset + 26)
                    start = offset + 30 + name_size + extra_size
                    end = start + member.compress_size
                    if start > archive.start_dir or end > archive.start_dir:
                        raise ValueError('ZIP payload overlaps archive metadata')
                    payload_ranges.append((offset, start, end))
                metadata = []
                cursor = 0
                for offset, start, end in sorted(payload_ranges):
                    if offset < cursor:
                        raise ValueError('Overlapping ZIP members')
                    metadata.append(data[cursor:start])
                    cursor = end
                metadata.append(data[cursor:])
                # Headers, comments, signing blocks, preambles and trailing bytes
                # remain inspected. A member review never approves the container.
                results[0] = (name, findings(name, b'\n'.join(metadata), self.domains))
        else:
            stream = io.BytesIO(data)
            if lower.endswith('.tar.zst'):
                import zstandard
                stream = zstandard.ZstdDecompressor().stream_reader(stream)
            elif lower.endswith(('.tar.gz', '.tgz')):
                import gzip
                stream = gzip.GzipFile(fileobj=stream)
            elif lower.endswith('.tar.xz'):
                import lzma
                stream = lzma.LZMAFile(stream)
            elif lower.endswith('.tar.bz2'):
                import bz2
                stream = bz2.BZ2File(stream)
            with stream, tarfile.open(fileobj=self.bounded_stream(stream), mode='r|') as archive:
                for member in archive:
                    self.current_member = name + '/' + member.name
                    self.check_budget()
                    if member.isfile():
                        self.check_budget(member.size)
                        results.extend(child(member.name, archive.extractfile(member).read()))
                    else:
                        self.members += 1
                        results.append((self.current_member, findings(member.name, member.linkname.encode(), self.domains)))
        return results


def scan_archive(name, data, domains, depth=0):
    scanner = ArchiveScan(domains)
    result = scanner.scan(name, data, depth)
    scanner.finish()
    return result


def scan_package_cached(path, domains, cache_directory=None):
    """Cache only completed accepted scans; policy and evidence fingerprints remain local."""
    path = Path(path)
    if path.stat().st_size > MAX_ARCHIVE_MEMBER_BYTES:
        raise ValueError('Package exceeds privacy inspection limit')
    data = path.read_bytes()
    reviews = load_public_reviews()
    scanner = ArchiveScan(domains, reviews)
    inputs = {'material': hashlib.sha256(data).hexdigest(), 'name': path.name,
              'scanner': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              'reviews': hashlib.sha256(json.dumps(reviews, sort_keys=True).encode()).hexdigest(),
              'policy': hashlib.sha256(json.dumps(sorted(domains)).encode()).hexdigest(),
              'settings': [scanner.max_bytes, scanner.max_members, scanner.max_seconds,
                           scanner.max_depth, MAX_ARCHIVE_MEMBER_BYTES]}
    key = hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()
    cache = Path(cache_directory) / (key + '.json') if cache_directory is not None else None
    if cache is not None and cache.is_file():
        try:
            saved = json.loads(cache.read_text(encoding='utf-8'))
        except (OSError, ValueError):
            saved = {}
        if saved.get('inputs') == inputs and saved.get('accepted') is True and saved.get('complete') is True:
            return saved
    results = scanner.scan(path.name, data)
    scanner.finish()
    rejected = [(name, reasons) for name, reasons in results if reasons]
    report = {'inputs': inputs, 'accepted': not rejected, 'complete': True,
              'items': scanner.members, 'expandedBytes': scanner.expanded,
              'rawSamples': scanner.raw_samples, 'rejected': rejected}
    if cache is not None and not rejected:
        cache.parent.mkdir(parents=True, exist_ok=True)
        temporary = cache.with_suffix('.tmp')
        temporary.write_text(json.dumps(report, ensure_ascii=False), encoding='utf-8')
        temporary.replace(cache)
    return report


def scan_packages_cached(paths, domains, cache_directory=None):
    """Verify exact origins and test references across the complete release asset set."""
    paths = [Path(path) for path in paths]
    materials = []
    for path in paths:
        if path.stat().st_size > MAX_ARCHIVE_MEMBER_BYTES:
            raise ValueError('Package exceeds privacy inspection limit')
        with path.open('rb') as stream:
            materials.append({'name': path.name, 'sha256': hashlib.file_digest(stream, 'sha256').hexdigest()})
    reviews = load_public_reviews()
    inputs = {'materials': materials,
              'scanner': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              'reviews': hashlib.sha256(json.dumps(reviews, sort_keys=True).encode()).hexdigest(),
              'policy': hashlib.sha256(json.dumps(sorted(domains)).encode()).hexdigest(),
              'settings': [4 * 1024**3, 200000, 1800, 6, MAX_ARCHIVE_MEMBER_BYTES]}
    key = hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()
    cache = Path(cache_directory) / ('release-' + key + '.json') if cache_directory is not None else None
    if cache is not None and cache.is_file():
        try:
            saved = json.loads(cache.read_text(encoding='utf-8'))
        except (OSError, ValueError):
            saved = {}
        if saved.get('inputs') == inputs and saved.get('accepted') is True and saved.get('complete') is True:
            return saved
    scanners = []
    rejected = []
    for path, material in zip(paths, materials):
        data = path.read_bytes()
        if hashlib.sha256(data).hexdigest() != material['sha256']:
            raise ValueError('Package changed during privacy inspection')
        scanner = ArchiveScan(domains, reviews)
        results = scanner.scan(path.name, data)
        rejected.extend((name, reasons) for name, reasons in results if reasons)
        scanners.append(scanner)
    verified = set().union(*(scanner.seen for scanner in scanners))
    for scanner in scanners:
        scanner.seen = verified
        scanner.finish()
    report = {'inputs': inputs, 'accepted': not rejected, 'complete': True,
              'rejected': rejected, 'items': sum(scanner.members for scanner in scanners),
              'rawSamples': [sample for scanner in scanners for sample in scanner.raw_samples]}
    if cache is not None and report['accepted']:
        cache.parent.mkdir(parents=True, exist_ok=True)
        temporary = cache.with_suffix('.tmp')
        temporary.write_text(json.dumps(report, ensure_ascii=False), encoding='utf-8')
        temporary.replace(cache)
    return report


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
        package_items = 0
        package_records = 0
        if arguments.outgoing:
            results.extend(outgoing_findings(arguments.outgoing, arguments.base, domains))
        if arguments.package:
            cache = git('rev-parse', '--git-path', 'jms-privacy-cache').decode().strip()
            report = scan_packages_cached(arguments.package, domains, cache)
            package_items = report['items']
            package_records = len(report['rejected'])
            results.extend(report['rejected'])
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
        checked = len(results) + package_items - package_records
        print(f'Privacy check: {checked} items checked; {len(rejected)} rejected.')
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
        problems = git_blob_findings(name, data, domains)
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
    except Exception:
        print('Privacy check could not complete; inspect local policy, Git objects or archive integrity.', file=sys.stderr)
        sys.exit(1)
