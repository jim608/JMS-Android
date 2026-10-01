import http.client
import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import unittest

spec = importlib.util.spec_from_file_location('diagnostics_receiver', Path(__file__).resolve().parents[1] / 'server/diagnostics_receiver.py')
receiver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(receiver)


def event():
    return dict(schemaVersion=1, event='runtime_error', platform='android',
                version='0.11.1-jms.25', buildId='JMS-0.11.1-jms.25-0123456789ab',
                category='flutter_framework')


class ReceiverTests(unittest.TestCase):
    def test_only_bounded_known_fields(self):
        self.assertEqual(receiver.validate_event(event()), event())
        for name in ('message', 'stack', 'cookie', 'token', 'url', 'account'):
            with self.assertRaises(ValueError):
                receiver.validate_event(dict(event(), **{name: 'synthetic-private.invalid'}))
        for name, value in [('buildId', 'private'), ('platform', 'unknown'), ('sourceCommit', 'invalid'), ('schemaVersion', True)]:
            with self.assertRaises(ValueError):
                receiver.validate_event(dict(event(), **{name: value}))
        performance = dict(event(), event='performance', category='slow_frames', metrics=dict(
            frameCount=600, slowFrameCount=40, worstFrameMs=70.5, totalDurationMs=10000))
        receiver.validate_event(performance)
        for name, value in [('frameCount', True), ('worstFrameMs', float('nan')), ('slowFrameCount', 601), ('totalDurationMs', -1)]:
            with self.assertRaises(ValueError):
                receiver.validate_event(dict(performance, metrics=dict(performance['metrics'], **{name: value})))

    def test_http_receives_without_credentials_and_has_no_read_api(self):
        with tempfile.TemporaryDirectory() as directory:
            store = receiver.EventStore(Path(directory) / 'events.db')
            server = receiver.Receiver(('127.0.0.1', 0), store, limit=3)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                def request(method, path, value=None, headers=None):
                    connection = http.client.HTTPConnection(*server.server_address, timeout=3)
                    body = json.dumps(value) if value is not None else None
                    connection.request(method, path, body, headers or {'Content-Type': 'application/json'})
                    response = connection.getresponse()
                    status = response.status
                    response.read()
                    connection.close()
                    return status
                self.assertEqual(request('GET', '/healthz'), 204)
                self.assertEqual(request('POST', receiver.API_PATH, event()), 202)
                self.assertEqual(request('POST', receiver.API_PATH, dict(event(), token='synthetic-secret')), 400)
                self.assertEqual(request('POST', receiver.API_PATH, event(), {'Content-Type': 'text/plain'}), 415)
                self.assertEqual(request('POST', receiver.API_PATH, event()), 429)
                self.assertEqual(request('GET', receiver.API_PATH), 404)
                self.assertEqual(store.connection.execute('SELECT COUNT(*) FROM events').fetchone()[0], 1)
                self.assertNotIn('synthetic-secret', store.connection.execute('SELECT payload FROM events').fetchone()[0])
            finally:
                server.shutdown()
                server.server_close()
                thread.join()
                store.close()

    def test_storage_retention_and_row_limit(self):
        with tempfile.TemporaryDirectory() as directory:
            now = [1000000]
            store = receiver.EventStore(Path(directory) / 'events.db', clock=lambda: now[0], max_rows=2)
            try:
                for _ in range(4):
                    store.add(event())
                self.assertEqual(store.connection.execute('SELECT COUNT(*) FROM events').fetchone()[0], 2)
                now[0] += 8 * 86400
                store.add(event())
                self.assertEqual(store.connection.execute('SELECT COUNT(*) FROM events').fetchone()[0], 1)
            finally:
                store.close()
