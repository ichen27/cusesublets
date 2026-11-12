"""Synthetic spot captures for tests and transport checks: a procedural textured sphere rendered
into portrait-phone slices at the app's dot layout. Not evidence of real-room quality."""
import numpy as np

SLICE_WIDTH, SLICE_HEIGHT, FOCAL = 1440, 1080, 1100.0
FLIP = np.diag([1.0, -1.0, -1.0])  # ARKit camera axes <-> OpenCV camera axes


def layout(ring_pitch_degrees=50.0):
    """(yaw, pitch) of every dot, matching SpotLayout.standard in the iPhone app."""
    p = np.radians(ring_pitch_degrees)
    return ([(i * np.pi / 6, 0.0) for i in range(12)] + [(i * np.pi / 4, p) for i in range(8)]
            + [(i * np.pi / 4, -p) for i in range(8)] + [(0.0, np.pi / 2)])


def arkit_rotation(yaw, pitch, roll=0.0):
    """ARKit camera-to-world rotation for a phone held upright (portrait) looking at yaw/pitch.
    Yaw follows ARKit: 0 faces −Z, positive turns left. Roll turns about the optical axis."""
    f = np.array([-np.sin(yaw) * np.cos(pitch), np.sin(pitch), -np.cos(yaw) * np.cos(pitch)])
    reference = np.array([0.0, 1.0, 0.0]) if abs(pitch) < 1.5 else np.array([np.sin(yaw), 0.0, np.cos(yaw)])
    right = np.cross(f, reference)
    right /= np.linalg.norm(right)
    up = np.cross(right, f)
    # Portrait: the landscape sensor's +x points down the screen, its +y points right.
    x, y = -up, right
    if roll:
        c, s = np.cos(roll), np.sin(roll)
        x, y = c * x + s * y, -s * x + c * y
    return np.stack([x, y, -f], 1)


def rotation_noise(rng, count, degrees):
    """Small random rotations with zero mean axis-angle, so the set is right on average."""
    from scipy.spatial.transform import Rotation
    vectors = rng.normal(size=(count, 3))
    vectors /= np.linalg.norm(vectors, axis=1, keepdims=True)
    vectors *= np.radians(degrees)
    vectors -= vectors.mean(0)
    return Rotation.from_rotvec(vectors).as_matrix()


def test_sphere(width=4096, seed=7):
    """Equirect BGR texture with corners for features: a 15° checkerboard over smooth colour."""
    import cv2
    rng = np.random.default_rng(seed)
    height = width // 2
    low = rng.uniform(40, 215, size=(16, 32, 3)).astype(np.float32)
    colour = cv2.resize(low, (width, height), interpolation=cv2.INTER_CUBIC)
    u = (np.arange(width) + 0.5) / width * 360
    v = (np.arange(height) + 0.5) / height * 180
    checks = ((u[None, :] // 15).astype(int) + (v[:, None] // 15).astype(int)) % 2
    image = colour * (0.65 + 0.35 * checks[..., None])
    for _ in range(400):
        x, y = int(rng.uniform(0, width)), int(rng.uniform(0, height))
        cv2.circle(image, (x, y), int(rng.uniform(4, 14)) * width // 4096,
                   tuple(float(c) for c in rng.uniform(0, 255, 3)), -1)
    image = cv2.GaussianBlur(image, (0, 0), 1.2 * width / 4096)
    return np.clip(image, 0, 255).astype(np.uint8)


def render_slice(sphere, rotation_arkit, width=SLICE_WIDTH, height=SLICE_HEIGHT, focal=FOCAL):
    """What a pinhole camera with this ARKit rotation sees of the sphere at infinity."""
    import cv2
    h, w = sphere.shape[:2]
    us, vs = np.meshgrid(np.arange(width) + 0.5, np.arange(height) + 0.5)
    rays = np.stack([(us - width / 2) / focal, (vs - height / 2) / focal, np.ones_like(us)], -1)
    d = rays @ (rotation_arkit @ FLIP).T
    d /= np.linalg.norm(d, axis=-1, keepdims=True)
    yaw = np.arctan2(d[..., 0], -d[..., 2])
    pitch = np.arcsin(np.clip(d[..., 1], -1, 1))
    map_x = ((yaw / (2 * np.pi) + 0.5) * w - 0.5).astype(np.float32)
    map_y = ((0.5 - pitch / np.pi) * h - 0.5).astype(np.float32)
    return cv2.remap(sphere, map_x, map_y, cv2.INTER_LINEAR, borderMode=cv2.BORDER_WRAP)


def frame_record(path, rotation_arkit, position=(0.0, 0.0, 0.0), spot=None, role='slice',
                 width=SLICE_WIDTH, height=SLICE_HEIGHT, focal=FOCAL):
    """A manifest frame record as the iPhone writes it (row-major camera-to-world)."""
    m = np.eye(4)
    m[:3, :3] = rotation_arkit
    m[:3, 3] = position
    record = {'file_path': path, 'timestamp': 0.0, 'width': width, 'height': height, 'fx': focal,
              'fy': focal, 'cx': width / 2, 'cy': height / 2, 'transform_matrix': m.tolist(),
              'tracking': 'normal', 'points': [], 'role': role}
    if spot is not None:
        record['spot'] = spot
    return record
