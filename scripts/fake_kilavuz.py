"""A stand-in for Kılavuz on the computer, for the CI smoke test: one analysed song, pairing key 'testkey'."""
import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.abspath(__file__))
SONG = json.load(open(os.path.join(ROOT, '..', 'Tests', 'Fixtures', 'test-song.json'), encoding='utf-8'))
MEDIA = {k: bytes((i * 7 + n) % 251 for i in range(300_000)) for n, k in enumerate(['full.mp3', 'backing.mp3', 'guitar.mp3'])}
LIST = [{k: SONG[k] for k in ('id', 'title', 'status', 'bpm', 'duration', 'lyr_status')}]


class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *a):
        sys.stderr.write('kilavuz-stub: ' + (a[0] % a[1:]) + '\n')

    def send(self, code, body, ctype='application/json', extra=()):
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.headers.get('Authorization') != 'Bearer testkey':
            return self.send(401, b'{"error": "key"}')
        p = self.path.split('?')[0]
        if p == '/api/ping':
            return self.send(200, b'{"ok": true, "app": "kilavuz", "version": 3}')
        if p == '/api/songs':
            return self.send(200, json.dumps(LIST).encode())
        if p == '/api/songs/test-song':
            return self.send(200, json.dumps(SONG, ensure_ascii=False).encode())
        m = re.match(r'^/media/test-song/(\w+\.mp3)$', p)
        if m and m.group(1) in MEDIA:
            return self.send(200, MEDIA[m.group(1)], 'audio/mpeg')
        if p == '/api/find':
            return self.send(200, b'{"mode": "catalog", "results": []}')
        self.send(404, b'{"error": "yok"}')


ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1]) if len(sys.argv) > 1 else 8765), H).serve_forever()
