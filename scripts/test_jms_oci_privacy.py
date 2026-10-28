"""OCI metadata is never an exemption for any image layer or deleted file."""
import gzip
import hashlib
import io
import json
import struct
import tarfile
import unittest

from check_jms_git_privacy import ArchiveScan


def digest(data):
    return hashlib.sha256(data).hexdigest()


def tar(members, *, trailing=b''):
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode='w', format=tarfile.PAX_FORMAT) as archive:
        for name, content in members:
            member = tarfile.TarInfo(name)
            member.size = len(content)
            archive.addfile(member, io.BytesIO(content))
    return stream.getvalue() + trailing


def image(layers, *, mutate=None, extra=(), compatibility=None):
    """Build a small complete Docker-save OCI layout with extensionless blobs."""
    blobs = {}
    def blob(data, media):
        path = 'blobs/sha256/' + digest(data)
        blobs[path] = data
        return {'mediaType': media, 'digest': 'sha256:' + digest(data), 'size': len(data)}
    configuration = {'config': {'User': 'fixture'}, 'architecture': 'amd64', 'os': 'linux'}
    config = blob(json.dumps(configuration).encode(), 'application/vnd.oci.image.config.v1+json')
    descriptors = [blob(content, media) for content, media in layers]
    manifest = {'schemaVersion': 2, 'mediaType': 'application/vnd.oci.image.manifest.v1+json',
                'config': config, 'layers': descriptors}
    if mutate:
        mutate(blobs, manifest)
    root = blob(json.dumps(manifest).encode(), 'application/vnd.oci.image.manifest.v1+json')
    index = {'schemaVersion': 2, 'mediaType': 'application/vnd.oci.image.index.v1+json', 'manifests': [root]}
    legacy = [{'Config': 'blobs/sha256/' + config['digest'][7:],
               'Layers': ['blobs/sha256/' + item['digest'][7:] for item in manifest['layers']]}]
    repositories = []
    if compatibility is not None:
        for position, layer in enumerate(descriptors):
            value = {'id': digest(('legacy-' + layer['digest']).encode()), 'created': '2026-01-01T00:00:00Z',
                     'container_config': {}, 'os': 'linux'}
            if position:
                value['parent'] = digest(('legacy-' + descriptors[position - 1]['digest']).encode())
            if position == len(descriptors) - 1:
                value.update(config={'User': 'fixture', 'AttachStdout': False}, architecture='amd64')
            compatibility(value)
            content = json.dumps(value).encode()
            blobs['blobs/sha256/' + digest(content)] = content
        legacy[0]['RepoTags'] = ['fixture:latest']
        repositories = [('repositories', json.dumps({'fixture': {'latest': descriptors[-1]['digest'][7:]}}).encode())]
    members = [('oci-layout', b'{"imageLayoutVersion":"1.0.0"}'),
               ('index.json', json.dumps(index).encode()),
               ('manifest.json', json.dumps(legacy).encode()), *blobs.items(), *repositories, *extra]
    return tar(members)


TAR = 'application/vnd.oci.image.layer.v1.tar'
GZIP = TAR + '+gzip'


class OciPrivacyTests(unittest.TestCase):
    def scan(self, data, **limits):
        scanner = ArchiveScan(['private.example.invalid'], reviews=[], **limits)
        results = scanner.scan('candidate.tar.gz', gzip.compress(data))
        scanner.finish()
        return scanner, [(name, reasons) for name, reasons in results if reasons]

    def test_uncompressed_and_gzip_extensionless_layers_are_fully_scanned(self):
        secret = b'https://private.example.invalid/api'
        plain = tar([('etc/public.txt', b'public'), ('etc/settings.txt', secret)])
        compressed = gzip.compress(tar([('app/settings.txt', secret)]))
        scanner, rejected = self.scan(image([(plain, TAR), (compressed, GZIP)]))
        self.assertGreater(scanner.members, 10)
        self.assertEqual(2, sum(name.endswith('/settings.txt') for name, _ in rejected))
        self.assertTrue(all('private domain' in reasons for name, reasons in rejected if name.endswith('/settings.txt')))

    def test_deleted_and_older_duplicate_layers_do_not_hide_private_bytes(self):
        old = tar([('app/settings.txt', b'https://private.example.invalid')])
        replacement = tar([('app/.wh.settings.txt', b''), ('app/public.txt', b'public')])
        _, rejected = self.scan(image([(old, TAR), (replacement, TAR), (old, TAR)]))
        # Repeated references share one physically stored, content-addressed
        # blob. It is still inspected even though a later layer deletes it.
        self.assertEqual(1, sum(name.endswith('/app/settings.txt') for name, _ in rejected))

    def test_every_layer_file_and_exact_member_context_is_retained(self):
        first = tar([('first.txt', b'first'), ('other.txt', b'other')])
        second = tar([('second.txt', b'second')])
        scanner = ArchiveScan([], reviews=[])
        results = scanner.scan('candidate.tar', image([(first, TAR), (second, TAR)]))
        expected = 'candidate.tar/blobs/sha256/' + digest(first) + '/first.txt'
        self.assertIn((expected, []), results)
        self.assertTrue(any(name.endswith('/other.txt') for name, _ in results))
        self.assertTrue(any(name.endswith('/second.txt') for name, _ in results))
        self.assertFalse(any(reasons for _, reasons in results))

    def test_missing_changed_and_size_mismatched_blobs_fail_closed(self):
        layer = tar([('public.txt', b'public')])
        def missing(blobs, manifest):
            blobs.pop('blobs/sha256/' + manifest['layers'][0]['digest'][7:])
        def changed(blobs, manifest):
            path = 'blobs/sha256/' + manifest['layers'][0]['digest'][7:]
            blobs[path] = b'X' + blobs[path][1:]
        def size(blobs, manifest):
            manifest['layers'][0]['size'] += 1
        for mutation in (missing, changed, size):
            with self.subTest(mutation=mutation.__name__), self.assertRaisesRegex(ValueError, 'OCI blob|descriptor size'):
                self.scan(image([(layer, TAR)], mutate=mutation))

    def test_unreferenced_and_unsupported_blobs_fail_closed(self):
        layer = tar([('public.txt', b'public')])
        def unused(blobs, manifest):
            value = gzip.compress(tar([('private.txt', b'https://private.example.invalid')]))
            blobs['blobs/sha256/' + digest(value)] = value
        with self.assertRaisesRegex(ValueError, 'Unreferenced'):
            self.scan(image([(layer, TAR)], mutate=unused))
        with self.assertRaisesRegex(ValueError, 'Unsupported OCI blob media type'):
            self.scan(image([(layer, 'application/vnd.unreviewed.binary')]))

    def test_legacy_config_chain_is_verified_and_every_raw_json_byte_scanned(self):
        layers = [(tar([('first.txt', b'first')]), TAR), (tar([('last.txt', b'last')]), TAR)]
        _, rejected = self.scan(image(layers, compatibility=lambda value: None))
        self.assertFalse(rejected)
        def private(value):
            value['container_config'] = {'Cmd': ['https://private.example.invalid']}
        _, rejected = self.scan(image(layers, compatibility=private))
        self.assertTrue(any('private domain' in reasons for _, reasons in rejected))
        def unrelated(value):
            value['unexpected'] = 'unsupported opaque field'
        def wrong_parent(value):
            value['parent'] = 'f' * 64
        def runtime_changed(value):
            if 'config' in value:
                value['config']['User'] = 'different'
        for mutation in (unrelated, wrong_parent, runtime_changed):
            with self.subTest(mutation=mutation.__name__), self.assertRaisesRegex(ValueError, 'compatibility'):
                self.scan(image(layers, compatibility=mutation))

    def test_unsafe_and_duplicate_archive_or_layer_names_fail_closed(self):
        for members in ([('../escape.txt', b'public')], [('/absolute.txt', b'public')],
                        [('same.txt', b'a'), ('same.txt', b'b')]):
            with self.subTest(members=members), self.assertRaisesRegex(ValueError, 'Unsafe OCI|Duplicate'):
                self.scan(image([(tar(members), TAR)]))
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            self.scan(image([(tar([('public.txt', b'public')]), TAR)],
                            extra=[('oci-layout', b'{"imageLayoutVersion":"1.0.0"}')]))

    def test_invalid_layer_media_or_truncation_cannot_fall_back_to_opaque_bytes(self):
        for content, media in ((b'not a tar', TAR), (b'not gzip', GZIP),
                               (tar([('public.txt', b'public')])[:600], TAR)):
            with self.subTest(media=media), self.assertRaises((ValueError, tarfile.TarError, OSError, EOFError)):
                self.scan(image([(content, media)]))

    def test_indices_cannot_reference_config_or_layer_descriptors_as_images(self):
        for media, content in (('application/vnd.oci.image.config.v1+json', b'{}'),
                               (TAR, tar([('public.txt', b'public')]))):
            for nested in (False, True):
                descriptor = {'mediaType': media, 'digest': 'sha256:' + digest(content), 'size': len(content)}
                blobs = [('blobs/sha256/' + digest(content), content)]
                if nested:
                    inner = json.dumps({'schemaVersion': 2, 'manifests': [descriptor]}).encode()
                    descriptor = {'mediaType': 'application/vnd.oci.image.index.v1+json',
                                  'digest': 'sha256:' + digest(inner), 'size': len(inner)}
                    blobs.append(('blobs/sha256/' + digest(inner), inner))
                data = tar([('oci-layout', b'{"imageLayoutVersion":"1.0.0"}'),
                            ('index.json', json.dumps({'schemaVersion': 2, 'manifests': [descriptor]}).encode()), *blobs])
                with self.subTest(media=media, nested=nested), self.assertRaisesRegex(ValueError, 'nonimage'):
                    self.scan(data)

    def test_layer_header_comments_and_trailing_bytes_remain_inspected(self):
        layer = tar([('public.txt', b'public')], trailing=b'https://private.example.invalid')
        _, rejected = self.scan(image([(layer, TAR)]))
        self.assertTrue(any(name.endswith('/' + digest(layer)) and 'private domain' in reasons for name, reasons in rejected))
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode='w', format=tarfile.PAX_FORMAT) as archive:
            member = tarfile.TarInfo('public.txt')
            member.pax_headers = {'comment': 'https://private.example.invalid'}
            member.size = 6
            archive.addfile(member, io.BytesIO(b'public'))
        _, rejected = self.scan(image([(stream.getvalue(), TAR)]))
        self.assertTrue(any(name.endswith('/' + digest(stream.getvalue())) and 'private domain' in reasons for name, reasons in rejected))

    def test_compressed_copy_wrapper_metadata_cannot_hide_private_bytes(self):
        layer = tar([('public.txt', b'public')])
        encoded = gzip.compress(layer)
        private = b'https://private.example.invalid'
        for flag, annotation in ((4, struct.pack('<H', len(private)) + private),
                                 (8, private + b'\0'), (16, private + b'\0')):
            header = bytearray(encoded[:10])
            header[3] = flag
            annotated = bytes(header) + annotation + encoded[10:]
            with self.subTest(gzip_flag=flag):
                _, rejected = self.scan(image([(annotated, GZIP)]))
                self.assertTrue(any(name.endswith('/' + digest(annotated)) and 'private domain' in reasons
                                    for name, reasons in rejected))
        import zstandard
        # A valid skippable frame changes no decoded layer bytes, but its raw
        # content remains part of the distributed archive and must be inspected.
        skippable = b'\x50\x2a\x4d\x18' + struct.pack('<I', len(private)) + private
        annotated = zstandard.ZstdCompressor().compress(layer) + skippable
        # OCI zstd layers are rejected until a complete frame-integrity decoder
        # is available; stream_reader alone can accept truncated checksums.
        for content in (annotated, zstandard.ZstdCompressor(write_checksum=True).compress(layer)[:-1]):
            with self.assertRaisesRegex(ValueError, 'Unsupported OCI blob media type'):
                self.scan(image([(content, TAR + '+zstd')]))

    def test_aggregate_member_depth_and_decompression_limits_still_apply(self):
        data = image([(gzip.compress(tar([('payload.txt', b'x' * 50000)])), GZIP)])
        for limits in ({'max_members': 3}, {'max_depth': 1}, {'max_bytes': 15000}):
            with self.subTest(limits=limits), self.assertRaisesRegex(ValueError, 'limit'):
                self.scan(data, **limits)


if __name__ == '__main__':
    unittest.main()
