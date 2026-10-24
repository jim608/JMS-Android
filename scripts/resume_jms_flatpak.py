"""Resume validation of a byte-identical bundle from a verified native CI build."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import tempfile
import threading
import zipfile

from jms_publication import Github, ROOT, ReleaseError, sha256

REPOSITORY = 'jim608/JMS-Android'
WORKFLOW = '.github/workflows/jms-flatpak.yml'
MAX_BYTES = 512 * 1024**2
NATIVE_STEPS = ('建置鎖定的 Flutter Linux 來源', '建置原生依賴與 Flatpak')


def require(condition, message):
    if not condition:
        raise ReleaseError(message)


def native_artifact(github, run_id, source):
    require(type(run_id) is int and run_id > 0, 'Positive original CI run ID required')
    require(re.fullmatch('[a-f0-9]{40}', source), 'Exact original App source required')
    prefix = 'repos/' + REPOSITORY + '/actions/'
    run = github.api(prefix + 'runs/' + str(run_id))
    require(run.get('id') == run_id and run.get('status') == 'completed'
            and run.get('conclusion') == 'failure' and run.get('head_sha') == source
            and run.get('head_branch') == 'jms' and run.get('path') == WORKFLOW
            and run.get('event') == 'workflow_dispatch'
            and run.get('repository', {}).get('full_name') == REPOSITORY
            and run.get('head_repository', {}).get('full_name') == REPOSITORY,
            'Original native CI source, repository or workflow differs')
    jobs = github.api(prefix + 'runs/' + str(run_id) + '/jobs?per_page=100')
    require(jobs.get('total_count') == 1 and len(jobs.get('jobs', [])) == 1,
            'Original CI job inventory differs')
    job = jobs['jobs'][0]
    require(job.get('name') == 'flatpak' and job.get('status') == 'completed'
            and job.get('conclusion') == 'failure',
            'Original native CI job is incomplete')
    for name in NATIVE_STEPS:
        steps = [step for step in job.get('steps', []) if step.get('name') == name]
        require(len(steps) == 1 and steps[0].get('status') == 'completed'
                and steps[0].get('conclusion') == 'success',
                'Original Flutter/native build step did not succeed')
    listing = github.api(prefix + 'runs/' + str(run_id) + '/artifacts?per_page=100')
    require(type(listing.get('total_count')) is int and listing['total_count'] <= 100,
            'Original CI artifact inspection limit exceeded')
    attempt = run.get('run_attempt')
    require(type(attempt) is int and attempt > 0, 'Original CI attempt identity missing')
    expected = f'jms-flatpak-failure-{source}-{attempt}'
    matches = [entry for entry in listing.get('artifacts', []) if entry.get('name') == expected]
    require(len(matches) == 1, 'Original native artifact is missing or ambiguous')
    artifact = matches[0]
    identity = artifact.get('workflow_run', {})
    require(type(artifact.get('id')) is int and artifact['id'] > 0
            and artifact.get('expired') is False
            and type(artifact.get('size_in_bytes')) is int
            and 0 < artifact['size_in_bytes'] <= MAX_BYTES
            and re.fullmatch(r'sha256:[a-f0-9]{64}', artifact.get('digest', ''))
            and identity.get('id') == run_id and identity.get('head_branch') == 'jms'
            and identity.get('head_sha') == source,
            'Original native artifact digest or provenance missing')
    return artifact


def download(github, artifact, destination):
    endpoint = f'repos/{REPOSITORY}/actions/artifacts/{artifact["id"]}/zip'
    digest = hashlib.sha256()
    count = 0
    with destination.open('xb') as output, tempfile.TemporaryFile() as errors:
        prefix = ['rtk', 'proxy'] if shutil.which('rtk') else []
        process = subprocess.Popen([*prefix, str(github.executable), 'api', endpoint],
                                   cwd=ROOT, env=github.environment,
                                   stdout=subprocess.PIPE, stderr=errors)
        timer = threading.Timer(600, process.kill)
        timer.daemon = True
        timer.start()
        try:
            while chunk := process.stdout.read(1024**2):
                count += len(chunk)
                require(count <= MAX_BYTES, 'Original CI ZIP download limit exceeded')
                output.write(chunk)
                digest.update(chunk)
            require(process.wait() == 0, 'Original CI ZIP download failed or timed out')
        finally:
            timer.cancel()
            if process.poll() is None:
                process.kill()
                process.wait()
            process.stdout.close()
    require(count > 0 and digest.hexdigest() == artifact['digest'].removeprefix('sha256:'),
            'Original CI ZIP differs from registered SHA256')


def extract_bundle(archive_path, destination, bundle_name):
    with zipfile.ZipFile(archive_path) as archive:
        entries = archive.infolist()
        require(0 < len(entries) <= 200000, 'Original CI ZIP member limit exceeded')
        names = [entry.filename for entry in entries]
        require(len(names) == len(set(name.casefold() for name in names)),
                'Original CI ZIP has duplicate members')
        for name in names:
            require('\\' not in name and ':' not in name
                    and not PurePosixPath(name).is_absolute()
                    and '..' not in PurePosixPath(name).parts,
                    'Original CI ZIP has unsafe paths')
        require(sum(entry.file_size for entry in entries) <= 4 * 1024**3,
                'Original CI ZIP expansion limit exceeded')
        matches = [entry for entry in entries
                   if entry.filename in (bundle_name, 'candidate/' + bundle_name)]
        require(len(matches) == 1, 'Original CI bundle member is missing or ambiguous')
        member = matches[0]
        require(not member.is_dir() and not stat.S_ISLNK(member.external_attr >> 16)
                and 0 < member.file_size <= MAX_BYTES,
                'Original CI bundle member is not a bounded regular file')
        count = 0
        with archive.open(member) as source, destination.open('xb') as output:
            while chunk := source.read(1024**2):
                count += len(chunk)
                require(count <= member.file_size and count <= MAX_BYTES,
                        'Original CI bundle expansion limit exceeded')
                output.write(chunk)
        require(count == member.file_size, 'Original CI bundle is incomplete')
    return member.filename


def resume(github, run_id, source, output):
    artifact = native_artifact(github, run_id, source)
    pubspec = subprocess.check_output(['git', 'show', source + ':pubspec.yaml'], cwd=ROOT)
    version = re.search(rb'^version:\s*([A-Za-z0-9._-]+)\+([0-9]+)\s*$', pubspec, re.M)
    require(version is not None, 'Original App version is invalid')
    version_name = version[1].decode('ascii')
    bundle_name = f'JMS-Linux-{version_name}-x86_64.flatpak'
    output = Path(output)
    require(not output.exists() and not output.is_symlink(),
            'Resume output must be a new directory; existing candidate preserved')
    with tempfile.TemporaryDirectory(prefix='jms-flatpak-native-origin-') as temporary:
        archive = Path(temporary) / 'original.zip'
        download(github, artifact, archive)
        output.mkdir(parents=True, exist_ok=False)
        bundle = output / bundle_name
        member = extract_bundle(archive, bundle, bundle_name)
    origin = {
        'schemaVersion': 1, 'sourceCommit': source,
        'buildId': f'JMS-{version_name}-flatpak-{source[:12]}',
        'runId': run_id, 'artifactId': artifact['id'], 'artifactName': artifact['name'],
        'artifactDigest': artifact['digest'], 'bundleMember': member,
        'bundle': {'name': bundle_name, 'size': bundle.stat().st_size, 'sha256': sha256(bundle)},
    }
    (output / 'native-build-origin.json').write_text(
        json.dumps(origin, indent=2) + '\n', encoding='utf-8')
    return origin


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-commit', required=True)
    parser.add_argument('--run-id', required=True, type=int)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    executable = shutil.which('gh') or ROOT / '.jms-tools/gh/bin/gh.exe'
    try:
        origin = resume(Github(executable=executable, repository=REPOSITORY),
                        args.run_id, args.source_commit, args.output)
    except (OSError, ValueError, subprocess.SubprocessError, ReleaseError) as error:
        parser.exit(1, 'FLATPAK RESUME STOPPED: ' + str(error) + '\n')
    print(json.dumps(origin, indent=2))


if __name__ == '__main__':
    main()
