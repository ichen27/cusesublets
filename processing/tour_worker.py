"""Serial, lease-fenced tour worker: Gaussian splat tours and stitched spot tours. No customer data
in logs."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import urllib.error
import urllib.request
from urllib.parse import urlsplit

ENGINE_REVISION = 'b1099a13eb8a6874f91ec92a63b9a2f444a31c2b'
LIMIT = 64 * 1024 * 1024
SPOT_LIMIT = 96 * 1024 * 1024
FORWARDED = ('capture_invalid', 'timeout', 'model_too_large', 'spot_incomplete')
CAPTURE_NAME = re.compile(r'^(manifest\.json|mesh\.json|images/\d{5}\.jpg)$')
PANORAMA_QUALITY = 85


def input_limit(job):
    return SPOT_LIMIT if job.get('kind') == 'spots' else LIMIT


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
    if os.environ.get('CUSE_ROOM_MESH') == '1':
        build_optional_mesh(work / 'frames', result / 'mesh')


def build_optional_mesh(frames, out, candidates=None):
    """The mesh is an addition to the tour: if it fails, the tour still completes."""
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    try:
        from room_mesh import MODEL, build_mesh
        extra = {} if candidates is None else {'candidates': candidates}
        build_mesh(frames, out, os.environ.get('CUSE_DA3_MODEL', MODEL), log=lambda line: print(line, flush=True),
                   **extra)
    except Exception as error:
        # Only the error type is logged; messages can include private paths.
        print('Room mesh skipped:', type(error).__name__, flush=True)
        for name in ('room-mesh.ply', 'mesh.json'):
            (out / name).unlink(missing_ok=True)


def upload_mesh(api, job, result):
    """Uploads the mesh if one was built. A rejected mesh is dropped; a lost lease stops the job."""
    mesh = result / 'mesh/room-mesh.ply'
    if not mesh.exists():
        return
    try:
        api.json(job['id'] + '/mesh', job=job, file=mesh,
                 metadata=json.loads((result / 'mesh/mesh.json').read_text()))
    except urllib.error.HTTPError as error:
        if error.code == 409:
            raise
        print('Room mesh rejected by the API:', error.code, flush=True)


def extract_capture(capture, out, limit=SPOT_LIMIT):
    """Unpacks a capture archive: regular files with the app's names only, no links or
    duplicates, bounded in total size. Returns the parsed manifest."""
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    (out / 'images').mkdir(exist_ok=True)
    seen, total = set(), 0
    try:
        with tarfile.open(capture, 'r:') as archive:
            for member in archive:
                if not member.isreg() or not CAPTURE_NAME.match(member.name) or member.name in seen:
                    raise ValueError('capture_invalid')
                seen.add(member.name)
                total += member.size
                if total > limit:
                    raise ValueError('capture_invalid')
                source = archive.extractfile(member)
                with (out / member.name).open('wb') as target:
                    while block := source.read(1024 * 1024):
                        target.write(block)
    except (tarfile.TarError, OSError) as error:
        raise ValueError('capture_invalid') from error
    if 'manifest.json' not in seen:
        raise ValueError('capture_invalid')
    try:
        return json.loads((out / 'manifest.json').read_text())
    except ValueError as error:
        raise ValueError('capture_invalid') from error


def write_bundle(path, panoramas, spots_json):
    """USTAR bundle of panoramas then spots.json; returns {name: (data offset, length)} so the API
    can serve each panorama by byte range."""
    ranges = {}
    with tarfile.open(path, 'w', format=tarfile.USTAR_FORMAT) as archive:
        for name, source in panoramas:
            data = Path(source).read_bytes()
            info = tarfile.TarInfo(name)
            info.size, info.mode = len(data), 0o600
            header = archive.fileobj.tell()
            archive.addfile(info, io.BytesIO(data))
            ranges[name] = (header + 512, len(data))
        info = tarfile.TarInfo('spots.json')
        info.size, info.mode = len(spots_json), 0o600
        archive.addfile(info, io.BytesIO(spots_json))
    return ranges


def mesh_candidates(manifest):
    """Walk frames plus level-ring slices: the views with the most parallax between them."""
    picked = []
    for index, frame in enumerate(manifest.get('frames', [])):
        if frame.get('role', 'walk') == 'walk':
            picked.append(index)
            continue
        forward_y = -float(frame['transform_matrix'][1][2])  # ARKit looks along −Z
        if abs(forward_y) < 0.26:  # within 15° of level
            picked.append(index)
    return picked


def reconstruct_spots(capture, work):
    """Stitches every finished spot, optionally builds the mesh, and writes the bundle and its
    display metadata under WORK/result."""
    import cv2
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from spot_stitch import MAX_HOLES, load_spot_slices, stitch
    work = Path(work)
    frames = work / 'frames'
    manifest = extract_capture(capture, frames)
    if manifest.get('capture') != 'spots':
        raise ValueError('capture_invalid')
    spots = load_spot_slices(manifest, frames)
    records = {s['spot']: s for s in manifest['spots']}
    result = work / 'result'
    (result / 'panos').mkdir(parents=True)
    panoramas, described = [], []
    for number in sorted(spots):
        image, holes = stitch(spots[number])
        print(f'spot {number}: {len(spots[number])} slices, holes {holes:.4f}', flush=True)
        if holes > MAX_HOLES:
            raise ValueError('spot_incomplete')
        name = f'panos/{number:02d}.jpg'
        if not cv2.imwrite(str(result / name), image, [cv2.IMWRITE_JPEG_QUALITY, PANORAMA_QUALITY]):
            raise ValueError('processing_failed')
        panoramas.append((name, result / name))
        record = records[number]
        described.append((number, name, [round(float(x), 4) for x in record['position']],
                          round(float(record['floor_y']), 4)))
    if os.environ.get('CUSE_ROOM_MESH') == '1':
        build_optional_mesh(frames, result / 'mesh', mesh_candidates(manifest))
    summary = {'spots': [{'spot': n, 'position': p, 'floorY': f, 'panorama': name} for n, name, p, f in described]}
    ranges = write_bundle(result / 'spots.bundle', panoramas, json.dumps(summary).encode())
    display = {
        'method': 'ARKit guided slices, ORB-refined rotations, feathered equirect stitching',
        'slices': sum(len(s) for s in spots.values()),
        'spots': [{'spot': n, 'position': p, 'floorY': f,
                   'panorama': {'offset': ranges[name][0], 'length': ranges[name][1], 'width': 4096, 'height': 2048}}
                  for n, name, p, f in described],
    }
    (result / 'display.json').write_text(json.dumps(display))


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
            try:
                work = Path(directory)
                capture = work / 'input.roomcapture'
                spot_tour = job.get('kind') == 'spots'
                total = 0
                with api.request(job['id'] + '/input', job=job) as response, capture.open('wb') as out:
                    while block := response.read(1024 * 1024):
                        total += len(block)
                        if total > input_limit(job) or total > job['inputSize'] or lease_lost.is_set():
                            raise ValueError('capture_invalid')
                        out.write(block)
                if total != job['inputSize'] or file_hash(capture) != job['inputHash']:
                    raise ValueError('capture_invalid')
                with (work / 'process.log').open('wb') as log:
                    mode = '--reconstruct-spots' if spot_tour else '--reconstruct'
                    process = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), mode,
                                                str(capture), str(work / 'training')], stdout=log,
                                               stderr=subprocess.STDOUT, start_new_session=True)
                    deadline = time.monotonic() + 7500
                    while process.poll() is None:
                        if lease_lost.wait(1):
                            raise ValueError('lease_lost')
                        if time.monotonic() > deadline:
                            raise ValueError('timeout')
                    if process.returncode:
                        # The child reports only codes from a fixed list; anything else is generic.
                        marker = work / 'training/error_code'
                        code = marker.read_text().strip() if marker.exists() else ''
                        raise ValueError(code if code in FORWARDED else 'processing_failed')
                result = work / 'training/result'
                metadata = json.loads((result / 'display.json').read_text())
                upload_mesh(api, job, result)
                output = result / ('spots.bundle' if spot_tour else 'export_3000.ply')
                api.json(job['id'] + '/complete', job=job, file=output, metadata=metadata)
                print('Tour reconstruction completed', flush=True)
            finally:
                if process is not None:
                    stop_process(process)
    except (Exception, KeyboardInterrupt) as error:
        if process is not None:
            stop_process(process)
        if not lease_lost.is_set():
            code = str(error) if str(error) in FORWARDED else 'processing_failed'
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
    parser.add_argument('--reconstruct-spots', nargs=2, type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    def terminate(*_):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, terminate)
    if args.reconstruct:
        reconstruct(*args.reconstruct)
        return
    if args.reconstruct_spots:
        capture, work = args.reconstruct_spots
        try:
            reconstruct_spots(capture, work)
        except ValueError as error:
            if str(error) in FORWARDED:
                Path(work).mkdir(parents=True, exist_ok=True)
                (Path(work) / 'error_code').write_text(str(error))
            print('Spot processing stopped:', type(error).__name__, flush=True)
            sys.exit(2)
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
