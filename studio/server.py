"""Tour Studio: a private service that turns spot captures from the iPhone app into 360° tours
and shows them. One process, standard library only; the stitching itself runs
`processing/tour_worker.py --reconstruct-spots` in a child process.

Run behind an authenticating proxy or a private network. The service has no login of its own.
"""
import html
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote

REPO = Path(__file__).resolve().parent.parent
WORKER = REPO / 'processing' / 'tour_worker.py'
SITE = REPO / 'studio-dist'
CAPTURE_LIMIT = 96 * 1024 * 1024
PROCESS_TIMEOUT = 15 * 60
PROPERTY_ID = r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
ROUTES = [(method, re.compile(pattern), name) for method, pattern, name in [
    ('GET', r'/health', 'health'),
    ('GET', r'/', 'index'),
    ('GET', r'/tour/(%s)' % PROPERTY_ID, 'viewer'),
    ('GET', r'/assets/([A-Za-z0-9._-]+)', 'asset'),
    ('GET', r'/api/properties', 'list'),
    ('GET', r'/api/properties/(%s)' % PROPERTY_ID, 'detail'),
    ('POST', r'/api/properties/(%s)/capture' % PROPERTY_ID, 'upload'),
    ('POST', r'/api/properties/(%s)/reprocess' % PROPERTY_ID, 'reprocess'),
    ('DELETE', r'/api/properties/(%s)' % PROPERTY_ID, 'delete'),
    ('GET', r'/api/listings/(%s)/tours/tour/panorama/(\d{1,2})' % PROPERTY_ID, 'panorama'),
]]
ASSET_TYPES = {'.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml',
               '.wasm': 'application/wasm', '.map': 'application/json'}


class Studio:
    """Properties on disk, and the one-at-a-time processing queue."""

    def __init__(self, data, python=sys.executable):
        self.root = Path(data) / 'properties'
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.python = python
        self.lock = threading.Lock()  # guards meta.json writes
        self.work = threading.Semaphore(1)  # one stitch at a time
        # A stitch that was running when the service stopped will never finish.
        for meta in self.all():
            if meta['status'] == 'processing':
                self.update(meta['id'], status='failed', error='interrupted')

    def folder(self, property_id):
        return self.root / property_id

    def read(self, property_id):
        try:
            return json.loads((self.folder(property_id) / 'meta.json').read_text())
        except (OSError, ValueError):
            return None

    def update(self, property_id, **changes):
        with self.lock:
            meta = self.read(property_id) or {'id': property_id}
            meta.update(changes)
            target = self.folder(property_id) / 'meta.json'
            scratch = target.with_suffix('.tmp')
            scratch.write_text(json.dumps(meta))
            scratch.replace(target)
            return meta

    def all(self):
        found = [self.read(p.name) for p in self.root.iterdir() if p.is_dir()]
        return sorted((m for m in found if m), key=lambda m: m.get('createdAt', ''), reverse=True)

    def describe(self, meta):
        """What the app and the viewer page see. `tour` matches the web app's RoomTour."""
        result = None
        if meta['status'] == 'ready':
            try:
                result = json.loads((self.folder(meta['id']) / 'out' / 'result' / 'display.json').read_text())
            except (OSError, ValueError):
                result = None
        tour = result and {
            'id': 'tour', 'listingId': meta['id'], 'name': meta['name'], 'status': 'ready',
            'kind': 'spots', 'published': False, 'createdAt': meta['createdAt'], 'result': result,
            'mesh': None, 'error': None}
        return {'id': meta['id'], 'name': meta['name'], 'status': meta['status'],
                'error': meta.get('error'), 'createdAt': meta['createdAt'],
                'spots': len(result['spots']) if result else 0,
                'seconds': meta.get('seconds'), 'tour': tour}

    def accept(self, property_id, name, stream, length):
        """Stores an uploaded capture and starts stitching it."""
        folder = self.folder(property_id)
        folder.mkdir(mode=0o700, exist_ok=True)
        scratch = folder / 'capture.part'
        with open(scratch, 'wb') as out:
            left = length
            while left:
                chunk = stream.read(min(left, 1 << 20))
                if not chunk:
                    scratch.unlink(missing_ok=True)
                    raise ValueError('incomplete upload')
                out.write(chunk)
                left -= len(chunk)
        scratch.replace(folder / 'capture.roomcapture')
        created = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
        self.update(property_id, name=name, createdAt=created)
        self.start(property_id)

    def start(self, property_id):
        self.update(property_id, status='processing', error=None, seconds=None)
        threading.Thread(target=self.process, args=(property_id,), daemon=True).start()

    def process(self, property_id):
        folder = self.folder(property_id)
        with self.work:
            started = time.monotonic()
            shutil.rmtree(folder / 'out', ignore_errors=True)
            error = None
            try:
                run = subprocess.run(
                    [self.python, str(WORKER), '--reconstruct-spots',
                     str(folder / 'capture.roomcapture'), str(folder / 'out')],
                    cwd=str(REPO), capture_output=True, text=True, timeout=PROCESS_TIMEOUT)
                (folder / 'process.log').write_text(run.stdout[-20000:] + run.stderr[-20000:])
                if run.returncode:
                    code = folder / 'out' / 'error_code'
                    error = code.read_text().strip() if code.exists() else 'processing_failed'
            except subprocess.TimeoutExpired:
                error = 'timeout'
            except OSError:
                error = 'processing_failed'
            if folder.exists():
                self.update(property_id, status='failed' if error else 'ready', error=error,
                            seconds=round(time.monotonic() - started, 1))

    def remove(self, property_id):
        shutil.rmtree(self.folder(property_id), ignore_errors=True)


def index_page(studio):
    rows = []
    for meta in studio.all():
        d = studio.describe(meta)
        label = {'ready': '%d spots' % d['spots'], 'processing': 'Stitching…'}.get(
            d['status'], 'Failed: %s' % html.escape(str(d['error'])))
        name = html.escape(d['name'])
        link = '<a href="/tour/%s">%s</a>' % (d['id'], name) if d['status'] == 'ready' else name
        rows.append('<li>%s <span>%s · %s</span></li>' % (link, label, html.escape(d['createdAt'][:10])))
    body = '<ul>%s</ul>' % ''.join(rows) if rows else '<p>No properties yet. Capture one in the iPhone app.</p>'
    return ('<!doctype html><html lang="en"><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width, initial-scale=1">'
            '<title>Tour Studio</title><style>body{font:16px system-ui;margin:2rem auto;max-width:40rem;'
            'padding:0 1rem}li{margin:.6rem 0}span{color:#666;margin-left:.5rem}</style>'
            '<h1>Tour Studio</h1>%s</html>' % body)


def handler(studio):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'

        def log_message(self, format, *args):
            sys.stderr.write('%s %s\n' % (self.command, self.path.split('?')[0]))

        def reply(self, status, body=b'', kind='application/json', cache='no-store'):
            if isinstance(body, (dict, list)):
                body = json.dumps(body).encode()
            elif isinstance(body, str):
                body = body.encode()
            self.send_response(status)
            self.send_header('Content-Type', kind)
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', cache)
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.end_headers()
            if self.command != 'HEAD':
                self.wfile.write(body)

        def fail(self, status, code):
            self.close_connection = True
            self.reply(status, {'error': code})

        def dispatch(self):
            path = self.path.split('?')[0]
            for method, pattern, name in ROUTES:
                match = pattern.fullmatch(path)
                if match and method == self.command:
                    # Browsers cannot add this header to a cross-site form post.
                    if method != 'GET' and self.headers.get('X-Cuse-Studio') != '1':
                        return self.fail(403, 'missing_header')
                    return getattr(self, 'do_' + name)(*match.groups())
            self.fail(404, 'not_found')

        do_GET = do_POST = do_DELETE = dispatch

        def do_health(self):
            self.reply(200, {'ok': True})

        def do_index(self):
            self.reply(200, index_page(studio), 'text/html; charset=utf-8')

        def do_viewer(self, property_id):
            page = SITE / 'studio.html'
            if not page.exists():
                return self.fail(503, 'viewer_not_built')
            self.reply(200, page.read_bytes(), 'text/html; charset=utf-8')

        def do_asset(self, name):
            target = SITE / 'assets' / name
            if not target.is_file():
                return self.fail(404, 'not_found')
            kind = ASSET_TYPES.get(target.suffix, 'application/octet-stream')
            self.reply(200, target.read_bytes(), kind, 'public, max-age=31536000, immutable')

        def do_list(self):
            self.reply(200, {'properties': [studio.describe(m) for m in studio.all()]})

        def do_detail(self, property_id):
            meta = studio.read(property_id)
            if not meta:
                return self.fail(404, 'not_found')
            self.reply(200, studio.describe(meta))

        def do_upload(self, property_id):
            try:
                length = int(self.headers.get('Content-Length', ''))
            except ValueError:
                return self.fail(411, 'length_required')
            if not 0 < length <= CAPTURE_LIMIT:
                return self.fail(413, 'capture_too_large')
            name = unquote(self.headers.get('X-Property-Name', '')).strip()[:80] or 'Untitled property'
            meta = studio.read(property_id)
            if meta and meta['status'] == 'processing':
                return self.fail(409, 'already_processing')
            try:
                studio.accept(property_id, name, self.rfile, length)
            except ValueError:
                return self.fail(400, 'incomplete_upload')
            self.reply(202, studio.describe(studio.read(property_id)))

        def do_reprocess(self, property_id):
            meta = studio.read(property_id)
            if not meta or not (studio.folder(property_id) / 'capture.roomcapture').exists():
                return self.fail(404, 'not_found')
            if meta['status'] == 'processing':
                return self.fail(409, 'already_processing')
            studio.start(property_id)
            self.reply(202, studio.describe(studio.read(property_id)))

        def do_delete(self, property_id):
            meta = studio.read(property_id)
            if meta and meta['status'] == 'processing':
                return self.fail(409, 'already_processing')
            studio.remove(property_id)
            self.reply(200, {'ok': True})

        def do_panorama(self, property_id, spot):
            meta = studio.read(property_id)
            target = studio.folder(property_id) / 'out' / 'result' / 'panos' / ('%02d.jpg' % int(spot))
            if not meta or meta['status'] != 'ready' or not target.is_file():
                return self.fail(404, 'not_found')
            self.reply(200, target.read_bytes(), 'image/jpeg', 'private, max-age=3600')

    return Handler


def main():
    data = os.environ.get('APP_DATA_DIR')
    if not data:
        sys.exit('APP_DATA_DIR is required')
    host, port = os.environ.get('HOST', '127.0.0.1'), int(os.environ.get('PORT', '8937'))
    server = ThreadingHTTPServer((host, port), handler(Studio(data)))
    print('Tour Studio on http://%s:%d' % (host, port), flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()
