"""Stitches one spot's guided slices into an equirectangular 360° panorama.

ARKit's camera rotations place each slice; ORB matches between overlapping slices refine them
by a few degrees, per-slice gains even out exposure, and feathered blending hides seams. Yaw 0
is ARKit world −Z, +Y is up, and columns grow clockwise seen from above. No customer data is
logged here.
"""
from dataclasses import dataclass
import os
from pathlib import Path
import re

import numpy as np

# Bounds on what a manifest may ask for, so a crafted capture cannot amplify the work. The app
# saves 6 slices per spot at 1920 × 1440 (walk frames are 1920 wide); 64 slices and the pixel
# budget leave room to tune the layout. The decoder enforces the per-image cap itself, so a
# header that lies to jpeg_size cannot reach a larger decode. Set before OpenCV is imported.
MAX_SPOTS = 8
MAX_SLICES = 64
MAX_SIDE = 1920
MAX_SPOT_PIXELS = 48 * 1440 * 1080
# Each slice is compared with at most this many of its nearest neighbours when refining.
MAX_NEIGHBOURS = 6
# The widest half field of view a slice may claim, in degrees (the 0.5× lens is about 54).
MAX_HALF_VIEW = 70.0
os.environ['OPENCV_IO_MAX_IMAGE_PIXELS'] = str(MAX_SIDE * MAX_SIDE)

FLIP = np.diag([1.0, -1.0, -1.0])  # ARKit camera (+Y up, −Z forward) <-> OpenCV camera
NADIR_BGR = (43, 43, 43)
NADIR_PITCH = np.radians(-80)
NADIR_FEATHER = np.radians(2)
MAX_HOLES = 0.02
# A slice aimed below this pitch is the floor shot. The person holding the phone stands on the
# side its bottom edge points to (camera +x), so that side of the shot shows their legs.
DOWN_PITCH = np.radians(-60)
# Floor distance towards the person, per metre of camera height, where the floor shot starts
# to be dropped and where it is dropped entirely (about 2° and 5° past straight down).
BODY_START, BODY_FULL = 0.03, 0.09
# Feather weight of the other slices at which they fully replace the floor shot. They are
# taken with the person behind the camera, so they win wherever they reach.
LEVEL_FULL = 0.25
# Unphotographed areas are filled from a copy this many times smaller, then blurred.
FILL_SHRINK = 8
# The fill is blurred sideways by this angle. Near the poles a panorama's rows are stretched,
# so the blur widens there and the top and bottom close smoothly.
FILL_BLUR = np.radians(6)
# A spot may be level shots only, leaving the ceiling and floor unphotographed. Rows of the
# panorama at least this covered are the band the shots were meant to cover, and holes are
# counted there. The open top and bottom are then not holes, while a missing level shot
# either leaves a counted gap in the band or leaves no band at all, and fails both ways.
BAND_SHARE = 0.9
BLOCK_ROWS = 256
SLICE_NAME = re.compile(r'^images/\d{5}\.jpg$')


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
            try:
                transform = np.asarray(frame['transform_matrix'], np.float64)
                fx, fy, cx, cy = (float(frame[k]) for k in ('fx', 'fy', 'cx', 'cy'))
            except (KeyError, TypeError, ValueError):
                raise ValueError('capture_invalid')
            # A pinhole no wider than a real phone lens, with its centre inside the image.
            narrowest = 0.5 / np.tan(np.radians(MAX_HALF_VIEW))
            if (transform.shape != (4, 4) or not np.all(np.isfinite(transform))
                    or not all(np.isfinite(v) for v in (fx, fy, cx, cy))
                    or fx < narrowest * frame['width'] or fy < narrowest * frame['height']
                    or fx > 1e5 or fy > 1e5
                    or not 0 <= cx <= frame['width'] or not 0 <= cy <= frame['height']):
                raise ValueError('capture_invalid')
            K = np.array([[fx, 0, cx], [0, fy, cy], [0, 0, 1]], np.float64)
            slices.append(Slice(path, K, transform[:3, :3] @ FLIP, int(frame['width']),
                                int(frame['height'])))
        if not slices or sum(s.width * s.height for s in slices) > MAX_SPOT_PIXELS:
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


def jpeg_size_bytes(data):
    """(width, height) from a JPEG's frame header without decoding it, or None. Like libjpeg, runs
    of 0xFF fill bytes before a marker are skipped; anything else unexpected gives None."""
    if data[:2] != b'\xff\xd8':
        return None
    i = 2
    while i < len(data):
        if data[i] != 0xFF:
            return None
        while i < len(data) and data[i] == 0xFF:
            i += 1
        if i >= len(data):
            return None
        marker = data[i]
        i += 1
        if marker == 0x01 or 0xD0 <= marker <= 0xD7:
            continue
        if marker in (0x00, 0xD8, 0xD9, 0xDA) or i + 2 > len(data):
            return None  # no frame header before data or end of image
        length = int.from_bytes(data[i:i + 2], 'big')
        if length < 2:
            return None
        if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
            if length < 7 or i + 7 > len(data):
                return None
            return int.from_bytes(data[i + 5:i + 7], 'big'), int.from_bytes(data[i + 3:i + 5], 'big')
        i += length
    return None


def jpeg_size(path):
    with open(path, 'rb') as source:
        return jpeg_size_bytes(source.read(1 << 20))


def _images(slices):
    import cv2
    images = []
    for s in slices:
        # Read once and decode those same bytes; check the header before the decoder sees them.
        data = s.path.read_bytes()
        if jpeg_size_bytes(data) != (s.width, s.height):
            raise ValueError('capture_invalid')
        image = cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_COLOR)
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
    orb = cv2.ORB_create(1500, fastThreshold=7)
    matcher = cv2.BFMatcher(cv2.NORM_HAMMING, crossCheck=True)
    grays = [cv2.cvtColor(image, cv2.COLOR_BGR2GRAY) for image in images]
    # Half the view along each slice's longer side, in degrees.
    half_views = [np.degrees(np.arctan(max(s.width / s.K[0, 0], s.height / s.K[1, 1]) / 2))
                  for s in slices]
    limit = np.cos(np.radians(max(8.0, 2.5 * max_correction_deg)))
    # Wide slices stretch the same wall differently at their edges, so features are not compared
    # in the slices themselves. Each overlapping pair is redrawn through one shared pinhole view
    # aimed between them; there the two look alike apart from the pose error being solved.
    side, view_focal = 720, 360 / np.tan(np.radians(35))
    grid = (np.arange(side) + 0.5 - side / 2) / view_focal
    view_rays = np.stack([*np.meshgrid(grid, grid), np.ones((side, side))], -1)
    view_rays /= np.linalg.norm(view_rays, axis=-1, keepdims=True)

    def redraw(index, view):
        s = slices[index]
        u, v, inside = _project(view_rays @ view.T, s.K, s.R, s.width, s.height)
        patch = cv2.remap(grays[index], (u - 0.5).astype(np.float32), (v - 0.5).astype(np.float32),
                          cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT)
        # Keep features away from the slice's edge, where the redraw has no neighbours.
        mask = cv2.erode(inside.astype(np.uint8) * 255, np.ones((15, 15), np.uint8))
        points, descriptors = orb.detectAndCompute(patch, mask)
        if descriptors is None:
            return np.zeros((0, 3)), None
        pixels = np.array([p.pt for p in points])
        rays = np.c_[(pixels + 0.5 - side / 2) / view_focal, np.ones(len(pixels))]
        rays /= np.linalg.norm(rays, axis=1, keepdims=True)
        return rays @ view.T, descriptors

    # Only slices that can overlap (optical axes closer than their views reach), and for each
    # slice only its nearest few, so the work grows with the slice count and not its square.
    axes = np.stack([s.R[:, 2] for s in slices])
    closeness = axes @ axes.T
    candidates = set()
    for i in range(len(slices)):
        near = [j for j in np.argsort(-closeness[i]) if j != i
                and closeness[i, j] >= np.cos(np.radians(min(160.0, half_views[i] + half_views[j] - 10.0)))]
        candidates.update((min(i, j), max(i, j)) for j in near[:MAX_NEIGHBOURS])
    pairs, left, right = [], [], []
    for i, j in sorted(candidates):
        fi, fj = slices[i].R[:, 2], slices[j].R[:, 2]
        forward = fi + fj
        forward /= np.linalg.norm(forward)
        x = np.cross(fi, fj)
        if np.linalg.norm(x) < 1e-6:
            x = slices[i].R[:, 0]
        x /= np.linalg.norm(x)
        view = np.stack([x, np.cross(forward, x), forward], 1)
        (wi, di), (wj, dj) = redraw(i, view), redraw(j, view)
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
    # The matches only fix the slices relative to each other; turning them all together fits
    # just as well. Undo that shared turn, so on average the set stays where the sensors put it.
    shared = _rotation(fit.x.reshape(n, 3).mean(0)).T
    corrected = []
    for vector, s in zip(fit.x.reshape(n, 3), slices):
        turn = shared @ _rotation(vector)
        angle = np.arccos(np.clip((np.trace(turn) - 1) / 2, -1, 1))
        if angle > largest:
            axis = np.array([turn[2, 1] - turn[1, 2], turn[0, 2] - turn[2, 0], turn[1, 0] - turn[0, 1]])
            turn = _rotation(axis / np.linalg.norm(axis) * largest)
        corrected.append(turn @ s.R)
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


def _body_keep(d, R):
    """Weight (0 to 1) for a floor shot's view of world directions `d`: 0 where the person
    holding the phone is in the way. `R` is the shot's camera-to-world rotation."""
    toward = np.array([R[0, 0], 0.0, R[2, 0]])
    length = np.linalg.norm(toward)
    if length < 1e-6:
        return np.ones(d.shape[:2], np.float32)
    drop = np.maximum(-d[..., 1], 1e-6)
    offset = (d @ (toward / length)) / drop
    t = np.clip((offset - BODY_START) / (BODY_FULL - BODY_START), 0, 1)
    return np.where(d[..., 1] < 0, 1 - t * t * (3 - 2 * t), 1).astype(np.float32)


def _fill(image, holes):
    """Paints `holes` with the blurred colours around them. Used where nothing was
    photographed: mostly the floor behind the person, which no shot can see."""
    import cv2
    height, width = holes.shape
    small = (width // FILL_SHRINK, height // FILL_SHRINK)
    valid = cv2.resize((~holes).astype(np.float32), small, interpolation=cv2.INTER_AREA)
    colour = cv2.resize(image.astype(np.float32) * (~holes)[..., None], small, interpolation=cv2.INTER_AREA)
    colour = np.clip(colour / np.maximum(valid, 1e-3)[..., None] + 0.5, 0, 255).astype(np.uint8)
    missing = (valid < 0.5).astype(np.uint8)
    # The panorama wraps around, so let the fill see across the left and right edges.
    pad = small[0] // 4
    colour = np.concatenate([colour[:, -pad:], colour, colour[:, :pad]], 1)
    missing = np.concatenate([missing[:, -pad:], missing, missing[:, :pad]], 1)
    filled = cv2.inpaint(colour, missing, 5, cv2.INPAINT_TELEA)
    filled = cv2.GaussianBlur(filled, (0, 0), 6, borderType=cv2.BORDER_REPLICATE)[:, pad:-pad]
    rows = filled.shape[0]
    pitch = np.pi / 2 - (np.arange(rows) + 0.5) / rows * np.pi
    sigma = FILL_BLUR / (2 * np.pi) * small[0] / np.maximum(np.cos(pitch), 0.02)
    for row in range(rows):
        if sigma[row] > 6:
            line = np.tile(filled[row][None], (1, 3, 1))  # wrap around the panorama
            line = cv2.GaussianBlur(line, (0, 0), min(float(sigma[row]), small[0] / 2), sigmaY=0.01)
            filled[row] = line[0, small[0]:2 * small[0]]
    filled = cv2.resize(filled, (width, height), interpolation=cv2.INTER_CUBIC)
    # Soften the border only on the filled side, so photographed pixels stay sharp.
    alpha = cv2.GaussianBlur(holes.astype(np.float32), (0, 0), FILL_SHRINK)
    alpha = np.where(holes, np.clip(alpha * 2, 0, 1), 0)[..., None]
    return np.clip(image * (1 - alpha) + filled * alpha + 0.5, 0, 255).astype(np.uint8)


def stitch(slices, width=4096, refine=True):
    """Returns (equirect BGR uint8 of width × width/2, hole fraction above the nadir disc).

    A spot of level shots only leaves the ceiling and floor unphotographed. They are filled
    with blurred colour from the edge of what was photographed and are not holes: holes are
    counted in the band of rows the shots mostly cover (see BAND_SHARE).

    A floor shot, if the spot has one, is used only where no other slice reaches and only on
    the side away from the person holding the phone, so they stay out of the panorama. The
    floor behind them is filled the same way and is not counted either, and a neutral disc
    below −80° pitch hides the floor under their feet."""
    import cv2
    height = width // 2
    images = _images(slices)
    rotations = refine_rotations(slices, images=images) if refine else [s.R for s in slices]
    gains = exposure_gains(slices, rotations, images=images)
    out = np.zeros((height, width, 3), np.float32)
    covered = np.zeros((height, width), bool)
    hidden = np.zeros((height, width), bool)
    for top in range(0, height, BLOCK_ROWS):
        rows = np.arange(top, min(height, top + BLOCK_ROWS))
        d = directions(width, height, rows)
        # [0] the slices taken with the person behind the camera, [1] floor shots.
        acc = [np.zeros(d.shape, np.float32), np.zeros(d.shape, np.float32)]
        weight = [np.zeros(d.shape[:2], np.float32), np.zeros(d.shape[:2], np.float32)]
        behind = np.zeros(d.shape[:2], bool)
        for s, image, R, gain in zip(slices, images, rotations, gains):
            u, v, inside = _project(d, s.K, R, s.width, s.height)
            if not inside.any():
                continue
            w = np.where(inside, _feather(u, v, s.width, s.height), 0).astype(np.float32)
            down = int(R[1, 2] < np.sin(DOWN_PITCH))
            if down:
                keep = _body_keep(d, R)
                behind |= inside & (keep < 1)
                w *= keep
            # Sample the 8-bit slice and widen only this block, so peak memory stays near the
            # decoded slices themselves rather than float copies of every one.
            sample = cv2.remap(image, (u - 0.5).astype(np.float32), (v - 0.5).astype(np.float32),
                               cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
            acc[down] += sample.astype(np.float32) * (w * gain)[..., None]
            weight[down] += w
        level = acc[0] / np.maximum(weight[0], 1e-6)[..., None]
        floor = acc[1] / np.maximum(weight[1], 1e-6)[..., None]
        share = np.where(weight[1] > 1e-6, np.clip(weight[0] / LEVEL_FULL, 0, 1), 1)[..., None]
        has = (weight[0] > 1e-6) | (weight[1] > 1e-6)
        out[rows] = np.where(has[..., None], level * share + floor * (1 - share), 0)
        covered[rows] = has
        hidden[rows] = behind & ~has
    pitch = np.pi / 2 - (np.arange(height) + 0.5) / height * np.pi
    above = np.repeat((pitch >= NADIR_PITCH)[:, None], width, 1)
    band = above & (covered.mean(1) >= BAND_SHARE)[:, None]
    holes = band & ~covered & ~hidden
    hole_fraction = float(holes.sum() / band.sum()) if band.any() else 1.0
    image = np.clip(out + 0.5, 0, 255).astype(np.uint8)
    if not covered.all():
        image = _fill(image, ~covered)
    if any(R[1, 2] < np.sin(DOWN_PITCH) for R in rotations):
        # The neutral disc: solid below −82°, blended over the 2° above it.
        alpha = np.clip((NADIR_PITCH - pitch) / NADIR_FEATHER, 0, 1)[:, None, None]
        alpha = np.where((~covered & ~above)[..., None], 1, np.broadcast_to(alpha, (height, width, 1)))
        disc = np.array(NADIR_BGR, np.float32)
        image = np.clip(image * (1 - alpha) + disc * alpha + 0.5, 0, 255).astype(np.uint8)
    return image, hole_fraction
