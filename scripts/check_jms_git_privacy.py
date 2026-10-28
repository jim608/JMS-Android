"""Check staged Git blobs, without printing matching private content."""

import argparse
import codecs
import ipaddress
from pathlib import Path, PurePosixPath
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


_CREDENTIAL_URL_HEADER = re.compile(
    r'https?://[^\s/:\x00-\x1f\x7f-\x9f\ud800-\udfff]+'
    r':[^\s/@\x00-\x1f\x7f-\x9f\ud800-\udfff]+@'
    # Preserve wrapped textual logs and Unicode whitespace, but never bridge
    # NULs, nontext control bytes, or malformed encoded characters.
    r'|\bBearer[^\S\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]+'
    r'[A-Za-z0-9_.-]{16,}', re.I)
_CREDENTIAL_UTF8_PREFIX = re.compile(rb'https?://|Bearer', re.I)
_CREDENTIAL_UTF16_PREFIXES = tuple(
    (encoding, re.compile('http'.encode(encoding)
        + b'(?:' + 's'.encode(encoding) + b')?' + '://'.encode(encoding)
        + b'|' + 'Bearer'.encode(encoding), re.I))
    for encoding in ('utf-16-le', 'utf-16-be'))


def credential_url_or_header(name, data):
    """Match contiguous text, preserving binary/string-pool boundaries.

    Invalid UTF-8 bytes and lone UTF-16 surrogates remain distinct boundary
    characters. No NUL is removed. Wide prefixes select only applicable byte
    alignments, avoiding four full binary decodes when no wide text is present.
    """
    if _CREDENTIAL_URL_HEADER.search(name):
        return True
    if (_CREDENTIAL_UTF8_PREFIX.search(data)
            and _CREDENTIAL_URL_HEADER.search(data.decode('utf-8', errors='surrogateescape'))):
        return True
    for encoding, prefix in _CREDENTIAL_UTF16_PREFIXES:
        alignments = set()
        for match in prefix.finditer(data):
            alignments.add(match.start() % 2)
            if len(alignments) == 2:
                break
        for alignment in alignments:
            end = len(data) - (len(data) - alignment) % 2
            text = codecs.decode(memoryview(data)[alignment:end], encoding, errors='surrogatepass')
            if _CREDENTIAL_URL_HEADER.search(text):
                return True
    return False


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
    if credential_url_or_header(name, data):
        problems.append('credential URL/header')
    assignments = re.findall(r'''(?i)(?<![A-Za-z0-9_])["']?(?:password|passwd|api[_-]?key|access[_-]?token|refresh[_-]?token|sessionCookie|cookie|set-cookie)["']?\s*[:=]\s*["']([A-Za-z0-9_./+=:;-]{16,})["']''', text)
    for value in assignments:
        # Explicitly synthetic credentials are permitted in public tests, never private policy matches.
        if not re.fullmatch(r'(?:connect\.sid=)?(?:fixture[-_][A-Za-z0-9_-]+|[A-Z_]*(?:ONLY|LEGACY))', value):
            problems.append('credential assignment')
            break
    if re.search(r'-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----|\bgh[pousr]_[A-Za-z0-9]{30,}\b|\bgithub_pat_[A-Za-z0-9_]{40,}\b', text):
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


def matching_reviews(data, contexts, reviews, *, inspection=None):
    digest = hashlib.sha256(data).hexdigest()
    return [review for review in reviews
            if (review.get('inspection') == inspection if inspection is not None
                else review.get('inspection') != 'public-ca-symlink')
            and review.get('sha256') == digest
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
    if review.get('inspection') == 'public-ca-symlink':
        certificate = review.get('certificate')
        target = review.get('linkTarget')
        origin = review.get('archiveSha256', '')
        if (review.get('rules') != ['private file type']
                or not re.fullmatch(r'[a-f0-9]{64}', origin)
                or review.get('source') != 'https://registry-1.docker.io/v2/library/nginx/blobs/sha256:' + origin
                or not isinstance(target, str) or not target or '\x00' in target or '\\' in target
                or hashlib.sha256(target.encode()).hexdigest() != review.get('sha256')
                or evidence['kind'] != 'upstream-public-x509-certificate'
                or not isinstance(certificate, dict)
                or certificate.get('member') != evidence['member']
                or certificate.get('sha256') != evidence['sha256']):
            return False
        certificate_origin = evidence.get('archiveSha256', origin)
        if (not isinstance(certificate_origin, str) or not re.fullmatch(r'[a-f0-9]{64}', certificate_origin)
                or certificate.get('source') != 'https://registry-1.docker.io/v2/library/nginx/blobs/sha256:' + certificate_origin):
            return False
        if any(not isinstance(items, list) or any(not isinstance(item, dict) for item in items)
               for items in (certificate.get('distributions', []), review.get('distributions', []))):
            return False
        for item in [certificate, *certificate.get('distributions', []),
                     {'member': review.get('member'), 'archiveSha256': origin},
                     *review.get('distributions', [])]:
            member = item.get('member', '')
            if (not isinstance(member, str) or not member or member.startswith('/')
                    or '\\' in member or ':' in member
                    or any(part in ('', '.', '..') for part in member.split('/'))
                    or ('archiveSha256' in item and (not isinstance(item['archiveSha256'], str)
                        or not re.fullmatch(r'[a-f0-9]{64}', item['archiveSha256'])))):
                return False
        return True
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
                 max_members=200000, max_seconds=1800, max_depth=6, project=None,
                 flatpak_bindings=None):
        import time
        self.domains = domains
        self.reviews = load_public_reviews() if reviews is None else reviews
        self.max_bytes = max_bytes
        self.max_members = max_members
        self.max_seconds = max_seconds
        self.max_depth = max_depth
        self.registry_project = project
        self.flatpak_bindings = flatpak_bindings or {}
        self.started = time.monotonic()
        self.expanded = 0
        self.members = 0
        self.raw_samples = []
        self.seen = set()
        self.used_reviews = []
        self.ca_link_origins = set()
        self.ca_links = []
        self.ca_certificate_identities = set()
        self.ca_verified_certificates = set()
        self.ca_parsed_digests = set()
        from jms_source_derivations import policy_entries
        self.source_derivations = policy_entries(project)
        self.source_lineage = {}
        self.stream_bytes = 0
        self.current_member = None
        self.expected_evidence = set()
        for review in self.reviews:
            for evidence in [review.get('evidence', {})] + review.get('additionalEvidence', []):
                if isinstance(evidence, dict):
                    self.expected_evidence.add((evidence.get('archiveSha256', review.get('archiveSha256')),
                                               evidence.get('member'), evidence.get('sha256')))
            self.expected_evidence.add((review.get('archiveSha256'), review.get('member'), review.get('sha256')))
            if review.get('inspection') == 'public-ca-symlink' and valid_evidence(review):
                evidence = review['evidence']
                identities = {(evidence.get('archiveSha256', review['archiveSha256']),
                               evidence['member'], evidence['sha256'])}
                identities.update((item['archiveSha256'], item['member'], review['certificate']['sha256'])
                                  for item in review['certificate'].get('distributions', []))
                self.ca_certificate_identities.update(identities)
                self.expected_evidence.update(identities)

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
        for review, contexts in self.ca_links:
            origin = (review['archiveSha256'], review['member'], review['sha256'])
            if origin not in self.ca_link_origins:
                raise ValueError('Public CA origin was not verified as an exact TAR symlink')
            evidence = review['evidence']
            official = (evidence.get('archiveSha256', review['archiveSha256']),
                        evidence['member'], evidence['sha256'])
            if official not in self.ca_verified_certificates:
                raise ValueError('Public CA official certificate was not parsed from a regular member')
            allowed = {official}
            allowed.update((item['archiveSha256'], item['member'], review['certificate']['sha256'])
                           for item in review['certificate'].get('distributions', []))
            parents = {archive for archive, _ in contexts}
            if not any(item in self.ca_verified_certificates and item[0] in parents for item in allowed):
                raise ValueError('Public CA certificate missing from the inspected link container')
            for middle in self.ca_target_chain(review):
                identity = (middle['archiveSha256'], middle['member'], middle['sha256'])
                identities = {identity}
                identities.update((item['archiveSha256'], item['member'], middle['sha256'])
                                  for item in middle.get('distributions', []))
                if identity not in self.ca_link_origins or not any(
                        item in self.ca_link_origins and item[0] in parents for item in identities):
                    raise ValueError('Public CA intermediate symlink missing from inspected materials')

    def verify_ca_certificate(self, data, identities):
        """Parse only pinned regular CA evidence in an empty, local TLS store."""
        digest = hashlib.sha256(data).hexdigest()
        if digest not in self.ca_parsed_digests:
            import ssl
            if (b'PRIVATE KEY' in data.upper() or not re.fullmatch(
                    rb'(?:\s*-----BEGIN CERTIFICATE-----\r?\n[A-Za-z0-9+/=\r\n]+-----END CERTIFICATE-----\s*)+', data)):
                raise ValueError('Public CA evidence is not certificate-only PEM')
            try:
                parser = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
                if parser.cert_store_stats()['x509']:
                    raise ValueError('Public CA parser unexpectedly has ambient trust roots')
                parser.load_verify_locations(cadata=data.decode('ascii'))
                stats = parser.cert_store_stats()
                if not stats['x509'] or stats['x509_ca'] != stats['x509']:
                    raise ValueError('Public CA evidence contains non-CA certificates')
            except (UnicodeError, ssl.SSLError) as error:
                raise ValueError('Public CA evidence cannot be parsed') from error
            self.ca_parsed_digests.add(digest)
        self.ca_verified_certificates.update(identities)

    def ca_target_chain(self, review):
        """Follow only reviewed same-origin links to their pinned CA member."""
        current = review
        seen = set()
        chain = []
        expected = review['certificate']
        for _ in range(20):
            path = current['member']
            if path in seen:
                return None
            seen.add(path)
            target = current['linkTarget']
            parts = [] if target.startswith('/') else path.split('/')[:-1]
            for part in target.split('/'):
                if part in ('', '.'):
                    continue
                if part == '..':
                    if not parts:
                        return None
                    parts.pop()
                else:
                    parts.append(part)
            resolved = '/'.join(parts)
            if resolved == expected['member']:
                return chain
            candidates = [item for item in self.reviews
                          if item.get('inspection') == 'public-ca-symlink' and valid_evidence(item)
                          and item['archiveSha256'] == review['archiveSha256'] and item['member'] == resolved
                          and item['certificate']['member'] == expected['member']
                          and item['certificate']['sha256'] == expected['sha256']]
            if len(candidates) != 1:
                return None
            current = candidates[0]
            chain.append(current)
        return None

    def ca_target_resolves(self, review):
        return self.ca_target_chain(review) is not None

    def scan_ca_link(self, member, contexts):
        data = member.linkname.encode()
        problems = findings(member.name, data, self.domains)
        if not member.issym():
            return problems
        approvals = [review for review in matching_reviews(data, contexts, self.reviews,
                                                          inspection='public-ca-symlink')
                     if self.ca_target_resolves(review)]
        if not approvals:
            return problems
        digest = hashlib.sha256(data).hexdigest()
        identities = {(archive, name, digest) for archive, name in contexts}
        self.seen.update(identities & self.expected_evidence)
        self.ca_link_origins.update(identities)
        self.used_reviews.extend(approvals)
        self.ca_links.extend((review, contexts) for review in approvals)
        return [problem for problem in problems if problem != 'private file type']

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

    @staticmethod
    def tar_input(data, compression):
        stream = io.BytesIO(data)
        if compression == 'zstd':
            import zstandard
            return zstandard.ZstdDecompressor().stream_reader(stream)
        if compression == 'gzip':
            import gzip
            return gzip.GzipFile(fileobj=stream)
        if compression == 'xz':
            import lzma
            return lzma.LZMAFile(stream)
        if compression == 'bzip2':
            import bz2
            return bz2.BZ2File(stream)
        return stream

    @staticmethod
    def oci_path(name):
        if not isinstance(name, str):
            raise ValueError('OCI archive path must be text')
        path = PurePosixPath(name)
        if (not name or path.is_absolute() or '..' in path.parts
                or any(value in name for value in ('\\', '\x00', '\n', '\r', '\t'))):
            raise ValueError('Unsafe OCI archive path')
        return path.as_posix()

    def oci_descriptors(self, data, compression):
        """Recognize an OCI layout and validate every referenced blob before descent.

        The catalog pass is bounded like the subsequent content scan. It retains
        only small JSON metadata, never complete layers or a reconstructed image.
        Every historical layer is scanned, including files later whiteouted.
        """
        records, metadata, duplicate, unsafe, catalog_members = {}, {}, False, False, 0
        metadata_files = {'oci-layout', 'index.json', 'manifest.json', 'repositories'}
        with self.tar_input(data, compression) as stream, tarfile.open(
                fileobj=self.bounded_stream(stream), mode='r|') as archive:
            for member in archive:
                self.check_budget()
                self.check_budget(member.size)
                catalog_members += 1
                if catalog_members + self.members > self.max_members:
                    raise ValueError('Archive aggregate privacy inspection limit exceeded')
                try:
                    path = self.oci_path(member.name)
                except ValueError:
                    unsafe = True
                    path = member.name
                duplicate |= path in records
                records[path] = (member.name, member.size, member.isfile())
                if member.isfile() and (path in metadata_files or path.startswith('blobs/')):
                    source = archive.extractfile(member)
                    prefix = source.read(4)
                    if path in metadata_files or member.size <= 16 * 1024 * 1024:
                        content = prefix + source.read()
                        if len(content) != member.size:
                            raise ValueError('Truncated OCI metadata')
                        if path in metadata_files or content.lstrip()[:1] in (b'{', b'['):
                            metadata[path] = content
        if 'oci-layout' not in records:
            return None
        if duplicate or unsafe or any(not regular and size for _, size, regular in records.values()):
            raise ValueError('Duplicate, unsafe or payload-bearing OCI metadata')

        def json_object(path):
            def unique_pairs(pairs):
                value = {}
                for key, item in pairs:
                    if key in value:
                        raise ValueError('Duplicate OCI JSON key')
                    value[key] = item
                return value
            if path not in metadata or not records[path][2]:
                raise ValueError('Missing or oversized OCI JSON metadata')
            try:
                return json.loads(metadata[path], object_pairs_hook=unique_pairs)
            except (UnicodeError, json.JSONDecodeError) as error:
                raise ValueError('Invalid OCI JSON metadata') from error

        if json_object('oci-layout') != {'imageLayoutVersion': '1.0.0'}:
            raise ValueError('Unsupported OCI layout version')
        layer_types = {
            'application/vnd.oci.image.layer.v1.tar': '',
            'application/vnd.oci.image.layer.v1.tar+gzip': 'gzip',
            'application/vnd.oci.image.layer.nondistributable.v1.tar': '',
            'application/vnd.oci.image.layer.nondistributable.v1.tar+gzip': 'gzip',
            'application/vnd.docker.image.rootfs.diff.tar.gzip': 'gzip',
            'application/vnd.docker.image.rootfs.foreign.diff.tar.gzip': 'gzip',
        }
        index_types = {'application/vnd.oci.image.index.v1+json',
                       'application/vnd.docker.distribution.manifest.list.v2+json'}
        manifest_types = {'application/vnd.oci.image.manifest.v1+json',
                          'application/vnd.docker.distribution.manifest.v2+json'}
        config_types = {'application/vnd.oci.image.config.v1+json',
                        'application/vnd.docker.container.image.v1+json'}
        descriptors, images = {}, set()

        def visit(descriptor, level=0):
            if not isinstance(descriptor, dict) or level > self.max_depth:
                raise ValueError('Invalid or excessively nested OCI descriptor')
            digest, size, media = (descriptor.get(key) for key in ('digest', 'size', 'mediaType'))
            if (not isinstance(digest, str) or not re.fullmatch(r'sha256:[a-f0-9]{64}', digest)
                    or type(size) is not int or size < 0):
                raise ValueError('Invalid OCI digest or size')
            path = 'blobs/sha256/' + digest[7:]
            if path not in records or not records[path][2] or records[path][1] != size:
                raise ValueError('Missing OCI blob or descriptor size mismatch')
            self.check_budget(size)
            identity = {'sha256': digest[7:], 'size': size, 'mediaType': media}
            if path in descriptors:
                if any(descriptors[path].get(key) != value for key, value in identity.items()):
                    raise ValueError('Conflicting OCI blob descriptors')
                return path
            descriptors[path] = identity
            if media in layer_types:
                identity['compression'] = layer_types[media]
                return path
            if media not in index_types | manifest_types | config_types:
                raise ValueError('Unsupported OCI blob media type')
            if hashlib.sha256(metadata.get(path, b'')).hexdigest() != digest[7:]:
                raise ValueError('OCI metadata digest mismatch')
            value = json_object(path)
            if not isinstance(value, dict):
                raise ValueError('OCI metadata must be a JSON object')
            if media in config_types:
                return path
            if value.get('schemaVersion') != 2:
                raise ValueError('Unsupported OCI manifest schema')
            if media in index_types:
                children = value.get('manifests')
                if not isinstance(children, list) or not children:
                    raise ValueError('OCI index has no manifests')
                for child in children:
                    if not isinstance(child, dict) or child.get('mediaType') not in index_types | manifest_types:
                        raise ValueError('OCI index references a nonimage descriptor')
                    visit(child, level + 1)
            else:
                config = visit(value.get('config'), level + 1)
                layers = value.get('layers')
                if (descriptors[config]['mediaType'] not in config_types or not isinstance(layers, list)):
                    raise ValueError('Invalid OCI config or layers')
                ordered = tuple(visit(layer, level + 1) for layer in layers)
                if any(descriptors[path]['mediaType'] not in layer_types for path in ordered):
                    raise ValueError('OCI layer references a nonlayer blob')
                images.add((config, ordered))
            return path

        index = json_object('index.json')
        if (not isinstance(index, dict) or index.get('schemaVersion') != 2
                or index.get('mediaType', 'application/vnd.oci.image.index.v1+json') not in index_types
                or not isinstance(index.get('manifests'), list) or not index['manifests']):
            raise ValueError('Invalid OCI root index')
        for descriptor in index['manifests']:
            if not isinstance(descriptor, dict) or descriptor.get('mediaType') not in index_types | manifest_types:
                raise ValueError('OCI index references a nonimage descriptor')
            visit(descriptor)
        if not images:
            raise ValueError('OCI layout has no image manifests')
        blobs = {path for path in records if path.startswith('blobs/') and records[path][2]}
        # Docker-save also emits legacy per-layer JSON config blobs. They are
        # not image payload exemptions: validate their exact hash, schema and
        # complete parent chain against the declared plain layers and tag map,
        # then scan every JSON byte normally in the content pass.
        extras = blobs - set(descriptors)
        legacy_configs = {}
        legacy_keys = {'id', 'parent', 'created', 'container_config', 'config', 'architecture', 'os'}
        for path in extras:
            if (not re.fullmatch(r'blobs/sha256/[a-f0-9]{64}', path) or path not in metadata
                    or hashlib.sha256(metadata[path]).hexdigest() != path.rsplit('/', 1)[1]):
                raise ValueError('Unreferenced or unsupported OCI blobs')
            value = json_object(path)
            if (not isinstance(value, dict) or set(value) - legacy_keys
                    or not {'id', 'created', 'container_config', 'os'} <= set(value)
                    or not isinstance(value['id'], str) or not re.fullmatch('[a-f0-9]{64}', value['id'])
                    or value['id'] in legacy_configs or not isinstance(value['created'], str)
                    or not isinstance(value['container_config'], dict) or not isinstance(value['os'], str)
                    or ('config' in value and not isinstance(value['config'], dict))
                    or ('parent' in value and (not isinstance(value['parent'], str)
                        or not re.fullmatch('[a-f0-9]{64}', value['parent'])))):
                raise ValueError('Invalid Docker-save compatibility config')
            legacy_configs[value['id']] = value
            descriptors[path] = {'sha256': path.rsplit('/', 1)[1], 'size': records[path][1],
                                 'mediaType': 'docker-save-compatibility-json'}
        if extras and 'manifest.json' not in records:
            raise ValueError('Unreferenced OCI compatibility configs')
        used_configs, expected_repositories = set(), {}
        if 'manifest.json' in records:
            legacy = json_object('manifest.json')
            if not isinstance(legacy, list) or not legacy:
                raise ValueError('Invalid Docker-save manifest')
            for image in legacy:
                if not isinstance(image, dict) or not isinstance(image.get('Layers'), list):
                    raise ValueError('Invalid Docker-save image entry')
                config = self.oci_path(image.get('Config', ''))
                layers = tuple(self.oci_path(path) for path in image['Layers'])
                if (config, layers) not in images:
                    raise ValueError('Docker-save and OCI manifests differ')
                if extras:
                    config_value = json_object(config)
                    ids = [path.rsplit('/', 1)[1] for path in layers]
                    if not ids or any(path not in descriptors or descriptors[path].get('compression') != '' for path in layers):
                        raise ValueError('Unsupported Docker-save compatibility layer representation')
                    canonical = config_value.get('config', {})
                    defaults = {'AttachStderr': False, 'AttachStdin': False, 'AttachStdout': False,
                                'OpenStdin': False, 'StdinOnce': False, 'Tty': False, 'Domainname': '',
                                'Hostname': '', 'Image': '', 'Cmd': None, 'OnBuild': None, 'Volumes': None}
                    leaves = []
                    for leaf in legacy_configs.values():
                        if 'config' not in leaf or leaf.get('architecture') != config_value.get('architecture'):
                            continue
                        compatible = dict(leaf['config'])
                        valid = True
                        for key in set(compatible) - set(canonical):
                            if key not in defaults or compatible[key] != defaults[key]:
                                valid = False
                            del compatible[key]
                        if valid and compatible == canonical:
                            leaves.append(leaf)
                    if len(leaves) != 1:
                        raise ValueError('Docker-save compatibility runtime config differs')
                    # Legacy v1 IDs are generated IDs, not layer DiffIDs. Bind
                    # their entire acyclic parent chain by the image's exact
                    # runtime config, OS/architecture and declared layer count.
                    chain, value = set(), leaves[0]
                    while value is not None:
                        identifier = value['id']
                        if (identifier in chain or value['os'] != config_value.get('os')
                                or len(chain) >= len(ids)):
                            raise ValueError('Docker-save compatibility parent chain differs')
                        chain.add(identifier)
                        if 'parent' not in value:
                            break
                        value = legacy_configs.get(value['parent'])
                        if value is None:
                            raise ValueError('Docker-save compatibility parent chain differs')
                    if len(chain) != len(ids):
                        raise ValueError('Docker-save compatibility parent chain differs')
                    used_configs.update(chain)
                    tags = image.get('RepoTags')
                    if not isinstance(tags, list) or not tags:
                        raise ValueError('Docker-save compatibility tags missing')
                    for tag in tags:
                        if not isinstance(tag, str) or ':' not in tag:
                            raise ValueError('Invalid Docker-save compatibility tag')
                        repository, label = tag.rsplit(':', 1)
                        expected_repositories.setdefault(repository, {})[label] = ids[-1]
                sources = image.get('LayerSources', {})
                if not isinstance(sources, dict):
                    raise ValueError('Invalid Docker-save layer sources')
                for digest, descriptor in sources.items():
                    if not isinstance(digest, str) or not re.fullmatch(r'sha256:[a-f0-9]{64}', digest):
                        raise ValueError('Invalid Docker-save layer source digest')
                    path = 'blobs/sha256/' + digest.removeprefix('sha256:')
                    expected = descriptors.get(path, {})
                    if (path not in layers or not isinstance(descriptor, dict)
                            or descriptor.get('digest') != digest
                            or descriptor.get('size') != expected.get('size')
                            or descriptor.get('mediaType') != expected.get('mediaType')):
                        raise ValueError('Docker-save layer source differs from OCI descriptor')
        if extras and (used_configs != set(legacy_configs) or json_object('repositories') != expected_repositories):
            raise ValueError('Unreferenced or inconsistent Docker-save compatibility configs')
        return descriptors

    def scan(self, name, data, depth=0, contexts=(), *, _oci_format=None):
        self.current_member = name
        self.check_budget(len(data))
        self.expanded += len(data)
        self.members += 1
        source_registry = ('JMS/config/jms_public_privacy_reviews.json')
        if (depth == 1 and len(contexts) == 1 and contexts[0][1] == source_registry
                and name.endswith('.zip/' + source_registry)):
            # The committed source archive carries the same formal registry.
            # Reuse its exact origin/member/evidence validation; this does not
            # approve other JSON paths, container metadata or package contents.
            problems = git_blob_findings('config/jms_public_privacy_reviews.json', data,
                                         self.domains, self.registry_project)
        else:
            problems = reviewed_archive_findings(name, data, self.domains, contexts, self.reviews)
        results = [(name, problems)]
        approvals = matching_reviews(data, contexts, self.reviews)
        digest = hashlib.sha256(data).hexdigest()
        if depth == 0:
            from jms_source_derivations import verify_lineage
            for derivation in self.source_derivations:
                if derivation.get('archiveSha256') == digest:
                    self.source_lineage.update(verify_lineage(data, derivation, self.registry_project))
        self.seen.update(identity for archive, member in contexts
                         if (identity := (archive, member, digest)) in self.expected_evidence)
        ca_identities = {(archive, member, digest) for archive, member in contexts} & self.ca_certificate_identities
        if ca_identities:
            self.verify_ca_certificate(data, ca_identities)
        # Only an actually scanned, unchanged retained member can supply its
        # original identity. Excluded members and changed containers never do.
        for archive, member in contexts:
            origin = self.source_lineage.get((archive, member, digest))
            if origin in self.expected_evidence:
                self.seen.add(origin)
        self.used_reviews.extend(approvals)
        raw = [r for r in approvals if r.get('inspection') == 'raw-public-test-sample'
               and r.get('testReference') and r.get('rawContentReview')]
        if raw and not problems and _oci_format is None:
            self.raw_samples.append({'member': name, 'sha256': hashlib.sha256(data).hexdigest(),
                                     'scope': 'raw bytes only; nested content not expanded'})
            return results
        lower = name.lower()
        if lower.endswith('.flatpak'):
            # An OSTree static delta is compressed binary content. Raw-byte
            # inspection cannot establish a complete package privacy result.
            # Only the publication gate can supply an independently downloaded,
            # hash-bound successful CI installation export for this bundle.
            binding = self.flatpak_bindings.get(name) if depth == 0 else None
            if (not isinstance(binding, dict)
                    or not re.fullmatch(r'[a-f0-9]{64}', binding.get('payloadSha256', ''))
                    or not re.fullmatch(r'[a-f0-9]{64}', binding.get('provenanceSha256', ''))):
                raise ValueError('Flatpak privacy inspection requires verified installed CI payload provenance')
            payload = Path(binding['payloadPath'])
            if not payload.name.lower().endswith('.tar.gz') or payload.stat().st_size > MAX_ARCHIVE_MEMBER_BYTES:
                raise ValueError('Invalid Flatpak installed privacy payload')
            content = payload.read_bytes()
            if hashlib.sha256(content).hexdigest() != binding['payloadSha256']:
                raise ValueError('Flatpak installed privacy payload changed')
            results.extend(self.scan(name + '/' + payload.name, content, depth + 1,
                                     ((digest, payload.name),)))
            return results
        is_zip = lower.endswith(('.zip', '.apk', '.jar', '.aar'))
        is_tar = _oci_format is not None or lower.endswith(('.tar.gz', '.tgz', '.tar.xz', '.tar', '.tar.bz2', '.tar.zst'))
        if not (is_zip or is_tar):
            return results
        if depth >= self.max_depth:
            raise ValueError('Archive nesting limit exceeded')
        parent_hash = hashlib.sha256(data).hexdigest()

        def child(member, content, oci_format=None):
            ancestry = tuple((digest, path + '/' + member) for digest, path in contexts)
            ancestry += ((parent_hash, member),)
            return self.scan(name + '/' + member, content, depth + 1, ancestry, _oci_format=oci_format)

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
            compression = (_oci_format if _oci_format is not None else
                           'zstd' if lower.endswith('.tar.zst') else
                           'gzip' if lower.endswith(('.tar.gz', '.tgz')) else
                           'xz' if lower.endswith('.tar.xz') else
                           'bzip2' if lower.endswith('.tar.bz2') else '')
            descriptors = None if _oci_format is not None else self.oci_descriptors(data, compression)
            structural = _oci_format is not None or descriptors is not None
            plain = data
            if structural and compression:
                with self.tar_input(data, compression) as compressed:
                    reader = self.bounded_stream(compressed)
                    chunks = []
                    while chunk := reader.read(1024 * 1024):
                        chunks.append(chunk)
                    plain = b''.join(chunks)
            stream = io.BytesIO(plain) if structural else self.tar_input(data, compression)
            payload_ranges, seen_paths = [], set()
            with stream, tarfile.open(fileobj=self.bounded_stream(stream), mode='r|') as archive:
                for member in archive:
                    self.current_member = name + '/' + member.name
                    self.check_budget()
                    if structural:
                        path = self.oci_path(member.name)
                        if path in seen_paths or member.sparse is not None:
                            raise ValueError('Duplicate or sparse OCI layer member')
                        seen_paths.add(path)
                    if member.isfile():
                        self.check_budget(member.size)
                        content = archive.extractfile(member).read()
                        if len(content) != member.size:
                            raise ValueError('Truncated TAR member')
                        descriptor = descriptors.get(path) if descriptors is not None else None
                        if descriptor is not None and (len(content) != descriptor['size']
                                or hashlib.sha256(content).hexdigest() != descriptor['sha256']):
                            raise ValueError('OCI blob digest or size mismatch')
                        results.extend(child(member.name, content,
                            descriptor.get('compression') if descriptor is not None else None))
                        if structural:
                            start, end = member.offset_data, member.offset_data + member.size
                            if start < 0 or end > len(plain):
                                raise ValueError('Invalid OCI TAR payload range')
                            payload_ranges.append((start, end))
                    else:
                        if structural and member.size:
                            raise ValueError('OCI nonfile member contains uninspected payload')
                        self.members += 1
                        ancestry = tuple((value, parent + '/' + member.name) for value, parent in contexts)
                        ancestry += ((parent_hash, member.name),)
                        results.append((self.current_member, self.scan_ca_link(member, ancestry)))
            if structural:
                metadata, cursor = [], 0
                for start, end in sorted(payload_ranges):
                    if start < cursor:
                        raise ValueError('Overlapping OCI TAR members')
                    metadata.append(plain[cursor:start])
                    cursor = end
                metadata.append(plain[cursor:])
                # Like ZIP, exclude only payload bytes already fully decoded and
                # scanned with their exact identities. Headers, links, PAX data,
                # padding and trailing bytes remain subject to the raw policy.
                header_problems = findings(name, b'\n'.join(metadata), self.domains)
                results[0] = (name, list(dict.fromkeys((problems if compression else []) + header_problems)))
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
    from jms_source_derivations import lineage_cache_inputs
    inputs = {'material': hashlib.sha256(data).hexdigest(), 'name': path.name,
              'sourceLineage': lineage_cache_inputs([hashlib.sha256(data).hexdigest()]),
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


def scan_packages_cached(paths, domains, cache_directory=None, *, flatpak_bindings=None):
    """Verify exact origins and test references across the complete release asset set."""
    paths = [Path(path) for path in paths]
    materials = []
    for path in paths:
        if path.stat().st_size > MAX_ARCHIVE_MEMBER_BYTES:
            raise ValueError('Package exceeds privacy inspection limit')
        with path.open('rb') as stream:
            materials.append({'name': path.name, 'sha256': hashlib.file_digest(stream, 'sha256').hexdigest()})
    bound_payloads = {}
    for name, binding in (flatpak_bindings or {}).items():
        if (not isinstance(binding, dict) or not name.lower().endswith('.flatpak')
                or name not in {item['name'] for item in materials}
                or not re.fullmatch(r'[a-f0-9]{64}', binding.get('payloadSha256', ''))
                or not re.fullmatch(r'[a-f0-9]{64}', binding.get('provenanceSha256', ''))):
            raise ValueError('Invalid Flatpak privacy provenance binding')
        payload = Path(binding['payloadPath'])
        if {'name': payload.name, 'sha256': binding['payloadSha256']} not in materials:
            raise ValueError('Flatpak installed payload differs from inspected release materials')
        bound_payloads[name] = {'payloadName': payload.name,
                               'payloadSha256': binding['payloadSha256'],
                               'provenanceSha256': binding['provenanceSha256']}
    reviews = load_public_reviews()
    from jms_source_derivations import lineage_cache_inputs
    inputs = {'materials': materials,
              'flatpakBindings': bound_payloads,
              'sourceLineage': lineage_cache_inputs([item['sha256'] for item in materials]),
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
        scanner = ArchiveScan(domains, reviews, flatpak_bindings=flatpak_bindings)
        results = scanner.scan(path.name, data)
        rejected.extend((name, reasons) for name, reasons in results if reasons)
        scanners.append(scanner)
    verified = set().union(*(scanner.seen for scanner in scanners))
    verified_ca_links = set().union(*(scanner.ca_link_origins for scanner in scanners))
    verified_ca_certificates = set().union(*(scanner.ca_verified_certificates for scanner in scanners))
    for scanner in scanners:
        scanner.seen = verified
        # Only identities observed during these complete, actual material scans
        # can satisfy cross-material origin evidence. Each link retains its own
        # container contexts for current certificate and intermediate checks.
        scanner.ca_link_origins = verified_ca_links
        scanner.ca_verified_certificates = verified_ca_certificates
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
