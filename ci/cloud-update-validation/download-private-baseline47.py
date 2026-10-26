"""Future own-repository CI read step. Never publishes or signs the old input.

GH_TOKEN is used only by gh in this step, with a fresh isolated gh config.
Only the accepted original runtime is extracted. Source/native archives stay in
the private ZIP and neither the ZIP nor runtime belongs in upload-artifact paths.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import zipfile


def require(value, message):
    if not value:
        raise ValueError(message)


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main(args):
    binding = json.loads(Path(__file__).with_name('baseline47-private-binding.json').read_text())
    ci, runtime = binding['ci'], binding['runtime']
    require(binding['privateRuntimeFixtureAccepted'] is True and
            binding['originalFullPublicGatePassed'] is False and
            binding['publicRepublishOrSigningPermitted'] is False, 'Private fixture scope differs')
    require(os.environ.get('GITHUB_ACTIONS') == 'true' and
            os.environ.get('GITHUB_REPOSITORY') == ci['repository'], 'Own JMS-Android CI is required')
    run_id = os.environ.get('GITHUB_RUN_ID', '')
    require(run_id.isdigit() and run_id, 'Cloud run identity missing')
    expected = Path('/var/tmp/jms-private-baseline-' + run_id)
    require(args.output == expected and not expected.exists() and not expected.is_symlink(),
            'Fresh private fixture directory required')
    token = os.environ.get('GH_TOKEN')
    require(token, 'Read-only own-Actions token is required in this download step only')
    gh = shutil.which('gh')
    require(gh, 'Existing GitHub CLI is required')
    expected.mkdir(mode=0o700)
    expected.chmod(0o700)
    config = expected / 'gh-config'
    config.mkdir(mode=0o700)
    environment = {'PATH': os.environ['PATH'], 'HOME': str(expected), 'GH_CONFIG_DIR': str(config),
                   'GH_TOKEN': token, 'GH_HOST': 'github.com', 'GH_PROMPT_DISABLED': '1'}
    prefix = 'repos/' + ci['repository'] + '/actions/'

    def api(path):
        result = subprocess.run([gh, 'api', prefix + path], env=environment,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=60)
        require(result.returncode == 0, 'Authenticated Actions metadata read failed')
        return json.loads(result.stdout)

    run = api('runs/' + str(ci['runId']))
    require(run.get('id') == ci['runId'] and run.get('status') == 'completed' and
            run.get('conclusion') == 'success' and run.get('head_branch') == 'jms' and
            run.get('head_sha') == ci['sourceCommit'] and run.get('path') == '.github/workflows/jms-flatpak.yml',
            'Original successful CI identity differs')
    jobs = api('runs/' + str(ci['runId']) + '/jobs?per_page=100')
    matching = [item for item in jobs.get('jobs', []) if item.get('name') == 'flatpak']
    require(jobs.get('total_count', 101) <= 100 and len(matching) == 1 and
            matching[0].get('status') == 'completed' and matching[0].get('conclusion') == 'success',
            'Original Flatpak job was not verified successful')
    artifact = api('artifacts/' + str(ci['artifactId']))
    identity = artifact.get('workflow_run', {})
    require(artifact.get('id') == ci['artifactId'] and artifact.get('name') == ci['artifactName'] and
            artifact.get('expired') is False and artifact.get('size_in_bytes') == ci['zipBytes'] and
            artifact.get('digest') == 'sha256:' + ci['zipSHA256'] and
            identity.get('id') == ci['runId'] and identity.get('head_branch') == 'jms' and
            identity.get('head_sha') == ci['sourceCommit'], 'Original artifact metadata differs or expired')
    archive_path = expected / 'original-actions-artifact.zip'
    with archive_path.open('xb') as output:
        result = subprocess.run([gh, 'api', prefix + 'artifacts/' + str(ci['artifactId']) + '/zip'],
            env=environment, stdout=output, stderr=subprocess.DEVNULL, timeout=1200)
    require(result.returncode == 0 and archive_path.stat().st_size == ci['zipBytes'] and
            sha(archive_path) == ci['zipSHA256'], 'Original ZIP size/digest differs')
    with zipfile.ZipFile(archive_path) as archive:
        entries = archive.infolist()
        names = [item.filename for item in entries]
        require(len(entries) <= 2000 and len(names) == len(set(names)), 'Ambiguous original ZIP inventory')
        selected = {}
        for name, checksum in binding['selectedMetadata'].items():
            entry = archive.getinfo(name)
            require(entry.file_size <= 64 * 1024, 'Selected metadata exceeds its bound')
            data = archive.read(entry)
            require(hashlib.sha256(data).hexdigest() == checksum, 'Selected original metadata differs')
            selected[name] = json.loads(data)
        runner = selected['runner-source.json']
        receipt = selected['flatpak-verification.json']
        manifest = selected['flatpak-build-manifest.json']
        require(runner.get('SOURCE_COMMIT') == ci['sourceCommit'] and
                runner.get('GITHUB_RUN_ID') == str(ci['runId']), 'Original runner binding differs')
        require(receipt.get('applicationId') == 'com.jim608.jms' and receipt.get('architecture') == 'x86_64' and
                receipt.get('branch') == 'stable' and receipt.get('sourceCommit') == ci['sourceCommit'] and
                receipt.get('ostreeCommit') == runtime['ostreeCommit'] and receipt.get('runtime') == runtime['runtime'] and
                receipt.get('bundle') == {key: runtime[key] for key in ('name', 'size', 'sha256')} and
                receipt.get('payload', {}).get('sha256') == runtime['payloadSHA256'] and
                receipt.get('validation', {}).get('install') is True and receipt.get('validation', {}).get('launch') is True,
                'Accepted original installed-runtime receipt differs')
        require(manifest.get('sourceCommit', manifest.get('build', {}).get('sourceCommit')) == ci['sourceCommit'] and
                manifest.get('ostreeCommit') == runtime['ostreeCommit'] and manifest.get('runtime') == runtime['runtime'],
                'Original build manifest differs')
        payload = archive.getinfo(runtime['payloadName'])
        require(payload.file_size == runtime['payloadBytes'], 'Original payload size differs')
        with archive.open(payload) as stream:
            require(hashlib.file_digest(stream, 'sha256').hexdigest() == runtime['payloadSHA256'],
                    'Original payload digest differs')
        member = archive.getinfo(runtime['name'])
        require(member.file_size == runtime['size'], 'Original runtime size differs')
        destination = expected / 'baseline-unsigned.flatpak'
        with archive.open(member) as source, destination.open('xb') as output:
            shutil.copyfileobj(source, output)
        require(destination.stat().st_size == runtime['size'] and sha(destination) == runtime['sha256'],
                'Original runtime digest differs')
        destination.chmod(0o400)
    proof = {'binding': binding, 'authenticatedOwnActionsMetadataVerified': True,
             'exactOriginalZipAndSelectedRuntimeVerified': True, 'sourceOrNativeArchivesExtracted': False,
             'runtimeSignedOrPubliclyRepublished': False}
    (expected / 'private-fixture-proof.json').write_text(json.dumps(proof, indent=2) + '\n')
    print(json.dumps({'privateFixtureReady': True, 'runtimeSha256': runtime['sha256'],
                      'originalFullPublicGatePassed': False, 'oldBitsPubliclyPublished': False}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    try:
        main(parser.parse_args())
    except Exception:
        raise SystemExit('Private baseline read/verification failed; no artifact contents or token are logged.')
