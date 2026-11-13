"""Panorama stitching on synthetic spheres. Needs processing/requirements-spots.txt."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

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


def photographed(slices, width=WIDTH):
    """Above the nadir disc, minus the floor behind the person, which is filled in rather than
    photographed: the floor shot's person side, below where the level shots reach."""
    d = ss.directions(width, width // 2)
    mask = above_nadir(width)
    for s in slices:
        if s.R[1, 2] < np.sin(ss.DOWN_PITCH):
            mask &= ~((ss._body_keep(d, s.R) < 1) & (d[..., 1] < -np.sin(np.radians(45))))
    if not any(abs(s.R[1, 2]) > 0.5 for s in slices):
        # Level shots only: they reach 54° up and down at their centres, less between them.
        mask &= np.abs(d[..., 1]) < np.sin(np.radians(45))
    return mask


PERSON_BGR = (0, 0, 255)


class Capture:
    """Writes one synthetic spot to disk and returns its Slice list."""

    def __init__(self, root, rotations=None, noise=None, brighten=None, drop=None, roll=0.0,
                 person=False, poles=False):
        self.root = Path(root)
        (self.root / 'images').mkdir(parents=True, exist_ok=True)
        # The app's spots are six level shots; earlier builds added the ceiling and the floor.
        targets = syn.layout(poles or person)
        true = [syn.arkit_rotation(y, p, roll) for y, p in targets]
        self.frames = []
        for index, rotation in enumerate(true):
            ring = 0 if index < 6 else index - 5  # level ring, then ceiling (1), floor (2)
            if index == drop:
                continue
            path = f'images/{len(self.frames):05d}.jpg'
            image = syn.render_slice(SPHERE, rotation)
            if person and ring == 2:
                # Legs fill the floor shot from just past straight down to the phone's bottom edge.
                image[:, syn.SLICE_WIDTH // 2 + 100:] = PERSON_BGR
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
        slices = Capture(self.root).slices()
        image, holes = ss.stitch(slices, width=WIDTH, refine=False)
        self.assertEqual(image.shape, (WIDTH // 2, WIDTH, 3))
        # Only slivers at the scalloped top and bottom edges of the level band.
        self.assertLess(holes, 0.005)
        self.assertGreaterEqual(psnr(image, SPHERE, photographed(slices)), 30)

    def test_the_person_holding_the_phone_is_left_out(self):
        slices = Capture(self.root, person=True).slices()
        image, holes = ss.stitch(slices, width=WIDTH, refine=False)

        def red(picture):
            b, g, r = (picture[..., i].astype(int) for i in range(3))
            return int(((r > 180) & (g < 80) & (b < 80)).sum())

        # The legs cover a sixth of the floor shot; none of that red may arrive. (The sphere
        # has a few red marks of its own.)
        self.assertLessEqual(red(image), red(SPHERE) + 50)
        # The floor behind them is filled in, not reported as a failed capture.
        self.assertEqual(holes, 0)
        self.assertGreaterEqual(psnr(image, SPHERE, photographed(slices)), 30)

    def test_the_floor_behind_the_person_is_filled_smoothly(self):
        slices = Capture(self.root, person=True).slices()
        image, _ = ss.stitch(slices, width=WIDTH, refine=False)
        # Well below the level shots' reach (54° down), on the person's side of the floor shot.
        d = ss.directions(WIDTH, WIDTH // 2)
        filled = above_nadir() & (ss._body_keep(d, slices[-1].R) == 0) & (d[..., 1] < -np.sin(np.radians(58)))
        self.assertGreater(int(filled.sum()), 0)
        # No black or unpainted pixels, and none of the checkerboard's hard edges.
        self.assertGreater(int(image[filled].min(axis=-1).min()), 20)
        edges = np.abs(np.diff(image.astype(int), axis=1)).max(-1)
        self.assertLess(float(edges[filled[:, 1:] & filled[:, :-1]].mean()), 3)

    def test_nadir_is_a_neutral_disc_when_there_is_a_floor_shot(self):
        image, _ = ss.stitch(Capture(self.root, poles=True).slices(), width=WIDTH, refine=False)
        bottom = image[-5:].reshape(-1, 3).mean(0)
        np.testing.assert_allclose(bottom, ss.NADIR_BGR, atol=3)

    def test_refinement_fixes_pose_noise(self):
        noise = syn.rotation_noise(np.random.default_rng(3), len(syn.layout()), 1.5)
        slices = Capture(self.root, noise=noise).slices()
        raw, _ = ss.stitch(slices, width=WIDTH, refine=False)
        refined, _ = ss.stitch(slices, width=WIDTH, refine=True)
        seen = photographed(slices)
        before, after = psnr(raw, SPHERE, seen), psnr(refined, SPHERE, seen)
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
        slices = Capture(self.root, roll=np.radians(20)).slices()
        image, holes = ss.stitch(slices, width=WIDTH, refine=False)
        self.assertLessEqual(holes, ss.MAX_HOLES)
        self.assertGreaterEqual(psnr(image, SPHERE, photographed(slices)), 30)

    def test_refinement_compares_each_slice_with_few_neighbours(self):
        # 24 slices all facing nearly the same way could pair 276 times; the cap keeps it linear.
        capture = Capture(self.root)
        frame = capture.frames[0]
        capture.manifest['frames'] = [dict(frame) for _ in range(24)]
        slices = [ss.load_spot_slices({**capture.manifest, 'spots': [
            {**capture.manifest['spots'][0], 'slices': [frame['file_path']]}]}, self.root)[1][0]] * 24
        calls = []
        original = ss._project
        ss._project = lambda *a: calls.append(1) or original(*a)
        try:
            ss.refine_rotations(slices)
        finally:
            ss._project = original
        self.assertLessEqual(len(calls), 2 * 24 * ss.MAX_NEIGHBOURS)

    def test_impossible_intrinsics_are_refused(self):
        for change in ({'fx': 1.0}, {'fy': float('nan')}, {'cx': -5.0}, {'cy': 1e9}, {'fx': 'wide'}):
            capture = Capture(self.root)
            capture.frames[0].update(change)
            with self.assertRaisesRegex(ValueError, 'capture_invalid'):
                capture.slices()

    def test_a_missing_level_shot_fails(self):
        _, holes = ss.stitch(Capture(self.root, drop=2).slices(), width=WIDTH, refine=False)
        self.assertGreater(holes, ss.MAX_HOLES)

    def test_two_missing_level_shots_fail(self):
        capture = Capture(self.root)
        slices = [s for i, s in enumerate(capture.slices()) if i not in (2, 3)]
        self.assertGreater(ss.stitch(slices, width=WIDTH, refine=False)[1], ss.MAX_HOLES)

    def test_level_shots_alone_leave_a_soft_top_and_bottom_not_holes(self):
        image, holes = ss.stitch(Capture(self.root).slices(), width=WIDTH, refine=False)
        self.assertLessEqual(holes, ss.MAX_HOLES)
        for rows in (slice(0, WIDTH // 16), slice(-WIDTH // 16, None)):
            cap = image[rows].astype(int)
            # Painted, with no dark disc and none of the checkerboard's hard edges.
            self.assertGreater(int(cap.min()), 20)
            self.assertLess(float(np.abs(np.diff(cap, axis=1)).max(-1).mean()), 2)
        self.assertFalse(np.all(np.abs(image[-1].astype(int) - np.array(ss.NADIR_BGR)) <= 2))

    def test_earlier_builds_ceiling_and_floor_shots_still_stitch(self):
        slices = Capture(self.root, poles=True).slices()
        image, holes = ss.stitch(slices, width=WIDTH, refine=False)
        self.assertEqual(len(slices), 8)
        self.assertEqual(holes, 0)
        self.assertGreaterEqual(psnr(image, SPHERE, photographed(slices)), 30)


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
        np.testing.assert_allclose(s.K, [[700, 0, 960], [0, 700, 720], [0, 0, 1]])

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


class Bounds(unittest.TestCase):
    """A crafted manifest must not amplify work beyond what a real capture can need."""

    def manifest(self, spots, frames=8, width=1440, height=1080):
        records = [syn.frame_record(f'images/{i:05d}.jpg', np.eye(3), spot=1, width=width, height=height)
                   for i in range(frames)]
        return {'frames': records, 'spots': spots}

    def check(self, manifest):
        with tempfile.TemporaryDirectory() as root, self.assertRaisesRegex(ValueError, 'capture_invalid'):
            ss.load_spot_slices(manifest, Path(root))

    def test_rejects_a_slice_listed_twice(self):
        self.check(self.manifest([{'spot': 1, 'slices': ['images/00000.jpg', 'images/00000.jpg']}]))

    def test_rejects_a_slice_shared_by_two_spots(self):
        self.check(self.manifest([{'spot': 1, 'slices': ['images/00000.jpg']},
                                  {'spot': 2, 'slices': ['images/00000.jpg']}]))

    def test_rejects_more_slices_than_a_spot_can_have(self):
        names = [f'images/{i:05d}.jpg' for i in range(ss.MAX_SLICES + 1)]
        self.check(self.manifest([{'spot': 1, 'slices': names}], frames=ss.MAX_SLICES + 1))

    def test_rejects_more_spots_than_a_tour_can_have(self):
        spots = [{'spot': n, 'slices': [f'images/{n:05d}.jpg']} for n in range(ss.MAX_SPOTS + 1)]
        self.check(self.manifest(spots, frames=ss.MAX_SPOTS + 1))

    def test_rejects_oversized_declared_images(self):
        self.check(self.manifest([{'spot': 1, 'slices': ['images/00000.jpg']}], width=8000, height=6000))

    def test_rejects_an_image_larger_than_declared_before_decoding(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            (root / 'images').mkdir()
            cv2.imwrite(str(root / 'images/00000.jpg'), np.zeros((1200, 1600, 3), np.uint8))
            m = self.manifest([{'spot': 1, 'slices': ['images/00000.jpg']}], frames=1)
            slices = ss.load_spot_slices(m, root)[1]
            with patch.object(cv2, 'imdecode', side_effect=AssertionError('decoded')), \
                    patch.object(cv2, 'imread', side_effect=AssertionError('decoded')):
                with self.assertRaisesRegex(ValueError, 'capture_invalid'):
                    ss._images(slices)

    def test_rejects_images_wider_than_the_app_saves(self):
        self.check(self.manifest([{'spot': 1, 'slices': ['images/00000.jpg']}], width=2400, height=1800))

    def test_rejects_a_spot_over_the_pixel_budget(self):
        # Each slice is within bounds, but together they exceed what one spot may decode.
        count = ss.MAX_SPOT_PIXELS // (1920 * 1440) + 1
        names = [f'images/{i:05d}.jpg' for i in range(count)]
        self.check(self.manifest([{'spot': 1, 'slices': names}], frames=count, width=1920, height=1440))

    def test_header_reader_skips_fill_bytes_like_libjpeg(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'x.jpg'
            ok, jpeg = cv2.imencode('.jpg', np.zeros((108, 144, 3), np.uint8))
            data = jpeg.tobytes()
            path.write_bytes(data[:2] + b'\xff\xff\xff' + data[2:])  # fill bytes before the next marker
            self.assertEqual(ss.jpeg_size(path), (144, 108))
            self.assertEqual(ss.jpeg_size_bytes(path.read_bytes()), (144, 108))

    def test_decoder_refuses_images_over_the_pixel_cap(self):
        import os
        self.assertEqual(int(os.environ['OPENCV_IO_MAX_IMAGE_PIXELS']), ss.MAX_SIDE * ss.MAX_SIDE)

    def test_reads_jpeg_dimensions_from_the_header(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'x.jpg'
            cv2.imwrite(str(path), np.zeros((108, 144, 3), np.uint8))
            self.assertEqual(ss.jpeg_size(path), (144, 108))
            path.write_bytes(b'not a jpeg')
            self.assertIsNone(ss.jpeg_size(path))


class Equirect(unittest.TestCase):
    def test_yaw_zero_is_minus_z_and_clockwise_increases_column(self):
        d = ss.directions(8, 4)
        mid = d[2, 4]  # just below the horizon, at yaw ≈ 0 (column W/2)
        self.assertLess(mid[2], 0)
        right = d[2, 6]  # further right in the image: yaw > 0, towards +X
        self.assertGreater(right[0], 0)


if __name__ == '__main__':
    unittest.main()
