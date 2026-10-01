"""Write-only receiver for consented, bounded JMS diagnostic events."""
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

API_PATH = '/api/jms/diagnostics/v1'
PLATFORMS = {'android', 'windows', 'linux', 'web', 'ios', 'macos'}
CATEGORIES = {'runtime_error': {'flutter_framework', 'unhandled_async'},
              'performance': {'slow_frames'}}
MAX_BODY = 4096


def validate_event(value):
    allowed = {'schemaVersion', 'event', 'platform', 'version', 'buildId',
               'sourceCommit', 'category', 'metrics'}
    required = {'schemaVersion', 'event', 'platform', 'version', 'buildId', 'category'}
    if not isinstance(value, dict) or not required <= value.keys() or value.keys() - allowed:
        raise ValueError('schema')
    if type(value['schemaVersion']) is not int or value['schemaVersion'] != 1:
        raise ValueError('schema')
    if value['event'] not in CATEGORIES or value['platform'] not in PLATFORMS:
        raise ValueError('category')
    if value['category'] not in CATEGORIES[value['event']]:
        raise ValueError('category')
    if not isinstance(value['version'], str) or not re.fullmatch(r'\d+\.\d+\.\d+-jms\.\d+', value['version']):
        raise ValueError('version')
    if not isinstance(value['buildId'], str) or not re.fullmatch(
            r'JMS-' + re.escape(value['version']) + r'(?:-(?:android|windows|linux|web))?-[a-f0-9]{12,64}', value['buildId']):
        raise ValueError('build')
    if 'sourceCommit' in value and (not isinstance(value['sourceCommit'], str) or
                                 not re.fullmatch('[a-f0-9]{40}', value['sourceCommit'])):
        raise ValueError('source')
    if value['event'] == 'runtime_error':
        if 'metrics' in value:
            raise ValueError('metrics')
    else:
        metrics = value.get('metrics')
        if not isinstance(metrics, dict) or set(metrics) != {
                'frameCount', 'slowFrameCount', 'worstFrameMs', 'totalDurationMs'}:
            raise ValueError('metrics')
        for name in ('frameCount', 'slowFrameCount'):
            if type(metrics[name]) is not int or not 0 <= metrics[name] <= 100000:
                raise ValueError('metrics')
        if not 1 <= metrics['slowFrameCount'] <= metrics['frameCount']:
            raise ValueError('metrics')
        for name in ('worstFrameMs', 'totalDurationMs'):
            if type(metrics[name]) not in (int, float) or not math.isfinite(metrics[name]) or not 0 <= metrics[name] <= 600000:
                raise ValueError('metrics')
    # Copy only the validated object; headers, remote addresses and logs are not stored.
    return json.loads(json.dumps(value, allow_nan=False))


class EventStore:
    def __init__(self, path, clock=time.time, max_rows=20000):
        self.clock, self.max_rows = clock, max_rows
        self.lock = threading.Lock()
        self.connection = sqlite3.connect(path, check_same_thread=False)
        self.connection.execute('CREATE TABLE IF NOT EXISTS events (id INTEGER PRIMARY KEY, received INTEGER NOT NULL, payload TEXT NOT NULL)')
        self.connection.execute('CREATE INDEX IF NOT EXISTS expiry ON events(received)')
        self.connection.commit()

    def add(self, event):
        with self.lock, self.connection:
            now = int(self.clock())
            self.connection.execute('DELETE FROM events WHERE received < ?', (now - 7 * 86400,))
            self.connection.execute('INSERT INTO events(received,payload) VALUES (?,?)',
                                    (now, json.dumps(event, separators=(',', ':'), allow_nan=False)))
            self.connection.execute('DELETE FROM events WHERE id <= COALESCE((SELECT id FROM events ORDER BY id DESC LIMIT 1 OFFSET ?), -1)',
                                    (self.max_rows,))

    def close(self):
        self.connection.close()


class Receiver(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, store, clock=time.monotonic, limit=120):
        self.store, self.clock, self.limit = store, clock, limit
        self.rate_lock = threading.Lock()
        self.window, self.count = clock(), 0
        self.slots = threading.BoundedSemaphore(16)
        super().__init__(address, Handler)

    def process_request(self, request, address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request, address):
        try:
            super().process_request_thread(request, address)
        finally:
            self.slots.release()

    def handle_error(self, request, address):
        # Do not print requests or arbitrary exception details.
        pass

    def accept_event(self):
        with self.rate_lock:
            now = self.clock()
            if now - self.window >= 60:
                self.window, self.count = now, 0
            self.count += 1
            return self.count <= self.limit


class Handler(BaseHTTPRequestHandler):
    server_version = 'JMS'
    sys_version = ''

    def setup(self):
        super().setup()
        self.connection.settimeout(3)

    def log_message(self, *_):
        pass

    def reply(self, status):
        self.send_response(status)
        self.send_header('Content-Length', '0')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Connection', 'close')
        self.end_headers()
        self.close_connection = True

    def do_GET(self):
        self.reply(204 if self.path == '/healthz' else 404)

    def do_POST(self):
        if self.path != API_PATH:
            self.reply(404)
            return
        if not self.server.accept_event():
            self.reply(429)
            return
        length_headers = self.headers.get_all('Content-Length', [])
        if len(length_headers) != 1 or self.headers.get('Transfer-Encoding'):
            self.reply(400)
            return
        if self.headers.get('Content-Type', '').split(';')[0].strip().lower() != 'application/json':
            self.reply(415)
            return
        try:
            length = int(length_headers[0])
            if not 0 < length <= MAX_BODY:
                self.reply(413)
                return
            raw = self.rfile.read(length)
            if len(raw) != length:
                raise ValueError('incomplete')
            event = validate_event(json.loads(raw))
        except (ValueError, TypeError, KeyError, UnicodeError, TimeoutError):
            self.reply(400)
            return
        try:
            self.server.store.add(event)
        except sqlite3.Error:
            self.reply(503)
            return
        self.reply(202)


def main():
    directory = Path(os.environ.get('JMS_DIAGNOSTICS_DATA', '/data'))
    directory.mkdir(parents=True, exist_ok=True)
    store = EventStore(directory / 'diagnostics.sqlite3')
    server = Receiver(('0.0.0.0', int(os.environ.get('PORT', '8080'))), store)
    try:
        server.serve_forever()
    finally:
        server.server_close()
        store.close()


if __name__ == '__main__':
    main()
