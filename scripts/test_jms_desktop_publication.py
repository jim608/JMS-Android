import unittest
import hashlib
import io
import json
import tarfile
import tempfile
import zipfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
from jms_publication import Github, ReleaseError, allowed_url
import jms_desktop_publication as desktop
from jms_desktop_publication import release_tag, resume_publication_state
from jms_release_notes import release_body_for_candidate


class DesktopPublicationTests(unittest.TestCase):
    def test_repository_scope_is_exact(self):
        for repository in ('jim608/JMS-Desktop', 'jim608/JMS-Linux', 'jim608/JMS-Web'):
            github = Github(repository=repository)
            with patch.object(github, 'call', return_value=b'{}') as call:
                github.api('repos/' + repository + '/releases')
                call.assert_called_once()
                with self.assertRaises(ReleaseError):
                    github.api('repos/jim608/JMS-Android/releases')
            self.assertTrue(allowed_url(
                'https://github.com/' + repository + '/releases/download/v20/asset.zip',
                repository=repository))
            self.assertFalse(allowed_url(
                'https://github.com/jim608/JMS-Android/releases/download/v20/asset.zip',
                repository=repository))

    def test_other_repository_is_rejected(self):
        with self.assertRaises(ReleaseError):
            Github(repository='DonutWare/Fladder')

    def test_release_tag_defaults_or_matches_exact_full_application_version(self):
        record = {'versionName': '0.11.1-jms.25', 'versionCode': 27}
        self.assertEqual(release_tag(record), 'v0.11.1-jms.25')
        self.assertEqual(release_tag(dict(record, releaseTag='v0.11.1-jms.25')), 'v0.11.1-jms.25')
        self.assertEqual(release_tag(dict(record, releaseTag='v0.11.1-jms.25+27')), 'v0.11.1-jms.25+27')
        for tag in ('v0.11.1-jms.25+28', 'v0.11.1-jms.26+27', 'v0.11.1-jms.25-publication.1',
                    'v0.11.1-jms.25+027', 'v0.11.1-jms.25+27/other', '', None, 27):
            with self.subTest(tag=tag), self.assertRaises(ReleaseError):
                release_tag(dict(record, releaseTag=tag))

    def test_release_tag_rejects_invalid_version_identity(self):
        for code in (True, '27', 27.0, -1, None):
            with self.subTest(code=code), self.assertRaises(ReleaseError):
                release_tag({'versionName': '0.11.1-jms.25', 'versionCode': code})
        for version in ('', None, 25):
            with self.subTest(version=version), self.assertRaises(ReleaseError):
                release_tag({'versionName': version, 'versionCode': 27})

    def test_full_version_tag_drives_existing_tag_and_publication_state(self):
        record = {'repository': 'jim608/JMS-Desktop', 'sourceCommit': 'a' * 40,
                  'versionName': '0.11.1-jms.25', 'versionCode': 27,
                  'releaseTag': 'v0.11.1-jms.25+27'}
        release_commit = 'b' * 40
        calls = []
        def git(*arguments, **kwargs):
            calls.append(arguments)
            if arguments[:2] == ('ls-remote', 'https://github.com/jim608/JMS-Android.git'):
                return record['sourceCommit'] + '\trefs/heads/jms'
            if arguments == ('rev-parse', 'HEAD'):
                return release_commit
            if arguments == ('remote', 'get-url', 'origin'):
                return 'https://github.com/jim608/JMS-Desktop.git'
            if arguments[:2] == ('ls-remote', 'origin'):
                return release_commit + '\trefs/tags/' + record['releaseTag']
            return ''
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            checkout = root / 'artifacts/release-repositories/JMS-Desktop'
            (checkout / 'releases').mkdir(parents=True)
            (checkout / 'releases/0.11.1-jms.25.json').write_text(json.dumps(record), encoding='utf-8')
            (root / 'RELEASE_NOTES.md').write_text('synthetic release notes', encoding='utf-8')
            args = SimpleNamespace(artifact_directory=str(root), platform='windows', dry_run=False,
                                   channel='prerelease')
            with patch.object(desktop, 'ROOT', root), patch.object(desktop, 'git', side_effect=git), \
                    patch.object(desktop, 'validate_inventory', return_value=(record, {})) as validate, \
                    patch.object(desktop, 'Github') as github_type, \
                    patch.object(desktop.subprocess, 'run') as push, \
                    patch.object(desktop, 'upload_complete_release') as upload, \
                    patch('builtins.print'):
                github = github_type.return_value
                github.releases.return_value = [{'id': 7, 'tag_name': record['releaseTag']}]
                github.api.return_value = {'assets': [], 'html_url': 'synthetic release'}
                desktop.publish_desktop(args)
                validate.assert_called_once_with(root, 'windows')
                push.assert_not_called()
                planned = upload.call_args.args[1]
                self.assertEqual(planned['tag'], record['releaseTag'])
                self.assertEqual(planned['releaseCommit'], release_commit)
                self.assertEqual(planned['sourceCommit'], record['sourceCommit'])
                self.assertEqual(planned['version'], record['versionName'])
                def different_existing_tag(*arguments, **kwargs):
                    if arguments[:2] == ('ls-remote', 'origin'):
                        return 'c' * 40 + '\trefs/tags/' + record['releaseTag']
                    return git(*arguments, **kwargs)
                with patch.object(desktop, 'git', side_effect=different_existing_tag):
                    with self.assertRaisesRegex(ReleaseError, 'tag exists at another commit'):
                        desktop.publish_desktop(args)
                push.assert_not_called()
                self.assertEqual(upload.call_count, 1)
            self.assertIn(('ls-remote', 'origin', 'refs/tags/' + record['releaseTag']), calls)
            self.assertNotIn(('ls-remote', 'origin', 'refs/tags/v0.11.1-jms.25'), calls)
            saved = json.loads((root / 'publication-state.json').read_text(encoding='utf-8'))
            self.assertEqual(saved['tag'], record['releaseTag'])

    def test_interrupted_release_preserves_receipts_without_accepting_identity_drift(self):
        planned = {'releaseId': 7, 'tag': 'vfixture', 'version': 'fixture',
                   'notes': 'fixture notes', 'prerelease': True,
                   'sourceCommit': 'a' * 40, 'releaseCommit': 'b' * 40}
        saved = dict(planned, verifiedAssets={'test.zip': 'c' * 64}, published=True)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'publication-state.json'
            self.assertEqual(resume_publication_state(path, planned), planned)
            path.write_text(json.dumps(saved), encoding='utf-8')
            resumed = resume_publication_state(path, planned)
            self.assertEqual(resumed['verifiedAssets'], saved['verifiedAssets'])
            self.assertTrue(resumed['published'])
            for field in planned:
                changed = dict(planned, **{field: 'different'})
                with self.subTest(field=field), self.assertRaises(ReleaseError):
                    resume_publication_state(path, changed)


class FlatpakPublicationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.record = {
            'repository': 'jim608/JMS-Linux', 'platform': 'linux-x64', 'packageFormat': 'flatpak',
            'sourceRepository': 'jim608/JMS-Android', 'sourceCommit': 'a' * 40,
            'versionName': '0.11.1-jms.35', 'versionCode': 37,
            'buildId': 'JMS-0.11.1-jms.35-flatpak-' + 'a' * 12,
            'validation': {'install': True, 'launch': True},
            'canonicalNotes': '# JMS 0.11.1-jms.35\n\n## 新增\n- 提供 Linux Flatpak 套件。\n',
            'canonicalNotesCommit': 'a' * 40,
            'nativeReview': {'platform': 'linux-x64', 'missing': [],
                             'materials': ['native.tar.gz'], 'binaries': {},
                             'evidence': 'flatpak-native-sources.json'},
            'flatpak': {'bundle': 'JMS-Linux-0.11.1-jms.35-x86_64.flatpak',
                        'payload': 'installed-payload.tar.gz', 'receipt': 'flatpak-verification.json',
                        'buildManifest': 'flatpak-build-manifest.json', 'source': 'complete-source.zip',
                        'nativeSources': 'flatpak-native-sources.json',
                        'ci': {'runId': 100, 'artifactName': 'jms-flatpak-' + 'a' * 40}},
        }
        self.identity = {key: self.record[key] for key in
                         ('platform', 'packageFormat', 'versionName', 'versionCode', 'sourceCommit', 'buildId')}
        self.payload_members = {
            'metadata': b'[Application]\nname=com.jim608.jms\nruntime=org.gnome.Platform/x86_64/49\n',
            'files/share/jms/JMS_BUILD_INFO.json': json.dumps(self.identity).encode(),
            'files/lib/libflutter_linux_gtk.so': b'native fixture',
            'files/lib/libapp.so': self.record['buildId'].encode(),
        }
        for notice in desktop.FLATPAK_REQUIRED_LICENSES:
            self.payload_members['files/share/licenses/' + notice] = (b'GNU public license notice fixture\n' * 10)
        self.write_payload()
        self.record['nativeReview']['binaries'] = {'files/lib/libflutter_linux_gtk.so':
                                                 self.digest(b'native fixture'),
                                                 'files/lib/libapp.so': self.digest(self.record['buildId'].encode())}
        (self.directory / self.record['flatpak']['bundle']).write_bytes(b'flatpak static delta fixture')
        native = {'build': self.identity, 'sources': [{'module': 'fixture'}]}
        self.write_json('flatpak-native-sources.json', native)
        with tarfile.open(self.directory / 'native.tar.gz', 'w:gz') as archive:
            data = json.dumps(native).encode()
            member = tarfile.TarInfo('source-materials.json')
            member.size = len(data)
            archive.addfile(member, io.BytesIO(data))
        with zipfile.ZipFile(self.directory / 'complete-source.zip', 'w') as archive:
            archive.writestr('JMS/pubspec.yaml', 'version: 0.11.1-jms.35+37\n')
            archive.writestr('JMS/CHANGELOG.md', self.record['canonicalNotes'])
            archive.writestr('JMS/LICENSE', self.payload_members['files/share/licenses/jms/LICENSE'])
        self.receipt = dict(self.identity, schemaVersion=1, applicationId='com.jim608.jms',
                            architecture='x86_64', branch='stable', ostreeCommit='b' * 64,
                            runtime='org.gnome.Platform/x86_64/49',
                            validation={'install': True, 'launch': True},
                            members={name: self.digest(data) for name, data in self.payload_members.items()})
        for field in ('bundle', 'payload'):
            name = self.record['flatpak'][field]
            self.receipt[field] = self.asset(name)
        self.write_json('flatpak-verification.json', self.receipt)
        self.write_manifest()
        (self.directory / 'RELEASE_NOTES.md').write_text(release_body_for_candidate(
            self.record['canonicalNotes'], self.record['versionName'], self.record['sourceCommit'],
            self.record['buildId']), encoding='utf-8')
        self.refresh_assets()

    @staticmethod
    def digest(content):
        return hashlib.sha256(content).hexdigest()

    def write_json(self, name, value):
        (self.directory / name).write_text(json.dumps(value), encoding='utf-8')

    def write_manifest(self):
        self.write_json('flatpak-build-manifest.json', {
            'build': self.identity, 'runtime': self.receipt['runtime'],
            'ostreeCommit': self.receipt['ostreeCommit'],
            'binaries': self.record['nativeReview']['binaries'],
            'outputs': [self.receipt['bundle'], self.receipt['payload']]})

    def asset(self, name):
        path = self.directory / name
        return {'name': name, 'size': path.stat().st_size, 'sha256': self.digest(path.read_bytes())}

    def write_payload(self):
        with tarfile.open(self.directory / self.record['flatpak']['payload'], 'w:gz') as archive:
            for name, data in self.payload_members.items():
                member = tarfile.TarInfo(name)
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))

    def refresh_assets(self):
        names = sorted(path.name for path in self.directory.iterdir()
                       if path.name not in ('desktop-publication.json', 'SHA256SUMS.txt'))
        entries = [self.asset(name) for name in names]
        checksums = ''.join(entry['sha256'] + '  ' + entry['name'] + '\n' for entry in entries)
        (self.directory / 'SHA256SUMS.txt').write_text(checksums, encoding='ascii')
        self.record['assets'] = entries + [self.asset('SHA256SUMS.txt')]
        self.write_json('desktop-publication.json', self.record)
        return desktop.prepared_assets(self.directory, self.record)

    def validate(self):
        with patch.object(desktop, 'verify_flatpak_ci', return_value='c' * 64), \
                patch.object(desktop, 'verify_source_archive') as source, \
                patch.object(desktop, 'load_policy', return_value=['private.example.invalid']), \
                patch.object(desktop, 'git', return_value=str(self.directory / 'cache')):
            result = desktop.validate_inventory(self.directory, 'linux')
            source.assert_called_once_with(self.directory / 'complete-source.zip', 'a' * 40)
            return result

    def test_flatpak_only_uses_existing_linux_publisher_without_pacman_feed(self):
        record, files = self.validate()
        self.assertEqual(record['packageFormat'], 'flatpak')
        self.assertIn(record['flatpak']['bundle'], files)
        self.assertNotIn('update-linux.json', files)
        self.assertFalse(any(name.endswith('.pkg.tar.xz') for name in files))

    def test_flatpak_only_rejects_pacman_metadata_or_packages(self):
        for name in ('update-linux.json', 'installer.pkg.tar.xz', 'installer.pkg.tar.zst'):
            with self.subTest(name=name):
                path = self.directory / name
                path.write_bytes(b'forbidden pacman fixture')
                self.refresh_assets()
                with self.assertRaisesRegex(ReleaseError, 'must not supply pacman'):
                    self.validate()
                path.unlink()
                self.refresh_assets()

    def test_flatpak_native_materials_bind_every_bundled_library(self):
        self.record['nativeReview']['binaries'] = {}
        self.write_manifest()
        self.refresh_assets()
        with self.assertRaisesRegex(ReleaseError, 'native review differs'):
            self.validate()

    def test_flatpak_installed_payload_hash_and_member_inventory_are_required(self):
        self.payload_members['files/private-settings.txt'] = b'added fixture'
        self.write_payload()
        self.receipt['payload'] = self.asset(self.record['flatpak']['payload'])
        self.write_json('flatpak-verification.json', self.receipt)
        self.write_manifest()
        self.refresh_assets()
        with self.assertRaisesRegex(ReleaseError, 'member hashes differ'):
            self.validate()

    def test_flatpak_build_identity_cannot_be_substituted(self):
        self.receipt['buildId'] = 'another-build'
        self.write_json('flatpak-verification.json', self.receipt)
        self.refresh_assets()
        with self.assertRaisesRegex(ReleaseError, 'identity or runtime'):
            self.validate()

    def test_flatpak_receipt_and_build_manifest_must_bind_same_outputs(self):
        manifest = json.loads((self.directory / 'flatpak-build-manifest.json').read_text())
        manifest['ostreeCommit'] = 'd' * 64
        self.write_json('flatpak-build-manifest.json', manifest)
        self.refresh_assets()
        with self.assertRaisesRegex(ReleaseError, 'manifest outputs, runtime or native binaries'):
            self.validate()

    def test_flatpak_requires_regular_installed_license_files_for_bundled_components(self):
        name = 'files/share/licenses/mpv/LICENSE.GPL'
        del self.payload_members[name]
        self.write_payload()
        self.receipt['payload'] = self.asset(self.record['flatpak']['payload'])
        del self.receipt['members'][name]
        self.write_json('flatpak-verification.json', self.receipt)
        self.write_manifest()
        self.refresh_assets()
        with self.assertRaisesRegex(ReleaseError, 'license/notice is missing'):
            self.validate()

    def test_flatpak_cannot_substitute_jms_license_even_with_consistent_member_hashes(self):
        name = 'files/share/licenses/jms/LICENSE'
        self.payload_members[name] = b'another license fixture\n' * 10
        self.write_payload()
        self.receipt['payload'] = self.asset(self.record['flatpak']['payload'])
        self.receipt['members'][name] = self.digest(self.payload_members[name])
        self.write_json('flatpak-verification.json', self.receipt)
        self.write_manifest()
        self.refresh_assets()
        with self.assertRaisesRegex(ReleaseError, 'JMS license differs'):
            self.validate()

    def test_flatpak_build_info_does_not_replace_actual_aot_build_identity(self):
        self.payload_members['files/lib/libapp.so'] = b'another AOT build'
        self.write_payload()
        digest = self.digest(self.payload_members['files/lib/libapp.so'])
        self.receipt['payload'] = self.asset(self.record['flatpak']['payload'])
        self.receipt['members']['files/lib/libapp.so'] = digest
        self.record['nativeReview']['binaries']['files/lib/libapp.so'] = digest
        self.write_json('flatpak-verification.json', self.receipt)
        self.write_manifest()
        self.refresh_assets()
        with self.assertRaisesRegex(ReleaseError, 'AOT binary is not bound'):
            self.validate()

    def test_flatpak_compilation_does_not_replace_actual_install_and_launch(self):
        self.receipt['validation']['launch'] = False
        self.write_json('flatpak-verification.json', self.receipt)
        self.refresh_assets()
        with self.assertRaisesRegex(ReleaseError, 'runtime verification'):
            self.validate()

    def test_flatpak_private_deployment_content_rejected_after_valid_identity(self):
        name = 'files/settings.txt'
        self.payload_members[name] = b'https://private.example.invalid'
        self.write_payload()
        self.receipt['payload'] = self.asset(self.record['flatpak']['payload'])
        self.receipt['members'][name] = self.digest(self.payload_members[name])
        self.write_json('flatpak-verification.json', self.receipt)
        self.write_manifest()
        self.refresh_assets()
        with self.assertRaisesRegex(ReleaseError, 'privacy review required'):
            self.validate()

    def ci_fixture(self):
        repository = {'full_name': 'jim608/JMS-Android'}
        run = {'id': 100, 'status': 'completed', 'conclusion': 'success', 'head_branch': 'jms',
               'head_sha': self.record['flatpak']['ci'].get('verificationCommit', 'a' * 40),
               'path': desktop.FLATPAK_WORKFLOW, 'event': 'workflow_dispatch',
               'repository': repository, 'head_repository': repository}
        stream = io.BytesIO()
        flatpak = self.record['flatpak']
        with zipfile.ZipFile(stream, 'w') as archive:
            for name in [flatpak[field] for field in
                         ('bundle', 'payload', 'receipt', 'buildManifest', 'nativeSources', 'source')] + ['native.tar.gz']:
                archive.writestr(name, (self.directory / name).read_bytes())
            runner = {'SOURCE_COMMIT': self.record['sourceCommit'], 'VERSION': self.record['versionName'],
                      'BUILD_ID': self.record['buildId'], 'GITHUB_RUN_ID': '100'}
            if 'verificationCommit' in flatpak['ci']:
                runner['VERIFICATION_COMMIT'] = flatpak['ci']['verificationCommit']
            if 'nativeBuildRunId' in flatpak['ci']:
                runner['NATIVE_BUILD_RUN_ID'] = str(flatpak['ci']['nativeBuildRunId'])
                archive.writestr('native-build-origin.json', json.dumps(flatpak['ci']['nativeBuildOrigin']))
            archive.writestr('runner-source.json', json.dumps(runner))
        content = stream.getvalue()
        artifact = {'id': 200, 'name': flatpak['ci']['artifactName'], 'expired': False,
                    'size_in_bytes': len(content), 'digest': 'sha256:' + self.digest(content),
                    'workflow_run': {'id': 100, 'head_branch': 'jms', 'head_sha': run['head_sha']}}
        return run, artifact, content

    @staticmethod
    def ci_jobs(run_id, required, conclusion='success'):
        return {'total_count': 1, 'jobs': [{'name': 'flatpak', 'run_id': run_id,
                'status': 'completed', 'conclusion': conclusion,
                'steps': [{'name': name, 'status': 'completed', 'conclusion': 'success'} for name in required]}]}

    def verify_ci(self, run, artifact, content, jobs=None, parent=None, parent_jobs=None):
        def download(*args, **kwargs):
            data = parent[2] if parent and '/artifacts/201/zip' in args[0][-1] else content
            kwargs['stdout'].write(data)
            return SimpleNamespace(returncode=0)
        with patch.object(desktop, 'Github') as github_type, \
                patch.object(desktop.subprocess, 'run', side_effect=download):
            github = github_type.return_value
            github.executable = 'gh'
            github.environment = {}
            resumed = 'nativeBuildRunId' in self.record['flatpak']['ci']
            steps = desktop.FLATPAK_VERIFICATION_STEPS + (() if resumed else desktop.FLATPAK_BUILD_STEPS)
            github.api.side_effect = [run, jobs or self.ci_jobs(100, steps),
                                     {'total_count': 1, 'artifacts': [artifact]}] + (
                [parent[0], parent_jobs or self.ci_jobs(99, desktop.FLATPAK_BUILD_STEPS, 'failure'),
                 {'total_count': 1, 'artifacts': [parent[1]]}] if parent else [])
            return desktop.verify_flatpak_ci(self.record, self.refresh_assets())

    def resumed_ci_fixture(self):
        parent_run = {'id': 99, 'run_attempt': 1, 'status': 'completed', 'conclusion': 'failure',
                      'head_branch': 'jms', 'head_sha': 'a' * 40, 'path': desktop.FLATPAK_WORKFLOW,
                      'event': 'workflow_dispatch', 'repository': {'full_name': 'jim608/JMS-Android'},
                      'head_repository': {'full_name': 'jim608/JMS-Android'}}
        bundle = self.record['flatpak']['bundle']
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, 'w') as archive:
            archive.writestr('candidate/' + bundle, (self.directory / bundle).read_bytes())
        content = stream.getvalue()
        name = 'jms-flatpak-failure-' + 'a' * 40 + '-1'
        artifact = {'id': 201, 'name': name, 'expired': False, 'size_in_bytes': len(content),
                    'digest': 'sha256:' + self.digest(content),
                    'workflow_run': {'id': 99, 'head_branch': 'jms', 'head_sha': 'a' * 40}}
        origin = {'schemaVersion': 1, 'sourceCommit': 'a' * 40, 'buildId': self.record['buildId'],
                  'runId': 99, 'artifactId': 201, 'artifactName': name,
                  'artifactDigest': artifact['digest'], 'bundle': self.asset(bundle),
                  'bundleMember': 'candidate/' + bundle}
        self.record['flatpak']['ci'].update(verificationCommit='d' * 40,
                                            nativeBuildRunId=99, nativeBuildOrigin=origin)
        return parent_run, artifact, content

    def test_flatpak_ci_verifies_independently_downloaded_registered_artifact(self):
        run, artifact, content = self.ci_fixture()
        self.assertEqual(self.verify_ci(run, artifact, content), self.digest(content))

    def test_flatpak_ci_rejects_wrong_workflow_source_status_or_branch(self):
        run, artifact, content = self.ci_fixture()
        for key, value in (('head_sha', 'd' * 40), ('head_branch', 'main'), ('conclusion', 'failure'),
                           ('path', '.github/workflows/other.yml'), ('event', 'pull_request'),
                           ('head_repository', {'full_name': 'other/fork'})):
            with self.subTest(field=key), self.assertRaisesRegex(ReleaseError, 'pinned JMS build'):
                self.verify_ci(dict(run, **{key: value}), artifact, content)

    def test_flatpak_ci_rejects_expired_unhashed_or_misbound_artifact(self):
        run, artifact, content = self.ci_fixture()
        for key, value in (('expired', True), ('digest', ''), ('workflow_run', {'id': 101})):
            with self.subTest(field=key), self.assertRaisesRegex(ReleaseError, 'provenance is incomplete'):
                self.verify_ci(run, dict(artifact, **{key: value}), content)

    def test_flatpak_ci_rejects_changed_archive_or_candidate_bytes(self):
        run, artifact, content = self.ci_fixture()
        with self.assertRaisesRegex(ReleaseError, 'artifact digest differs'):
            self.verify_ci(run, artifact, content + b'changed')
        (self.directory / self.record['flatpak']['bundle']).write_bytes(b'substituted bundle')
        with self.assertRaisesRegex(ReleaseError, 'asset size differs|candidate differs'):
            self.verify_ci(run, artifact, content)

    def test_flatpak_resume_preserves_source_and_independently_verifies_parent_bundle(self):
        parent = self.resumed_ci_fixture()
        run, artifact, content = self.ci_fixture()
        with patch.object(desktop, 'verify_flatpak_verification_inputs') as inputs:
            self.assertEqual(self.verify_ci(run, artifact, content, parent=parent), self.digest(content))
            inputs.assert_called_once_with('a' * 40, 'd' * 40)
        self.assertEqual(self.record['sourceCommit'], 'a' * 40)
        self.assertTrue(self.record['buildId'].endswith('a' * 12))

    def test_flatpak_resume_rejects_self_declared_parent_origin_and_changed_binary(self):
        parent = self.resumed_ci_fixture()
        for field, value in (('head_sha', 'b' * 40), ('conclusion', 'success'),
                             ('head_repository', {'full_name': 'other/fork'})):
            run, artifact, content = self.ci_fixture()
            changed = (dict(parent[0], **{field: value}), parent[1], parent[2])
            with patch.object(desktop, 'verify_flatpak_verification_inputs'), self.subTest(field=field), \
                    self.assertRaisesRegex(ReleaseError, 'pinned JMS build'):
                self.verify_ci(run, artifact, content, parent=changed)
        run, artifact, content = self.ci_fixture()
        changed = (parent[0], parent[1], parent[2] + b'changed')
        with patch.object(desktop, 'verify_flatpak_verification_inputs'), \
                self.assertRaisesRegex(ReleaseError, 'artifact digest differs'):
            self.verify_ci(run, artifact, content, parent=changed)
        origin = self.record['flatpak']['ci']['nativeBuildOrigin']
        origin['bundle']['sha256'] = 'b' * 64
        run, artifact, content = self.ci_fixture()
        with patch.object(desktop, 'verify_flatpak_verification_inputs'), \
                self.assertRaisesRegex(ReleaseError, 'artifact binding differs'):
            self.verify_ci(run, artifact, content, parent=parent)

    def test_flatpak_resume_rejects_successful_parent_archive_with_a_different_bundle(self):
        parent_run, parent_artifact, _ = self.resumed_ci_fixture()
        stream = io.BytesIO()
        bundle = self.record['flatpak']['bundle']
        original = (self.directory / bundle).read_bytes()
        with zipfile.ZipFile(stream, 'w') as archive:
            archive.writestr('candidate/' + bundle, bytes([original[0] ^ 1]) + original[1:])
        parent_content = stream.getvalue()
        parent_artifact.update(size_in_bytes=len(parent_content), digest='sha256:' + self.digest(parent_content))
        self.record['flatpak']['ci']['nativeBuildOrigin']['artifactDigest'] = parent_artifact['digest']
        run, artifact, content = self.ci_fixture()
        with patch.object(desktop, 'verify_flatpak_verification_inputs'), \
                self.assertRaisesRegex(ReleaseError, 'differs from original native build bundle'):
            self.verify_ci(run, artifact, content, parent=(parent_run, parent_artifact, parent_content))

    def test_flatpak_resume_requires_original_native_build_steps_to_succeed(self):
        parent = self.resumed_ci_fixture()
        run, artifact, content = self.ci_fixture()
        jobs = self.ci_jobs(99, desktop.FLATPAK_BUILD_STEPS, 'failure')
        jobs['jobs'][0]['steps'][-1]['conclusion'] = 'failure'
        with patch.object(desktop, 'verify_flatpak_verification_inputs'), \
                self.assertRaisesRegex(ReleaseError, 'required step did not succeed'):
            self.verify_ci(run, artifact, content, parent=parent, parent_jobs=jobs)

    def test_flatpak_ci_requires_runtime_and_source_collection_steps_to_succeed(self):
        run, artifact, content = self.ci_fixture()
        for required in desktop.FLATPAK_VERIFICATION_STEPS:
            jobs = self.ci_jobs(100, desktop.FLATPAK_VERIFICATION_STEPS + desktop.FLATPAK_BUILD_STEPS)
            next(step for step in jobs['jobs'][0]['steps'] if step['name'] == required)['conclusion'] = 'skipped'
            with self.subTest(step=required), self.assertRaisesRegex(ReleaseError, 'required step did not succeed'):
                self.verify_ci(run, artifact, content, jobs=jobs)

    def test_flatpak_resume_cannot_omit_parent_or_rebind_runner_source(self):
        self.record['flatpak']['ci']['verificationCommit'] = 'd' * 40
        run, artifact, content = self.ci_fixture()
        with self.assertRaisesRegex(ReleaseError, 'Invalid Flatpak CI identity'):
            self.verify_ci(run, artifact, content)
        self.record['flatpak']['ci'].pop('verificationCommit')
        run, artifact, content = self.ci_fixture()
        stream = io.BytesIO()
        with zipfile.ZipFile(io.BytesIO(content)) as old, zipfile.ZipFile(stream, 'w') as new:
            for name in old.namelist():
                data = old.read(name)
                if name == 'runner-source.json':
                    runner = json.loads(data)
                    runner['SOURCE_COMMIT'] = 'b' * 40
                    data = json.dumps(runner).encode()
                new.writestr(name, data)
        content = stream.getvalue()
        artifact.update(size_in_bytes=len(content), digest='sha256:' + self.digest(content))
        with self.assertRaisesRegex(ReleaseError, 'runner source/verification identity differs'):
            self.verify_ci(run, artifact, content)


class FlatpakVerificationCommitTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.command('init', '--quiet')
        self.command('config', 'user.name', 'fixture')
        self.command('config', 'user.email', 'fixture@users.noreply.github.com')
        self.inputs = ['Dockerfile.linux', 'pubspec.lock', '.fvmrc', 'lib/main.dart',
                       'linux/CMakeLists.txt', 'flatpak/jms-flatpak', 'LICENSE', '.dockerignore']
        for name in self.inputs:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('original input\n')
        self.command('add', '--', *self.inputs)
        self.command('commit', '--quiet', '-m', 'source')
        self.source = self.command('rev-parse', 'HEAD')
        (self.root / 'verification.py').write_text('verification tool\n')
        self.command('add', '--', 'verification.py')
        self.command('commit', '--quiet', '-m', 'verification')
        self.verification = self.command('rev-parse', 'HEAD')

    def command(self, *arguments):
        return desktop.subprocess.check_output(['git', *arguments], cwd=self.root,
                                                stderr=desktop.subprocess.PIPE).decode().strip()

    def test_later_verification_tools_preserve_original_app_inputs(self):
        with patch.object(desktop, 'ROOT', self.root):
            desktop.verify_flatpak_verification_inputs(self.source, self.verification)

    def test_changed_app_native_recipe_license_or_toolchain_input_is_rejected(self):
        for name in self.inputs:
            self.command('checkout', '--quiet', '--detach', self.verification)
            (self.root / name).write_text('changed input\n')
            self.command('add', '--', name)
            self.command('commit', '--quiet', '-m', 'changed input')
            changed = self.command('rev-parse', 'HEAD')
            with self.subTest(path=name), patch.object(desktop, 'ROOT', self.root), \
                    self.assertRaisesRegex(ReleaseError, 'changes candidate build inputs'):
                desktop.verify_flatpak_verification_inputs(self.source, changed)

    def test_unrelated_verification_commit_is_rejected_even_with_identical_tree(self):
        tree = self.command('rev-parse', self.verification + '^{tree}')
        unrelated = self.command('commit-tree', tree, '-m', 'unrelated verification')
        with patch.object(desktop, 'ROOT', self.root), \
                self.assertRaisesRegex(ReleaseError, 'not descended'):
            desktop.verify_flatpak_verification_inputs(self.source, unrelated)


if __name__ == '__main__':
    unittest.main()
