"""Tour Studio: a private service that turns spot captures from the iPhone app into 360° tours
and shows them. One process, standard library only; the stitching itself runs
`processing/tour_worker.py --reconstruct-spots` in a child process.

Login: when STUDIO_TOKEN is set (at least 32 characters), every request except /health must
carry it, as `Authorization: Bearer <token>` (the iPhone app) or as the `studio_token` cookie
(a browser, after entering the token at /signin). Without STUDIO_TOKEN the service has no login
and must stay behind an authenticating proxy or on a private network.

It also answers only requests addressed to its own loopback address or to a hostname listed in
STUDIO_HOSTS (comma-separated, with the port when it is not 443), so a web page cannot reach it
by pointing another name at this machine.
"""
import hmac
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
from urllib.parse import parse_qs, unquote

REPO = Path(__file__).resolve().parent.parent
WORKER = REPO / 'processing' / 'tour_worker.py'
SITE = REPO / 'studio-dist'
CAPTURE_LIMIT = 96 * 1024 * 1024
PROCESS_TIMEOUT = 15 * 60
MINIMUM_TOKEN = 32
OPEN_ROUTES = {'health', 'signin_page', 'signin'}
PROPERTY_ID = r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
ROUTES = [(method, re.compile(pattern), name) for method, pattern, name in [
    ('GET', r'/health', 'health'),
    ('GET', r'/', 'index'),
    ('GET', r'/signin', 'signin_page'),
    ('POST', r'/signin', 'signin'),
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


def allowed_hosts(port, extra=''):
    names = {'127.0.0.1:%d' % port, 'localhost:%d' % port}
    names.update(h.strip().lower() for h in extra.split(',') if h.strip())
    return names


SIGNIN_PAGE = ('<!doctype html><html lang="en"><meta charset="utf-8">'
               '<meta name="viewport" content="width=device-width, initial-scale=1">'
               '<title>Tour Studio</title><style>body{font:16px system-ui;margin:2rem auto;max-width:24rem;'
               'padding:0 1rem}input,button{font:inherit;padding:.5rem;width:100%%;box-sizing:border-box;'
               'margin-top:.5rem}</style><h1>Tour Studio</h1>%s<form method="post" action="/signin">'
               '<label>Access token<input type="password" name="token" autocomplete="current-password" '
               'required></label><button>Sign in</button></form></html>')


def handler(studio, hosts=None, token=None):
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
            self.send_header('Referrer-Policy', 'no-referrer')
            for name, value in getattr(self, 'extra_headers', ()):
                self.send_header(name, value)
            self.end_headers()
            if self.command != 'HEAD':
                self.wfile.write(body)

        def fail(self, status, code):
            self.close_connection = True
            self.reply(status, {'error': code})

        def signed_in(self):
            """Whether the request carries the token, as a bearer header or the sign-in cookie."""
            if token is None:
                return True
            offered = []
            scheme, _, value = self.headers.get('Authorization', '').partition(' ')
            if scheme.lower() == 'bearer':
                offered.append(value.strip())
            for part in self.headers.get('Cookie', '').split(';'):
                name, _, value = part.strip().partition('=')
                if name == 'studio_token':
                    offered.append(value)
            return any(hmac.compare_digest(o.encode(), token.encode()) for o in offered)

        def dispatch(self):
            self.extra_headers = []
            if hosts is not None and self.headers.get('Host', '').lower() not in hosts:
                return self.fail(421, 'unknown_host')
            path = self.path.split('?')[0]
            for method, pattern, name in ROUTES:
                match = pattern.fullmatch(path)
                if match and method == self.command:
                    if name not in OPEN_ROUTES and not self.signed_in():
                        # A person in a browser is sent to sign in; the app gets a plain refusal.
                        if method == 'GET' and 'text/html' in self.headers.get('Accept', ''):
                            self.extra_headers.append(('Location', '/signin'))
                            return self.reply(303)
                        return self.fail(401, 'unauthorized')
                    # Browsers cannot add this header to a cross-site form post.
                    if method != 'GET' and name != 'signin' and self.headers.get('X-Cuse-Studio') != '1':
                        return self.fail(403, 'missing_header')
                    return getattr(self, 'do_' + name)(*match.groups())
            # Unknown paths look the same signed in or not.
            self.fail(404, 'not_found')

        def do_signin_page(self):
            self.reply(200, SIGNIN_PAGE % '', 'text/html; charset=utf-8')

        def do_signin(self):
            try:
                length = int(self.headers.get('Content-Length', '0'))
            except ValueError:
                length = -1
            if not 0 <= length <= 4096:
                return self.fail(413, 'too_large')
            offered = parse_qs(self.rfile.read(length).decode('utf-8', 'replace')).get('token', [''])[0]
            if token is None or not hmac.compare_digest(offered.encode(), token.encode()):
                # Slow guessing a little; the token is too long to guess in any case.
                time.sleep(1)
                return self.reply(401, SIGNIN_PAGE % '<p role="alert">That token is not right.</p>',
                                  'text/html; charset=utf-8')
            self.extra_headers.append((
                'Set-Cookie', 'studio_token=%s; Path=/; Max-Age=2592000; HttpOnly; Secure; SameSite=Lax' % token))
            self.extra_headers.append(('Location', '/'))
            self.reply(303)

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


class StudioServer(ThreadingHTTPServer):
    """Serves requests in threads, and stays quiet when a client hangs up.

    Cloudflare's tunnel opens and drops spare connections continually, so the
    default handler's traceback for a reset connection would bury real errors.
    """

    daemon_threads = True

    QUIET = (ConnectionResetError, BrokenPipeError, ConnectionAbortedError, TimeoutError)

    def handle_error(self, request, client_address):
        failure = sys.exc_info()[0]
        if failure is not None and issubclass(failure, self.QUIET):
            return
        super().handle_error(request, client_address)


def main():
    data = os.environ.get('APP_DATA_DIR')
    if not data:
        sys.exit('APP_DATA_DIR is required')
    host, port = os.environ.get('HOST', '127.0.0.1'), int(os.environ.get('PORT', '8937'))
    hosts = allowed_hosts(port, os.environ.get('STUDIO_HOSTS', ''))
    token = os.environ.get('STUDIO_TOKEN') or None
    if token is not None and (len(token) < MINIMUM_TOKEN or not token.isascii() or not token.isalnum()):
        sys.exit('STUDIO_TOKEN must be at least %d letters and digits' % MINIMUM_TOKEN)
    server = StudioServer((host, port), handler(Studio(data), hosts, token))
    print('Tour Studio on http://%s:%d (%s)' % (host, port, 'token login' if token else 'NO LOGIN'), flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()
