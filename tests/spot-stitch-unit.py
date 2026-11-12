"""Panorama stitching on synthetic spheres. Needs processing/requirements-spots.txt."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

import cv2
import numpy as np


def load(name):
    spec = importlib.util.spec_from_file_location(name, f'processing/{name}.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ss = load('spot_stitch')
syn = load('spot_synthetic')
WIDTH = 2048  # half the production width keeps the suite quick; the math is resolution-free
SPHERE = syn.test_sphere(WIDTH)


def psnr(a, b, mask):
    error = np.mean((a[mask].astype(np.float64) - b[mask].astype(np.float64)) ** 2)
    return 10 * np.log10(255 ** 2 / max(error, 1e-9))


def above_nadir(width=WIDTH):
    rows = 90 - (np.arange(width // 2) + 0.5) / (width // 2) * 180
    return np.repeat((rows > -80)[:, None], width, 1)


class Capture:
    """Writes one synthetic spot to disk and returns its Slice list."""

    def __init__(self, root, rotations=None, noise=None, brighten=None, drop_ring=None, roll=0.0):
        self.root = Path(root)
        (self.root / 'images').mkdir(parents=True, exist_ok=True)
        targets = syn.layout()
        true = [syn.arkit_rotation(y, p, roll) for y, p in targets]
        self.frames = []
        for index, rotation in enumerate(true):
            ring = 0 if index < 12 else 1 if index < 20 else 2 if index < 28 else 3
            if ring == drop_ring:
                continue
            path = f'images/{len(self.frames):05d}.jpg'
            image = syn.render_slice(SPHERE, rotation)
            if brighten and index in brighten:
                image = np.clip(image.astype(np.float32) * brighten[index], 0, 255).astype(np.uint8)
            cv2.imwrite(str(self.root / path), image, [cv2.IMWRITE_JPEG_QUALITY, 95])
            reported = rotation if noise is None else noise[index] @ rotation
            self.frames.append(syn.frame_record(path, reported, spot=1))
        self.manifest = {'schema_version': 2, 'capture': 'spots', 'frames': self.frames,
                         'spots': [{'spot': 1, 'slices': [f['file_path'] for f in self.frames],
                                    'position': [0, 0, 0], 'floor_y': -1.4, 'start_yaw': 0,
                                    'exposure_duration': 0.01, 'iso': 200}]}

    def slices(self):
        return ss.load_spot_slices(self.manifest, self.root)[1]


class Stitching(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def test_stitch_recovers_sphere(self):
        image, holes = ss.stitch(Capture(self.root).slices(), width=WIDTH, refine=False)
        self.assertEqual(image.shape, (WIDTH // 2, WIDTH, 3))
        self.assertEqual(holes, 0)
        self.assertGreaterEqual(psnr(image, SPHERE, above_nadir()), 30)

    def test_nadir_is_a_neutral_disc(self):
        image, _ = ss.stitch(Capture(self.root).slices(), width=WIDTH, refine=False)
        bottom = image[-5:].reshape(-1, 3).mean(0)
        np.testing.assert_allclose(bottom, ss.NADIR_BGR, atol=3)

    def test_refinement_fixes_pose_noise(self):
        noise = syn.rotation_noise(np.random.default_rng(3), 29, 1.5)
        slices = Capture(self.root, noise=noise).slices()
        raw, _ = ss.stitch(slices, width=WIDTH, refine=False)
        refined, _ = ss.stitch(slices, width=WIDTH, refine=True)
        before, after = psnr(raw, SPHERE, above_nadir()), psnr(refined, SPHERE, above_nadir())
        self.assertGreaterEqual(after, 26)
        self.assertGreater(after, before)

    def test_refinement_corrections_are_clamped(self):
        slices = Capture(self.root).slices()
        rotations = ss.refine_rotations(slices, max_correction_deg=3.0)
        for s, r in zip(slices, rotations):
            angle = np.degrees(np.arccos(np.clip((np.trace(r @ s.R.T) - 1) / 2, -1, 1)))
            self.assertLessEqual(angle, 3.0 + 1e-6)

    def test_exposure_gains_equalise(self):
        slices = Capture(self.root, brighten={5: 1.3}).slices()
        gains = ss.exposure_gains(slices, [s.R for s in slices])
        self.assertAlmostEqual(gains.mean(), 1, places=6)
        self.assertAlmostEqual(gains[5] / np.median(gains), 1 / 1.3, delta=0.05)

    def test_rolled_slices_stitch(self):
        image, holes = ss.stitch(Capture(self.root, roll=np.radians(20)).slices(), width=WIDTH,
                                 refine=False)
        self.assertLessEqual(holes, ss.MAX_HOLES)
        self.assertGreaterEqual(psnr(image, SPHERE, above_nadir()), 30)

    def test_missing_ring_reports_holes(self):
        _, holes = ss.stitch(Capture(self.root, drop_ring=1).slices(), width=WIDTH, refine=False)
        self.assertGreater(holes, ss.MAX_HOLES)


class Loading(unittest.TestCase):
    def manifest(self, **spot):
        frames = [syn.frame_record(f'images/{i:05d}.jpg', np.eye(3), spot=1 if i < 2 else 2)
                  for i in range(4)]
        return {'frames': frames, 'spots': [{'spot': 1, 'slices': ['images/00000.jpg',
                                                                   'images/00001.jpg'], **spot}]}

    def test_ignores_slices_of_unfinished_spots(self):
        with tempfile.TemporaryDirectory() as root:
            spots = ss.load_spot_slices(self.manifest(), Path(root))
        self.assertEqual(list(spots), [1])
        self.assertEqual([s.path.name for s in spots[1]], ['00000.jpg', '00001.jpg'])

    def test_converts_arkit_axes_to_opencv(self):
        with tempfile.TemporaryDirectory() as root:
            s = ss.load_spot_slices(self.manifest(), Path(root))[1][0]
        # ARKit identity looks along −Z; in OpenCV axes the optical axis (+Z) must map to −Z.
        np.testing.assert_allclose(s.R @ [0, 0, 1], [0, 0, -1], atol=1e-9)
        np.testing.assert_allclose(s.K, [[1100, 0, 720], [0, 1100, 540], [0, 0, 1]])

    def test_rejects_escaping_paths(self):
        for bad in ['../secret.jpg', 'images/../../x.jpg', '/etc/passwd', 'images/1.jpg']:
            m = self.manifest()
            m['spots'][0]['slices'] = [bad]
            with tempfile.TemporaryDirectory() as root, self.assertRaisesRegex(ValueError, 'capture_invalid'):
                ss.load_spot_slices(m, Path(root))

    def test_rejects_slices_missing_from_frames(self):
        m = self.manifest()
        m['spots'][0]['slices'] = ['images/00009.jpg']
        with tempfile.TemporaryDirectory() as root, self.assertRaisesRegex(ValueError, 'capture_invalid'):
            ss.load_spot_slices(m, Path(root))


class Equirect(unittest.TestCase):
    def test_yaw_zero_is_minus_z_and_clockwise_increases_column(self):
        d = ss.directions(8, 4)
        mid = d[2, 4]  # just below the horizon, at yaw ≈ 0 (column W/2)
        self.assertLess(mid[2], 0)
        right = d[2, 6]  # further right in the image: yaw > 0, towards +X
        self.assertGreater(right[0], 0)


if __name__ == '__main__':
    unittest.main()
