"""Stitches one spot's guided slices into an equirectangular 360° panorama.

ARKit's camera rotations place each slice; ORB matches between overlapping slices refine them
by a few degrees, per-slice gains even out exposure, and feathered blending hides seams. Yaw 0
is ARKit world −Z, +Y is up, and columns grow clockwise seen from above. No customer data is
logged here.
"""
from dataclasses import dataclass
from pathlib import Path
import re

import numpy as np

FLIP = np.diag([1.0, -1.0, -1.0])  # ARKit camera (+Y up, −Z forward) <-> OpenCV camera
NADIR_BGR = (43, 43, 43)
NADIR_PITCH = np.radians(-80)
NADIR_FEATHER = np.radians(2)
MAX_HOLES = 0.02
BLOCK_ROWS = 256
SLICE_NAME = re.compile(r'^images/\d{5}\.jpg$')
# Bounds on what a manifest may ask for, so a crafted capture cannot amplify the work: the app
# saves 29 slices per spot (64 leaves room to tune the layout), at most 8 spots, 1440 px wide.
MAX_SPOTS = 8
MAX_SLICES = 64
MAX_SIDE = 4096


@dataclass
class Slice:
    path: Path
    K: np.ndarray  # 3×3 intrinsics; pixel i spans [i, i+1), so its centre is i + 0.5
    R: np.ndarray  # 3×3 camera-to-world rotation in OpenCV camera axes
    width: int
    height: int


def load_spot_slices(manifest, root):
    """Slices of every finished spot, keyed by spot number. Only paths listed in a spot's record
    count, so slices of a spot that never finished never reach a panorama."""
    root = Path(root).resolve()
    frames = {f.get('file_path'): f for f in manifest.get('frames', [])}
    records = manifest.get('spots') or []
    if not isinstance(records, list) or len(records) > MAX_SPOTS:
        raise ValueError('capture_invalid')
    spots, used = {}, set()
    for spot in records:
        number = spot.get('spot')
        names = spot.get('slices', [])
        if not isinstance(number, int) or number in spots or not isinstance(names, list) or len(names) > MAX_SLICES:
            raise ValueError('capture_invalid')
        slices = []
        for name in names:
            path = root / str(name)
            if (not isinstance(name, str) or not SLICE_NAME.match(name) or name not in frames or name in used
                    or path.is_symlink() or not path.resolve().is_relative_to(root)):
                raise ValueError('capture_invalid')
            used.add(name)
            frame = frames[name]
            if not all(isinstance(frame.get(k), int) and 1 <= frame[k] <= MAX_SIDE for k in ('width', 'height')):
                raise ValueError('capture_invalid')
            transform = np.asarray(frame['transform_matrix'], np.float64)
            K = np.array([[frame['fx'], 0, frame['cx']], [0, frame['fy'], frame['cy']], [0, 0, 1]],
                         np.float64)
            slices.append(Slice(path, K, transform[:3, :3] @ FLIP, int(frame['width']),
                                int(frame['height'])))
        if not slices:
            raise ValueError('capture_invalid')
        spots[number] = slices
    return spots


def directions(width, height, rows=None):
    """World unit directions of equirect pixel centres, shape (rows, width, 3)."""
    rows = np.arange(height) if rows is None else rows
    yaw = (np.arange(width) + 0.5) / width * 2 * np.pi - np.pi
    pitch = np.pi / 2 - (rows + 0.5) / height * np.pi
    yaw, pitch = np.meshgrid(yaw, pitch)
    return np.stack([np.cos(pitch) * np.sin(yaw), np.sin(pitch), -np.cos(pitch) * np.cos(yaw)], -1)


def _project(d, K, R, width, height):
    """Pixel coordinates (centre convention) of world directions in a slice, and visibility."""
    c = d @ R  # R^T · d for every direction
    z = c[..., 2]
    ahead = z > 1e-6
    z = np.where(ahead, z, 1)
    u = K[0, 0] * c[..., 0] / z + K[0, 2]
    v = K[1, 1] * c[..., 1] / z + K[1, 2]
    inside = ahead & (u >= 0) & (u <= width) & (v >= 0) & (v <= height)
    return u, v, inside


def _feather(u, v, width, height):
    edge = np.minimum(np.minimum(u, width - u), np.minimum(v, height - v))
    return np.clip(edge / (min(width, height) / 2), 0, 1) ** 2


def jpeg_size(path):
    """(width, height) from a JPEG's frame header without decoding it, or None."""
    with open(path, 'rb') as source:
        data = source.read(1 << 20)
    if data[:2] != b'\xff\xd8':
        return None
    i = 2
    while i + 9 < len(data):
        if data[i] != 0xFF:
            return None
        marker = data[i + 1]
        if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
            i += 2
            continue
        length = int.from_bytes(data[i + 2:i + 4], 'big')
        if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
            return int.from_bytes(data[i + 7:i + 9], 'big'), int.from_bytes(data[i + 5:i + 7], 'big')
        i += 2 + length
    return None


def _images(slices):
    import cv2
    images = []
    for s in slices:
        # Check the header first: the decoder must never see an image bigger than declared.
        if jpeg_size(s.path) != (s.width, s.height):
            raise ValueError('capture_invalid')
        image = cv2.imread(str(s.path), cv2.IMREAD_COLOR)
        if image is None or image.shape[:2] != (s.height, s.width):
            raise ValueError('capture_invalid')
        images.append(image)
    return images


def _rotation(vector):
    from scipy.spatial.transform import Rotation
    return Rotation.from_rotvec(vector).as_matrix()


def refine_rotations(slices, max_correction_deg=3.0, images=None):
    """Corrects each slice's rotation by at most `max_correction_deg` so ORB matches between
    overlapping slices point the same way. A weak prior keeps the set anchored to ARKit (whose
    gravity is reliable); with fewer than 20 matches the input rotations are returned."""
    import cv2
    from scipy.optimize import least_squares
    from scipy.sparse import lil_matrix
    images = _images(slices) if images is None else images
    # A low corner threshold finds features on plain walls and soft furniture.
    orb = cv2.ORB_create(2000, fastThreshold=7)
    features = []
    for s, image in zip(slices, images):
        points, descriptors = orb.detectAndCompute(cv2.cvtColor(image, cv2.COLOR_BGR2GRAY), None)
        if descriptors is None:
            features.append((np.zeros((0, 3)), None))
            continue
        pixels = np.array([p.pt for p in points]) + 0.5
        rays = np.c_[pixels, np.ones(len(pixels))] @ np.linalg.inv(s.K).T
        rays /= np.linalg.norm(rays, axis=1, keepdims=True)
        features.append((rays @ s.R.T, descriptors))
    matcher = cv2.BFMatcher(cv2.NORM_HAMMING, crossCheck=True)
    limit = np.cos(np.radians(max(8.0, 2.5 * max_correction_deg)))
    pairs, left, right = [], [], []
    for i in range(len(slices)):
        for j in range(i + 1, len(slices)):
            if slices[i].R[:, 2] @ slices[j].R[:, 2] < np.cos(np.radians(70)):
                continue
            (wi, di), (wj, dj) = features[i], features[j]
            if di is None or dj is None:
                continue
            for m in matcher.match(di, dj):
                a, b = wi[m.queryIdx], wj[m.trainIdx]
                if a @ b > limit:
                    pairs.append((i, j))
                    left.append(a)
                    right.append(b)
    rotations = [s.R for s in slices]
    if len(pairs) < 20:
        return rotations
    pairs = np.array(pairs)
    left, right = np.array(left), np.array(right)
    n = len(slices)
    prior = 0.05

    def residuals(x):
        mats = np.stack([_rotation(v) for v in x.reshape(n, 3)])
        a = np.einsum('nij,nj->ni', mats[pairs[:, 0]], left)
        b = np.einsum('nij,nj->ni', mats[pairs[:, 1]], right)
        return np.r_[(a - b).ravel(), prior * x]

    sparsity = lil_matrix((3 * len(pairs) + 3 * n, 3 * n), dtype=int)
    for row, (i, j) in enumerate(pairs):
        sparsity[3 * row:3 * row + 3, 3 * i:3 * i + 3] = 1
        sparsity[3 * row:3 * row + 3, 3 * j:3 * j + 3] = 1
    for k in range(3 * n):
        sparsity[3 * len(pairs) + k, k] = 1
    start = np.zeros(3 * n)
    try:
        fit = least_squares(residuals, start, jac_sparsity=sparsity, loss='soft_l1',
                            f_scale=0.003, max_nfev=500)
    except (ValueError, np.linalg.LinAlgError):
        return rotations
    # Stopping at the evaluation limit still leaves a better fit; only a worse one is refused.
    if fit.status < 0 or not np.all(np.isfinite(fit.x)):
        return rotations
    largest = np.radians(max_correction_deg)
    corrected = []
    for vector, s in zip(fit.x.reshape(n, 3), slices):
        angle = np.linalg.norm(vector)
        if angle > largest:
            vector = vector * (largest / angle)
        corrected.append(_rotation(vector) @ s.R)
    return corrected


def exposure_gains(slices, rotations, images=None, sigma_n=10.0, sigma_g=0.5):
    """Per-slice brightness gains that make overlaps agree (least squares on mean luminance in
    each pairwise overlap, Brown & Lowe), normalised to mean 1 and kept within 0.5–2."""
    import cv2
    images = _images(slices) if images is None else images
    d = directions(256, 128)
    lum, seen = [], []
    for s, image, R in zip(slices, images, rotations):
        u, v, inside = _project(d, s.K, R, s.width, s.height)
        gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY).astype(np.float32)
        sample = cv2.remap(gray, (u - 0.5).astype(np.float32), (v - 0.5).astype(np.float32),
                           cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
        lum.append(sample)
        seen.append(inside & (_feather(u, v, s.width, s.height) > 0.01))
    n = len(slices)
    A = np.zeros((n, n))
    b = np.zeros(n)
    for i in range(n):
        for j in range(i + 1, n):
            both = seen[i] & seen[j]
            count = int(both.sum())
            if count < 50:
                continue
            Ii, Ij = float(lum[i][both].mean()), float(lum[j][both].mean())
            w = count / sigma_n ** 2
            # count · ((g_i·I_i − g_j·I_j)² / σn² + (1 − g_i)² / σg² + (1 − g_j)² / σg²)
            A[i, i] += w * Ii * Ii
            A[j, j] += w * Ij * Ij
            A[i, j] -= w * Ii * Ij
            A[j, i] -= w * Ii * Ij
            for k in (i, j):
                A[k, k] += count / sigma_g ** 2
                b[k] += count / sigma_g ** 2
    for k in range(n):
        if A[k, k] == 0:
            A[k, k], b[k] = 1, 1
    gains = np.clip(np.linalg.solve(A, b), 0.5, 2)
    return gains / gains.mean()


def stitch(slices, width=4096, refine=True):
    """Returns (equirect BGR uint8 of width × width/2, hole fraction above the nadir disc).
    Holes above −80° pitch are inpainted and counted; below it a neutral disc hides the floor
    under the person's feet."""
    import cv2
    height = width // 2
    images = _images(slices)
    rotations = refine_rotations(slices, images=images) if refine else [s.R for s in slices]
    gains = exposure_gains(slices, rotations, images=images)
    floats = [image.astype(np.float32) for image in images]
    out = np.zeros((height, width, 3), np.float32)
    covered = np.zeros((height, width), bool)
    for top in range(0, height, BLOCK_ROWS):
        rows = np.arange(top, min(height, top + BLOCK_ROWS))
        d = directions(width, height, rows)
        acc = np.zeros(d.shape, np.float32)
        weight = np.zeros(d.shape[:2], np.float32)
        for s, image, R, gain in zip(slices, floats, rotations, gains):
            u, v, inside = _project(d, s.K, R, s.width, s.height)
            if not inside.any():
                continue
            w = np.where(inside, _feather(u, v, s.width, s.height), 0).astype(np.float32)
            sample = cv2.remap(image, (u - 0.5).astype(np.float32), (v - 0.5).astype(np.float32),
                               cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
            acc += sample * (w * gain)[..., None]
            weight += w
        has = weight > 1e-6
        out[rows] = np.where(has[..., None], acc / np.maximum(weight, 1e-6)[..., None], 0)
        covered[rows] = has
    pitch = np.pi / 2 - (np.arange(height) + 0.5) / height * np.pi
    above = np.repeat((pitch >= NADIR_PITCH)[:, None], width, 1)
    holes = above & ~covered
    hole_fraction = float(holes.sum() / above.sum())
    image = np.clip(out + 0.5, 0, 255).astype(np.uint8)
    if holes.any():
        image = cv2.inpaint(image, holes.astype(np.uint8), 3, cv2.INPAINT_TELEA)
    # The neutral disc: solid below −82°, blended over the 2° above it.
    alpha = np.clip((NADIR_PITCH - pitch) / NADIR_FEATHER, 0, 1)[:, None, None]
    alpha = np.where((~covered & ~above)[..., None], 1, np.broadcast_to(alpha, (height, width, 1)))
    disc = np.array(NADIR_BGR, np.float32)
    image = np.clip(image * (1 - alpha) + disc * alpha + 0.5, 0, 255).astype(np.uint8)
    return image, hole_fraction
