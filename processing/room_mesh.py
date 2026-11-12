"""Builds a coloured room mesh from a prepared ARKit capture.

Depth Anything 3 (Base, Apache-2.0) estimates depth for up to 60 evenly spaced views in a single
pass, conditioned on ARKit's camera poses and intrinsics, so all views agree on where surfaces are.
Splitting a capture into separately processed windows gave each window its own scale (up to 30%
apart in testing), so the view count is capped instead. Low-confidence pixels and pixels across
object edges are dropped, the rest is fused into a TSDF grid, and the mesh is cleaned, simplified
and written as a binary PLY with vertex colours in ARKit world coordinates (metres, +Y up).

Pure helpers (view selection, depth cleaning, PLY writing) need only NumPy; model
inference needs PyTorch and depth_anything_3, and fusion needs Open3D. Usage for offline runs:

    python processing/room_mesh.py FRAMES_DIR OUT_DIR

FRAMES_DIR holds native-manifest.json (or manifest.json) and the images it references.
"""
import json
import struct
import sys
import time
from dataclasses import dataclass
from pathlib import Path

import numpy as np

MODEL = 'depth-anything/DA3-BASE'
METHOD = 'Depth Anything 3 Base depth with ARKit poses + TSDF fusion'
# One pass over 60 views at 504 px takes about 40 s and fits in 16 GB on an Apple M-series Mac.
MAX_VIEWS = 60
PROCESS_RES = 504
VOXEL = 0.02
NEAR, FAR = 0.2, 5.0
CONF_PERCENTILE = 40
EDGE = 0.12
MIN_COMPONENT = 200
MAX_TRIANGLES = 300_000
LIMIT = 64 * 1024 * 1024
FLIP = np.diag([1.0, -1.0, -1.0, 1.0])  # ARKit camera (+Y up, -Z forward) <-> OpenCV camera


@dataclass
class ViewDepth:
    depth: np.ndarray  # metres, H x W, 0 where unknown
    conf: np.ndarray | None
    K: tuple[float, float, float, float]  # fx, fy, cx, cy at depth resolution


def select_views(count, limit=MAX_VIEWS, candidates=None):
    """Indices of at most `limit` views spread evenly over the capture (or over `candidates`, when
    given), always keeping both ends."""
    pool = list(range(count)) if candidates is None else sorted({i for i in candidates if 0 <= i < count})
    if len(pool) <= limit:
        return pool
    return [pool[i] for i in sorted({int(round(x)) for x in np.linspace(0, len(pool) - 1, limit)})]


def clean_depth(depth, conf=None, percentile=CONF_PERCENTILE):
    """Zero pixels outside the working range, below the confidence percentile, or across edges."""
    d = depth.astype(np.float32).copy()
    bad = ~np.isfinite(d) | (d < NEAR) | (d > FAR)
    if conf is not None and percentile:
        bad |= conf < np.percentile(conf, percentile)
    safe = np.where(bad, 0, d)
    for axis in (0, 1):
        jump = np.abs(np.roll(safe, 2, axis) - np.roll(safe, -2, axis))
        bad |= jump > EDGE * np.maximum(safe, 1e-3)
    d[bad] = 0
    return d


def write_ply(path, vertices, colors, faces):
    """Binary little-endian PLY: float x,y,z; uchar red,green,blue; uchar-count int vertex faces."""
    vertices = np.asarray(vertices, '<f4').reshape(-1, 3)
    colors = np.asarray(colors, np.uint8).reshape(-1, 3)
    faces = np.asarray(faces, '<i4').reshape(-1, 3)
    if len(colors) != len(vertices) or (len(faces) and faces.max() >= len(vertices)) or faces.min(initial=0) < 0:
        raise ValueError('Mesh arrays are inconsistent')
    header = ('ply\nformat binary_little_endian 1.0\ncomment ARKit world coordinates, metres, +Y up\n'
              f'element vertex {len(vertices)}\nproperty float x\nproperty float y\nproperty float z\n'
              'property uchar red\nproperty uchar green\nproperty uchar blue\n'
              f'element face {len(faces)}\nproperty list uchar int vertex_indices\nend_header\n')
    vertex = np.empty(len(vertices), dtype=[('p', '<f4', 3), ('c', 'u1', 3)])
    vertex['p'], vertex['c'] = vertices, colors
    face = np.empty(len(faces), dtype=[('n', 'u1'), ('i', '<i4', 3)])
    face['n'], face['i'] = 3, faces
    with open(path, 'wb') as out:
        out.write(header.encode('ascii'))
        out.write(vertex.tobytes())
        out.write(face.tobytes())


def read_ply_header(path):
    """Element counts of a PLY written by write_ply, for validation."""
    with open(path, 'rb') as source:
        head = source.read(4096)
    end = head.index(b'end_header\n')
    counts = {}
    for line in head[:end].decode('ascii').splitlines():
        if line.startswith('element '):
            _, name, n = line.split()
            counts[name] = int(n)
    return counts


def load_frames(frames_dir):
    """Frames whose images are exactly images/NNNNN.jpg inside frames_dir, as the engine requires.

    The worker reads the engine's validated manifest; this check also protects offline runs on an
    unvalidated manifest.json from paths that escape the folder.
    """
    frames_dir = Path(frames_dir).resolve()
    manifest = frames_dir / 'native-manifest.json'
    if not manifest.exists():
        manifest = frames_dir / 'manifest.json'
    frames = json.loads(manifest.read_text())['frames']
    for index, frame in enumerate(frames):
        name = frame.get('file_path')
        path = frames_dir / str(name)
        if (name != f'images/{index:05d}.jpg' or path.is_symlink()
                or not path.resolve().is_relative_to(frames_dir)):
            raise ValueError('capture_invalid')
    return frames


def estimate_depth(frames, frames_dir, model_name=MODEL, log=print, candidates=None):
    """Depth for the selected views from one Depth Anything 3 pass, in ARKit's metric scale."""
    import torch
    from depth_anything_3.api import DepthAnything3
    from PIL import Image

    device = 'mps' if torch.backends.mps.is_available() else 'cuda' if torch.cuda.is_available() else 'cpu'
    model = DepthAnything3.from_pretrained(model_name).to(device).eval()
    ids = select_views(len(frames), candidates=candidates)
    images = [np.asarray(Image.open(Path(frames_dir) / frames[i]['file_path']).convert('RGB')) for i in ids]
    ext = np.stack([np.linalg.inv(np.asarray(frames[i]['transform_matrix'], np.float64) @ FLIP) for i in ids])
    ixt = np.stack([np.array([[frames[i]['fx'], 0, frames[i]['cx']], [0, frames[i]['fy'], frames[i]['cy']],
                              [0, 0, 1]], np.float64) for i in ids])
    with torch.no_grad():
        p = model.inference(images, extrinsics=ext.astype(np.float32), intrinsics=ixt.astype(np.float32),
                            process_res=PROCESS_RES)
    log(f'depth: {len(ids)} of {len(frames)} views in one pass')
    return {i: ViewDepth(p.depth[k].astype(np.float32),
                         None if p.conf is None else p.conf[k].astype(np.float32),
                         (float(p.intrinsics[k][0, 0]), float(p.intrinsics[k][1, 1]),
                          float(p.intrinsics[k][0, 2]), float(p.intrinsics[k][1, 2])))
            for k, i in enumerate(ids)}


def fuse(frames, frames_dir, depths, voxel=VOXEL):
    import open3d as o3d
    from PIL import Image

    volume = o3d.pipelines.integration.ScalableTSDFVolume(
        voxel_length=voxel, sdf_trunc=4 * voxel, color_type=o3d.pipelines.integration.TSDFVolumeColorType.RGB8)
    used = 0
    for i, frame in enumerate(frames):
        if i not in depths:
            continue
        v = depths[i]
        d = clean_depth(v.depth, v.conf)
        if (d > 0).mean() < 0.05:
            continue
        h, w = d.shape
        rgb = np.asarray(Image.open(Path(frames_dir) / frame['file_path']).convert('RGB').resize((w, h)))
        intr = o3d.camera.PinholeCameraIntrinsic(w, h, *v.K)
        rgbd = o3d.geometry.RGBDImage.create_from_color_and_depth(
            o3d.geometry.Image(np.ascontiguousarray(rgb)), o3d.geometry.Image(d), depth_scale=1.0,
            depth_trunc=FAR, convert_rgb_to_intensity=False)
        volume.integrate(rgbd, intr, np.linalg.inv(np.asarray(frame['transform_matrix'], np.float64) @ FLIP))
        used += 1
    return volume.extract_triangle_mesh(), used


def finish(mesh, max_triangles=MAX_TRIANGLES):
    """Drop small floating fragments and simplify to a size viewers and exports handle easily."""
    tri, counts, _ = mesh.cluster_connected_triangles()
    tri, counts = np.asarray(tri), np.asarray(counts)
    mesh.remove_triangles_by_mask(counts[tri] < MIN_COMPONENT)
    mesh.remove_unreferenced_vertices()
    if len(mesh.triangles) > max_triangles:
        mesh = mesh.simplify_quadric_decimation(max_triangles)
    mesh.remove_degenerate_triangles()
    mesh.remove_unreferenced_vertices()
    return mesh


def build_mesh(frames_dir, out_dir, model_name=MODEL, log=print, candidates=None):
    """Writes OUT_DIR/room-mesh.ply and returns its display metadata. `candidates` limits which
    frame indices the depth pass may use (spot tours prefer walk frames and level slices)."""
    started = time.time()
    frames_dir, out_dir = Path(frames_dir), Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    frames = load_frames(frames_dir)
    depths = estimate_depth(frames, frames_dir, model_name, log, candidates)
    mesh, used = fuse(frames, frames_dir, depths)
    mesh = finish(mesh)
    vertices = np.asarray(mesh.vertices)
    faces = np.asarray(mesh.triangles)
    if len(faces) < 1000:
        raise ValueError('mesh_too_sparse')
    colors = np.clip(np.asarray(mesh.vertex_colors) * 255 + 0.5, 0, 255).astype(np.uint8)
    path = out_dir / 'room-mesh.ply'
    write_ply(path, vertices, colors, faces)
    if path.stat().st_size > LIMIT:
        raise ValueError('mesh_too_large')
    low, high = vertices.min(0), vertices.max(0)
    metadata = {'method': METHOD, 'views': used, 'vertices': int(len(vertices)), 'triangles': int(len(faces)),
                'voxel': VOXEL, 'bounds': [[round(float(x), 3) for x in low], [round(float(x), 3) for x in high]]}
    (out_dir / 'mesh.json').write_text(json.dumps(metadata))
    log(f'mesh: {used}/{len(frames)} views, {len(faces)} triangles, {time.time() - started:.0f}s')
    return metadata


if __name__ == '__main__':
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    print(json.dumps(build_mesh(sys.argv[1], sys.argv[2])))
