import contextlib
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request

from prepare_jms_release import ROOT, SECRET, sha256, validate_source_name

REPOSITORY = 'jim608/JMS-Android'
SIGNER = '4327eedb953fbf51d82b70e2e56c23122c85304d55a67fbbdb37a8f1ffd5f399'
BASELINE_CODE = 2008
MAX_ASSET = 512 * 1024 * 1024


class ReleaseError(ValueError):
    pass


def read_json(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))


def save_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    pending = path.with_suffix(path.suffix + '.pending')
    pending.write_text(json.dumps(value, indent=2, ensure_ascii=False), encoding='utf-8')
    os.replace(pending, path)


@contextlib.contextmanager
def release_lock(path):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('a+b') as stream:
        stream.seek(0, 2)
        if stream.tell() == 0:
            stream.write(b'0')
            stream.flush()
        stream.seek(0)
        try:
            if os.name == 'nt':
                import msvcrt
                msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            raise ReleaseError('Another JMS publisher holds the release lock') from error
        try:
            yield
        finally:
            stream.seek(0)
            if os.name == 'nt':
                msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(stream, fcntl.LOCK_UN)


def execute(command, *, environment=None, data=None, log=None, timeout=600):
    result = subprocess.run(['rtk', 'proxy', *map(str, command)], cwd=ROOT,
                            env=environment, input=data, capture_output=True, timeout=timeout)
    if log:
        output = result.stdout + result.stderr
        for name in ('GH_TOKEN', 'GITHUB_TOKEN'):
            secret = (environment or os.environ).get(name)
            if secret:
                output = output.replace(secret.encode(), b'[REDACTED]')
        Path(log).write_bytes(output)
    if result.returncode:
        raise ReleaseError(f'{Path(command[0]).name} failed (exit {result.returncode}); see local stage log')
    return result.stdout


def source_files():
    names = execute(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard']).decode().split('\0')
    result = {}
    for name in sorted(set(names)):
        if not name or name.startswith('.github/'):
            continue
        path = ROOT / name
        if not path.is_file():
            continue
        if name != 'AGENTS.md' and not validate_source_name(name):
            continue
        if path.is_symlink() or path.stat().st_size > 64 * 1024 * 1024:
            raise ReleaseError('Unsafe or unexpectedly large source: ' + name)
        data = path.read_bytes()
        if SECRET.search(data):
            raise ReleaseError('Possible credential in source: ' + name)
        if re.search(rb'(?i)(?:https?://[^\s/]+:[^\s/]+@|Bearer\s+[A-Za-z0-9_.-]{32,})', data):
            raise ReleaseError('Credential-like URL/header in source: ' + name)
        result[name] = sha256(path)
    required = {'LICENSE', 'pubspec.yaml', 'pubspec.lock', '.fvmrc', 'AGENTS.md', 'config/jms_updates.json'}
    if not required.issubset(result):
        raise ReleaseError('Required source/build/license files missing')
    return result


def source_fingerprint(files):
    return hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest()


def native_hashes(apk):
    import zipfile
    with zipfile.ZipFile(apk) as archive:
        return {name: hashlib.sha256(archive.read(name)).hexdigest() for name in archive.namelist()
                if name.endswith('.so') and not name.endswith('/libapp.so')}


def evidence_file(reference):
    if not isinstance(reference, dict) or not re.fullmatch('[a-f0-9]{64}', reference.get('sha256', '')):
        raise ReleaseError('Missing hash-bound publication evidence')
    path = (ROOT / reference['path']).resolve()
    if not path.is_relative_to(ROOT.resolve()) or not path.is_file() or sha256(path) != reference['sha256']:
        raise ReleaseError('Publication evidence missing, outside workspace or hash changed')
    return path


def publication_gates(policy, baseline_apk, signer=SIGNER):
    failures = []
    if policy.get('schemaVersion') != 1 or policy.get('repository') != REPOSITORY:
        return ['Publication policy must target only ' + REPOSITORY]
    try:
        signing = read_json(evidence_file(policy.get('signingEvidence')))
        if signing.get('signerSha256') != signer or signer != SIGNER:
            raise ReleaseError('Signer differs from installed .8 trust baseline')
        if not signing.get('ownerStatement') or not signing.get('reviewedAt'):
            raise ReleaseError('Owner must confirm key creation, holders, sharing and backup history; local scans cannot establish this')
        if not signing.get('sharingHistory') or not signing.get('backupCustody'):
            raise ReleaseError('Owner creation/custody recorded; external sharing and backup custody remain unspecified')
        if signing.get('status') != 'APPROVED' or signing.get('knownCompromise') is not False:
            raise ReleaseError('Signing custody review not approved or compromise found')
        if signing.get('localExposureAudit') != 'PASS':
            raise ReleaseError('Local signing exposure audit has not passed')
        audit = read_json(evidence_file(signing.get('auditEvidence')))
        if audit.get('status') != 'PASS':
            raise ReleaseError('Bound local exposure audit did not pass')
    except (ValueError, KeyError, OSError) as error:
        failures.append('SIGNING: ' + str(error))
    try:
        native = read_json(evidence_file(policy.get('nativeEvidence')))
        if native.get('missing'):
            raise ReleaseError('; '.join(native['missing']))
        if native.get('status') != 'APPROVED' or native.get('missing') != []:
            raise ReleaseError('Native license/corresponding-source review is incomplete')
        if native.get('nativeHashes') != native_hashes(baseline_apk):
            raise ReleaseError('Native dependency hashes changed; reuse of old audit refused')
        if not native.get('reviewedBy') or not native.get('legalBasis') or not native.get('materials'):
            raise ReleaseError('Native review lacks reviewer, license basis or corresponding materials')
        for material in native['materials']:
            evidence_file(material)
    except (ValueError, KeyError, OSError) as error:
        failures.append('NATIVE: ' + str(error))
    return failures


class Github:
    def __init__(self, executable=None):
        self.executable = executable or ROOT / '.jms-tools/gh/bin/gh.exe'
        self.environment = dict(os.environ, GH_HOST='github.com', GH_PROMPT_DISABLED='1', GIT_TERMINAL_PROMPT='0', GCM_INTERACTIVE='Never')
        for name in ('GH_DEBUG', 'GIT_TRACE', 'GIT_TRACE_CURL', 'GIT_CURL_VERBOSE'):
            self.environment.pop(name, None)

    def call(self, *arguments, data=None, timeout=300):
        return execute([self.executable, *arguments], environment=self.environment, data=data, timeout=timeout)

    def api(self, endpoint, method='GET', payload=None):
        prefix = 'repos/' + REPOSITORY
        if endpoint != 'user' and endpoint != prefix and not endpoint.startswith(prefix + '/'):
            raise ReleaseError('GitHub endpoint outside authorized repository')
        arguments = ['api', endpoint, '--method', method]
        data = None
        if payload is not None:
            arguments.extend(['--input', '-'])
            data = json.dumps(payload).encode()
        return json.loads(self.call(*arguments, data=data))

    def authenticate(self):
        try:
            account = self.api('user')
        except ReleaseError:
            credential = execute(['git', 'credential', 'fill'], environment=self.environment,
                                 data=b'protocol=https\nhost=github.com\nusername=jim608\n\n', timeout=20)
            fields = dict(line.split('=', 1) for line in credential.decode().splitlines() if '=' in line)
            if not fields.get('password'):
                raise ReleaseError('Authenticate GitHub CLI locally; never paste a token into chat')
            self.environment['GH_TOKEN'] = fields['password']
            account = self.api('user')
        if account.get('login') != 'jim608':
            raise ReleaseError('Authenticated account is not jim608; no automatic account switching')
        repository = self.api('repos/' + REPOSITORY)
        if repository.get('full_name') != REPOSITORY or repository.get('private') is not False:
            raise ReleaseError('Confirmed public JMS repository does not match')
        if repository.get('archived') or repository.get('permissions', {}).get('push') is not True:
            raise ReleaseError('Repository is archived or write permission is unavailable')
        return repository

    def releases(self):
        result = []
        for page in range(1, 11):
            rows = self.api(f'repos/{REPOSITORY}/releases?per_page=100&page={page}')
            result.extend(rows)
            if len(rows) < 100:
                return result
        raise ReleaseError('Release history exceeds bounded audit limit')

    def asset_bytes(self, asset, destination):
        if not 0 < asset['size'] <= MAX_ASSET or asset.get('state') != 'uploaded':
            raise ReleaseError('Remote asset incomplete or too large')
        with Path(destination).open('wb') as output:
            result = subprocess.run(['rtk', 'proxy', str(self.executable), 'api',
                f'repos/{REPOSITORY}/releases/assets/{asset["id"]}', '-H', 'Accept: application/octet-stream'],
                cwd=ROOT, env=self.environment, stdout=output, stderr=subprocess.PIPE, timeout=600)
        if result.returncode or Path(destination).stat().st_size != asset['size']:
            raise ReleaseError('Authenticated draft asset download/size verification failed')


def allowed_url(url, *, redirect=False):
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != 'https' or parsed.username or parsed.password or parsed.port not in (None, 443):
        return False
    if redirect and parsed.hostname in {'release-assets.githubusercontent.com', 'objects.githubusercontent.com'}:
        return True
    segments = parsed.path.split('/')[1:]
    return (parsed.hostname == 'github.com' and not parsed.query and not parsed.fragment
            and len(segments) == 6 and segments[:4] == ['jim608', 'JMS-Android', 'releases', 'download']
            and all(segment and urllib.parse.unquote(segment) not in {'.', '..'} for segment in segments))


class SafeRedirect(urllib.request.HTTPRedirectHandler):
    max_redirections = 5
    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        if not allowed_url(new_url, redirect=True):
            raise ReleaseError('Asset redirect outside GitHub HTTPS hosts')
        return super().redirect_request(request, file_pointer, code, message, headers, new_url)


def anonymous_download(url, destination, size, digest):
    if not allowed_url(url) or not 0 < size <= MAX_ASSET:
        raise ReleaseError('Invalid anonymous asset URL/size')
    destination = Path(destination)
    if destination.is_file() and destination.stat().st_size == size and sha256(destination) == digest:
        return False
    pending = destination.with_suffix(destination.suffix + '.part')
    try:
        opener = urllib.request.build_opener(SafeRedirect())
        request = urllib.request.Request(url, headers={'User-Agent': 'JMS-release-anonymous-verifier'})
        count = 0
        started = time.monotonic()
        with opener.open(request, timeout=30) as response, pending.open('wb') as output:
            while chunk := response.read(64 * 1024):
                count += len(chunk)
                if count > size or time.monotonic() - started > 600:
                    raise ReleaseError('Anonymous download exceeded expected size/time')
                output.write(chunk)
        if count != size or sha256(pending) != digest:
            raise ReleaseError('Anonymous download size/SHA-256 mismatch')
        os.replace(pending, destination)
        return True
    finally:
        pending.unlink(missing_ok=True)


def match_assets(release, files):
    actual = {}
    for asset in release.get('assets', []):
        name = asset['name']
        if name in actual or name not in files or asset.get('state') != 'uploaded':
            raise ReleaseError('Duplicate, unexpected or incomplete release asset')
        expected = files[name]
        if asset['size'] != expected['size']:
            raise ReleaseError('Existing release asset size differs: ' + name)
        remote_digest = asset.get('digest')
        if remote_digest and remote_digest != 'sha256:' + expected['sha256']:
            raise ReleaseError('Existing release asset checksum differs: ' + name)
        actual[name] = asset
    return actual


def upload_complete_release(github, state, files, save, verification_directory):
    release = github.api(f'repos/{REPOSITORY}/releases/{state["releaseId"]}')
    if release['tag_name'] != state['tag'] or release['prerelease'] != state['prerelease']:
        raise ReleaseError('Existing release tag/channel differs; never overwrite a published release')
    if release.get('body') != state['notes']:
        raise ReleaseError('Existing release notes differ; use a genuinely new version')
    actual = match_assets(release, files)
    if not release['draft'] and set(actual) != set(files):
        raise ReleaseError('Published release is incomplete/different; mutation refused')
    for name, expected in files.items():
        if name not in actual:
            github.call('release', 'upload', state['tag'], expected['path'], '--repo', REPOSITORY)
            release = github.api(f'repos/{REPOSITORY}/releases/{state["releaseId"]}')
            actual = match_assets(release, files)
        destination = Path(verification_directory) / name
        github.asset_bytes(actual[name], destination)
        if sha256(destination) != expected['sha256']:
            raise ReleaseError('Draft asset content differs; refusing publication: ' + name)
        state.setdefault('verifiedAssets', {})[name] = expected['sha256']
        save()
    if release['draft']:
        github.api(f'repos/{REPOSITORY}/releases/{state["releaseId"]}', 'PATCH', {'draft': False, 'make_latest': 'false'})
    state['published'] = True
    save()
