"""Serial, lease-fenced Gaussian reconstruction worker. No customer data in logs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from urllib.parse import urlsplit

ENGINE_REVISION = 'b1099a13eb8a6874f91ec92a63b9a2f444a31c2b'
LIMIT = 64 * 1024 * 1024


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def settings():
    base = os.environ['CUSE_PROCESSOR_API'].rstrip('/')
    parsed = urlsplit(base)
    if parsed.path or parsed.query or parsed.fragment or parsed.username or not (
        parsed.scheme == 'https' or parsed.scheme == 'http' and parsed.hostname in ('127.0.0.1', 'localhost')
    ):
        raise ValueError('CUSE_PROCESSOR_API must be an HTTPS origin or local test origin')
    token = os.environ['TOUR_PROCESSOR_TOKEN']
    if len(token) < 32:
        raise ValueError('Use a processor secret of at least 32 characters')
    return base, token


class API:
    def __init__(self):
        self.base, self.token = settings()
        self.opener = urllib.request.build_opener(NoRedirect)

    def request(self, path, payload=None, job=None, file=None, metadata=None):
        headers = {'Authorization': 'Bearer ' + self.token, 'Origin': os.environ.get('CUSE_PROCESSOR_ORIGIN', self.base)}
        if job:
            headers['X-Tour-Claim'] = job['claim']
        if file:
            headers.update({'Content-Type': 'application/octet-stream', 'Content-Length': str(file.stat().st_size),
                            'X-File-Size': str(file.stat().st_size), 'X-File-SHA256': file_hash(file),
                            'X-Tour-Result': json.dumps(metadata, separators=(',', ':'))})
        else:
            headers['Content-Type'] = 'application/json'
        data = file.open('rb') if file else (json.dumps(payload).encode() if payload is not None else None)
        try:
            return self.opener.open(urllib.request.Request(self.base + '/api/tour-processor/' + path,
                                   data=data, headers=headers, method='POST' if data is not None else 'GET'), timeout=120)
        finally:
            if file:
                data.close()

    def json(self, path, payload=None, **kwargs):
        with self.request(path, payload, **kwargs) as response:
            return json.load(response)


def file_hash(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def reconstruct(capture, work):
    engine = Path(os.environ['CUSE_CAPTURE_ENGINE']).resolve()
    revision = subprocess.check_output(['git', '-C', str(engine), 'rev-parse', 'HEAD'], text=True).strip()
    if revision != ENGINE_REVISION:
        raise ValueError('Capture engine revision does not match the reviewed adapter')
    # This dependency is the existing standalone experiment, pinned in the runbook.
    sys.path.insert(0, str(engine))
    from capture.native import prepare_native
    from capture.splat import validate_splat
    cameras = prepare_native(capture, work)
    brush = Path(os.environ['CUSE_BRUSH']).resolve(strict=True)
    result = work / 'result'
    result.mkdir()
    with (work / 'training.log').open('wb') as log:
        subprocess.run([str(brush), str(cameras.model_dir), '--total-steps', '3000', '--max-resolution', '1200',
                        '--max-splats', '500000', '--growth-stop-iter', '2400', '--refine-every', '100',
                        '--export-every', '3000', '--export-path', str(result)], check=True, timeout=7200,
                       stdout=log, stderr=subprocess.STDOUT, cwd=work)
    model = result / 'export_3000.ply'
    if model.stat().st_size > LIMIT:
        raise ValueError('model_too_large')
    validated = validate_splat(model)
    camera = json.loads((cameras.model_dir.parent / 'view.json').read_text())
    (result / 'display.json').write_text(json.dumps({'method': cameras.method, 'views': cameras.registered,
                                                  'gaussians': validated['count'], 'camera': camera}))


def stop_process(process):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()


def process_job(api, job, root):
    stop = threading.Event()
    lease_lost = threading.Event()

    def heartbeat():
        while not stop.wait(45):
            try:
                api.json(job['id'] + '/heartbeat', {}, job=job)
            except Exception:
                # Stop training promptly on ambiguous lease ownership; a fresh claim can retry.
                lease_lost.set()
                return

    thread = threading.Thread(target=heartbeat, daemon=True)
    thread.start()
    process = None
    try:
        with tempfile.TemporaryDirectory(prefix='tour-', dir=root) as directory:
            work = Path(directory)
            capture = work / 'input.roomcapture'
            total = 0
            with api.request(job['id'] + '/input', job=job) as response, capture.open('wb') as out:
                while block := response.read(1024 * 1024):
                    total += len(block)
                    if total > LIMIT or total > job['inputSize'] or lease_lost.is_set():
                        raise ValueError('capture_invalid')
                    out.write(block)
            if total != job['inputSize'] or file_hash(capture) != job['inputHash']:
                raise ValueError('capture_invalid')
            with (work / 'process.log').open('wb') as log:
                process = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), '--reconstruct',
                                            str(capture), str(work / 'training')], stdout=log,
                                           stderr=subprocess.STDOUT, start_new_session=True)
                deadline = time.monotonic() + 7500
                while process.poll() is None:
                    if lease_lost.wait(1):
                        raise ValueError('lease_lost')
                    if time.monotonic() > deadline:
                        raise ValueError('timeout')
                if process.returncode:
                    raise ValueError('processing_failed')
            result = work / 'training/result'
            metadata = json.loads((result / 'display.json').read_text())
            api.json(job['id'] + '/complete', job=job, file=result / 'export_3000.ply', metadata=metadata)
            print('Tour reconstruction completed', flush=True)
    except (Exception, KeyboardInterrupt) as error:
        if process is not None:
            stop_process(process)
        if not lease_lost.is_set():
            code = str(error) if str(error) in ('capture_invalid', 'timeout', 'model_too_large') else 'processing_failed'
            try:
                api.json(job['id'] + '/fail', {'code': code}, job=job)
            except Exception:
                pass  # Lease expiry makes the job available again; stale writes never win.
        print('Tour reconstruction stopped; private working files removed', flush=True)
        if isinstance(error, KeyboardInterrupt):
            raise
    finally:
        if process is not None:
            stop_process(process)
        stop.set()
        thread.join(timeout=125)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--once', action='store_true')
    parser.add_argument('--reconstruct', nargs=2, type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    if args.reconstruct:
        reconstruct(*args.reconstruct)
        return
    api = API()
    root = Path(os.environ['CUSE_PROCESSOR_WORK']).resolve()
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    while True:
        job = api.json('claim', {})['job']
        if job:
            process_job(api, job, root)
        if args.once:
            return
        time.sleep(10)


if __name__ == '__main__':
    main()
