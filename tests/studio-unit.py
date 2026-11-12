"""Tour Studio service: upload, stitch, status, panorama, and the request guards."""
import importlib.util
import json
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'processing'))


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


studio = load('studio_server', 'studio/server.py')
ID = '0f8fad5b-d9cb-469f-a165-70867728950e'


class StudioService(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scratch = tempfile.TemporaryDirectory()
        cls.capture = Path(cls.scratch.name) / 'capture.roomcapture'
        load('make_synthetic_capture', 'processing/make_synthetic_capture.py').write_spots(
            cls.capture, spots=((0.0, 0.0, 0.0),))
        cls.store = studio.Studio(Path(cls.scratch.name) / 'data')
        cls.server = ThreadingHTTPServer(('127.0.0.1', 0), studio.handler(cls.store))
        cls.base = 'http://127.0.0.1:%d' % cls.server.server_address[1]
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.scratch.cleanup()

    def call(self, path, method='GET', data=None, headers=None):
        request = urllib.request.Request(self.base + path, data=data, method=method, headers=headers or {})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return response.status, response.read(), response.headers
        except urllib.error.HTTPError as error:
            return error.code, error.read(), error.headers

    def test_1_upload_stitches_and_serves_the_tour(self):
        status, body, _ = self.call('/api/properties/%s/capture' % ID, 'POST', self.capture.read_bytes(),
                                    {'X-Cuse-Studio': '1', 'X-Property-Name': '12%20Elm%20St'})
        self.assertEqual(status, 202)
        self.assertEqual(json.loads(body)['status'], 'processing')
        deadline = time.time() + 120
        while time.time() < deadline:
            detail = json.loads(self.call('/api/properties/' + ID)[1])
            if detail['status'] != 'processing':
                break
            time.sleep(0.5)
        self.assertEqual(detail['status'], 'ready', detail)
        self.assertEqual(detail['name'], '12 Elm St')
        self.assertEqual(detail['spots'], 1)
        self.assertEqual(detail['tour']['listingId'], ID)
        self.assertEqual(detail['tour']['kind'], 'spots')
        status, image, headers = self.call('/api/listings/%s/tours/tour/panorama/1' % ID)
        self.assertEqual((status, headers['Content-Type'], image[:2]), (200, 'image/jpeg', b'\xff\xd8'))
        self.assertEqual(self.call('/api/listings/%s/tours/tour/panorama/2' % ID)[0], 404)
        listed = json.loads(self.call('/api/properties')[1])['properties']
        self.assertEqual([p['id'] for p in listed], [ID])
        self.assertIn(b'12 Elm St', self.call('/')[1])

    def test_2_changes_need_the_app_header(self):
        self.assertEqual(self.call('/api/properties/' + ID, 'DELETE')[0], 403)
        self.assertEqual(self.call('/api/properties/%s/capture' % ID, 'POST', b'x')[0], 403)
        self.assertEqual(json.loads(self.call('/api/properties/' + ID)[1])['status'], 'ready')

    def test_3_bad_requests_are_refused(self):
        headers = {'X-Cuse-Studio': '1'}
        self.assertEqual(self.call('/api/properties/../../etc/capture', 'POST', b'x', headers)[0], 404)
        self.assertEqual(self.call('/api/properties/not-a-uuid')[0], 404)
        self.assertEqual(self.call('/assets/..%2Fserver.py')[0], 404)
        other = ID.replace('0f8', '1f8')
        self.assertEqual(self.call('/api/properties/%s/capture' % other, 'POST', b'not an archive', headers)[0], 202)
        deadline = time.time() + 60
        while time.time() < deadline:
            detail = json.loads(self.call('/api/properties/' + other)[1])
            if detail['status'] != 'processing':
                break
            time.sleep(0.3)
        self.assertEqual(detail['status'], 'failed')
        self.assertIsNone(detail['tour'])

    def test_4_delete_removes_the_property(self):
        self.assertEqual(self.call('/api/properties/' + ID, 'DELETE', headers={'X-Cuse-Studio': '1'})[0], 200)
        self.assertEqual(self.call('/api/properties/' + ID)[0], 404)

    def test_names_are_escaped_on_the_index_page(self):
        page = studio.index_page(type('S', (), {
            'all': lambda self: [{'id': ID}],
            'describe': lambda self, m: {'id': ID, 'name': '<script>', 'status': 'failed',
                                         'error': '<b>', 'createdAt': '2026-11-12', 'spots': 0}})())
        self.assertNotIn('<script>', page)
        self.assertNotIn('<b>', page)


if __name__ == '__main__':
    unittest.main()
