"""Panorama stitching on synthetic spheres. Needs processing/requirements-spots.txt."""
import importlib.util
import json
import tarfile
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
se = load('spot_enhance')
tw = load('tour_worker')
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
                 person=False, poles=False, scenes=None, zoom=1.0, shade=None):
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
            # `scenes` gives single shots their own surroundings, as when they disagree.
            # `zoom` enlarges what every shot sees without saying so, as a room does when the
            # phone swings on the arm: neighbours then disagree however they are turned.
            image = syn.render_slice((scenes or {}).get(index, SPHERE), rotation, focal=syn.FOCAL * zoom)
            if person and ring == 2:
                # Legs fill the floor shot from just past straight down to the phone's bottom edge.
                image[:, syn.SLICE_WIDTH // 2 + 100:] = PERSON_BGR
            if shade:
                # Brighter towards one side of every shot and darker towards the other, by
                # this share, as uneven room light does. No single gain per shot undoes it.
                ramp = np.linspace(1 + shade, 1 - shade, image.shape[0])[:, None, None]
                image = np.clip(image * ramp, 0, 255).astype(np.uint8)
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

    def test_refinement_never_turns_a_shot_more_than_its_limit(self):
        slices = Capture(self.root).slices()
        rotations = ss.refine_rotations(slices, max_correction_deg=3.0)
        for s, r in zip(slices, rotations):
            angle = np.degrees(np.arccos(np.clip((np.trace(r @ s.R.T) - 1) / 2, -1, 1)))
            self.assertLessEqual(angle, 3.0 + 1e-6)

    def test_refinement_leaves_shots_alone_when_turning_them_cannot_make_them_agree(self):
        slices = Capture(self.root, zoom=1.15).slices()
        for s, r in zip(slices, ss.refine_rotations(slices)):
            np.testing.assert_array_equal(r, s.R)

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

    def test_an_object_two_shots_place_differently_is_drawn_solid_not_as_a_ghost(self):
        # A hand-held phone swings on the arm, so neighbouring shots see a near object in
        # different places. Here shot 0 has a post 26° left of ahead and shot 1 has it at 34°.
        post = np.array((255, 0, 255))
        rows = slice(*(int((90 - p) / 180 * (WIDTH // 2)) for p in (25, -25)))

        def columns(low, high):
            return slice(*(int((yaw + 180) / 360 * WIDTH) for yaw in (low, high)))

        scenes = {}
        for shot, where in ((0, columns(-28, -24)), (1, columns(-36, -32))):
            scenes[shot] = SPHERE.copy()
            scenes[shot][rows, where] = post
        image, _ = ss.stitch(Capture(self.root, scenes=scenes).slices(), width=WIDTH, refine=False)
        window = image[rows, columns(-38, -22)].astype(int)
        truth = SPHERE[rows, columns(-38, -22)].astype(int)
        # A ghost is neither the post nor what is behind it.
        ghost = (np.abs(window - post).max(-1) > 25) & (np.abs(window - truth).max(-1) > 25)
        one_post = (rows.stop - rows.start) * (columns(-28, -24).stop - columns(-28, -24).start)
        self.assertLess(int(ghost.sum()), 0.3 * one_post)

    def test_shots_lit_differently_meet_without_a_visible_step(self):
        slices = Capture(self.root, shade=0.1).slices()
        image, _ = ss.stitch(slices, width=WIDTH, refine=False)
        rows = slice(*(int((90 - p) / 180 * (WIDTH // 2)) for p in (25, -25)))

        def columns(picture):
            # Brightness of each column, averaged with its neighbours so that the sphere's own
            # hard edges, which a stitch softens a little, do not count as steps.
            return np.convolve(np.tile(picture[rows].mean((0, 2)), 3), np.ones(9) / 9, 'same')[WIDTH:2 * WIDTH]

        # Against the truth, brightness ramps across every shot. Where two shots meet it has to
        # come back up, and must do so gradually.
        level = columns(image) / columns(SPHERE)
        self.assertGreater(float(level.max() - level.min()), 0.1)
        step = np.abs(np.diff(np.r_[level, level[:1]]))
        self.assertLess(float(step.max()), 0.008)


class Seams(unittest.TestCase):
    """`_seams` on a toy panorama: 48 rows, 128 columns, two shots that overlap in columns
    48 to 79. Each shot's weight peaks at its own middle, like the stitcher's feathering."""

    def shots(self, shift=0):
        columns = np.arange(128)
        left = np.where(columns < 80, 40 - np.abs(columns - 39.5), 0).clip(0) / 40
        right = np.where(columns >= 48, 40 - np.abs(columns - 87.5), 0).clip(0) / 40
        weights = [np.tile(w.astype(np.float32), (48, 1)) for w in (left, right)]
        scene = np.tile(np.linspace(60, 180, 128, dtype=np.float32)[None, :, None], (48, 1, 3))
        colours = [scene.copy(), scene.copy()]
        return [np.roll(c, shift, 1) for c in colours], [np.roll(w, shift, 1) for w in weights]

    def test_shots_that_agree_meet_in_the_middle_of_their_overlap(self):
        colours, weights = self.shots()
        owner = ss._seams(colours, weights)
        self.assertTrue((owner[:, :63] == 0).all())
        self.assertTrue((owner[:, 65:] == 1).all())

    def test_the_cut_goes_round_an_object_the_shots_disagree_about(self):
        colours, weights = self.shots()
        # Only the left shot sees this object, right where the middle of the overlap runs.
        colours[0][14:34, 58:70] = 0
        owner = ss._seams(colours, weights)
        self.assertEqual(len(np.unique(owner[14:34, 58:70])), 1)
        # Away from it the shots still meet in the middle.
        self.assertTrue((owner[:6, :63] == 0).all() and (owner[:6, 65:] == 1).all())

    def test_seams_do_not_depend_on_where_the_panorama_wraps(self):
        colours, weights = self.shots()
        colours[0][14:34, 58:70] = 0
        owner = ss._seams(colours, weights)
        # Turned so the overlap straddles the panorama's left and right edges.
        turned = [np.roll(c, 64, 1) for c in colours], [np.roll(w, 64, 1) for w in weights]
        np.testing.assert_array_equal(ss._seams(*turned), np.roll(owner, 64, 1))

    def test_every_photographed_pixel_goes_to_one_shot_that_sees_it(self):
        colours, weights = self.shots()
        # A third shot across the top overlaps both, and nothing sees the bottom rows.
        top = np.zeros((48, 128), np.float32)
        top[:20] = 0.5
        weights = [np.where(np.arange(48)[:, None] < 40, w, 0).astype(np.float32) for w in weights] + [top]
        colours.append(colours[0] + 30)
        owner = ss._seams(colours, weights)
        seen = np.stack(weights) > 0
        np.testing.assert_array_equal(owner >= 0, seen.any(0))
        self.assertTrue(np.take_along_axis(seen, owner.clip(0)[None], 0)[0][owner >= 0].all())
        self.assertTrue((owner[40:] == -1).all())


class Finishing(unittest.TestCase):
    """The streaks above and below what was photographed, and the sharpening pass."""

    def band(self, width=512):
        """A panorama photographed only in its middle third: red on the left, blue on the right."""
        height = width // 2
        image = np.zeros((height, width, 3), np.uint8)
        covered = np.zeros((height, width), bool)
        covered[height // 3: 2 * height // 3] = True
        image[covered] = (0, 0, 200)
        image[height // 3: 2 * height // 3, width // 2:] = (200, 0, 0)
        return image, covered

    def test_each_direction_keeps_its_edge_colour_and_all_meet_at_the_pole(self):
        image, covered = self.band()
        painted = ss._caps(image, covered)
        height, width = covered.shape
        self.assertTrue(np.array_equal(painted, ~covered))
        for row in (height // 3 - 3, 2 * height // 3 + 3):
            # Just past the edge: still the colour of that side.
            np.testing.assert_allclose(image[row, width // 4], (0, 0, 200), atol=12)
            np.testing.assert_allclose(image[row, 3 * width // 4], (200, 0, 0), atol=12)
        for row in (0, height - 1):
            # At the pole every direction has blended into one colour.
            np.testing.assert_allclose(image[row, width // 4], image[row, 3 * width // 4], atol=12)
            np.testing.assert_allclose(image[row, width // 4], (100, 0, 100), atol=20)

    def test_streaks_leave_photographed_pixels_alone(self):
        image, covered = self.band()
        before = image.copy()
        ss._caps(image, covered)
        self.assertTrue(np.array_equal(image[covered], before[covered]))

    def test_a_fully_photographed_panorama_gets_no_streaks(self):
        image = np.full((64, 128, 3), 90, np.uint8)
        self.assertFalse(ss._caps(image, np.ones((64, 128), bool)).any())
        self.assertFalse(ss._caps(image, np.zeros((64, 128), bool)).any())

    def test_enhancing_sharpens_detail_and_lifts_dim_areas(self):
        rng = np.random.default_rng(5)
        soft = cv2.GaussianBlur(rng.uniform(40, 200, (256, 512, 3)).astype(np.float32), (0, 0), 2)
        soft[:, :256] *= 0.35  # a dim half
        image = np.clip(soft, 0, 255).astype(np.uint8)
        before = image.copy()

        def detail(picture):
            return cv2.Laplacian(cv2.cvtColor(picture, cv2.COLOR_BGR2GRAY), cv2.CV_64F).var()

        ss.enhance(image)
        self.assertEqual(image.shape, before.shape)
        self.assertGreater(detail(image[:, 300:]), 1.3 * detail(before[:, 300:]))
        # The dim half comes up; the well-lit half is not darkened much.
        self.assertGreater(image[:, 40:200].mean(), 1.25 * before[:, 40:200].mean())
        self.assertGreater(image[:, 320:480].mean(), 0.9 * before[:, 320:480].mean())

    def test_enhancing_can_leave_sharpening_out(self):
        rng = np.random.default_rng(5)
        soft = cv2.GaussianBlur(rng.uniform(40, 200, (256, 512, 3)).astype(np.float32), (0, 0), 2)
        soft[:, :256] *= 0.35
        image = np.clip(soft, 0, 255).astype(np.uint8)
        sharpened = ss.enhance(image.copy())
        plain = ss.enhance(image.copy(), sharpen=False)

        def detail(picture):
            return cv2.Laplacian(cv2.cvtColor(picture, cv2.COLOR_BGR2GRAY), cv2.CV_64F).var()

        self.assertLess(detail(plain[:, 300:]), 0.8 * detail(sharpened[:, 300:]))
        # The dim half is still brought up.
        self.assertGreater(plain[:, 40:200].mean(), 1.25 * image[:, 40:200].mean())

    def test_enhancing_does_not_sharpen_the_fill(self):
        rng = np.random.default_rng(6)
        image = np.clip(cv2.GaussianBlur(rng.uniform(90, 190, (128, 256, 3)).astype(np.float32),
                                         (0, 0), 2), 0, 255).astype(np.uint8)
        photographed = np.zeros((128, 256), bool)
        photographed[:, :128] = True
        toned = image.copy()
        ss.enhance(toned, np.zeros((128, 256), bool))  # brightness only
        ss.enhance(image, photographed)
        self.assertTrue(np.array_equal(image[:, 140:], toned[:, 140:]))
        self.assertFalse(np.array_equal(image[:, :120], toned[:, :120]))


def twice(image):
    """Stands in for the model: twice the size, nothing invented."""
    return cv2.resize(image, None, fx=2, fy=2, interpolation=cv2.INTER_CUBIC)


class Enhancing(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def test_tiles_join_into_the_same_picture_as_one_pass(self):
        image = np.random.default_rng(1).integers(0, 255, (150, 201, 3), np.uint8)

        def run(part):
            # Every output pixel depends on its neighbours, as a real model's does.
            return np.repeat(np.repeat(cv2.blur(part, (5, 5)), 2, 0), 2, 1)

        np.testing.assert_array_equal(se.tiled(image, run, 2, tile=64, pad=8), run(image))

    def test_shots_are_enlarged_only_as_far_as_the_panorama_can_show(self):
        slices = Capture(self.root).slices()
        images = ss.read_images(slices)
        enhancer = se.Enhancer(twice, 2)
        # The synthetic shots have 700 pixels to a radian; an 8192-wide panorama has 1304.
        big, pictures = enhancer.prepare(slices, images, 8192)
        self.assertEqual((big[0].width, big[0].height), (3840, 2880))
        self.assertEqual(pictures[0].shape, (2880, 3840, 3))
        np.testing.assert_allclose(big[0].K, np.diag([2, 2, 1]) @ slices[0].K)
        np.testing.assert_array_equal(big[0].R, slices[0].R)
        # A 2048-wide panorama has 326: the shots already hold more, so they keep their size.
        same, pictures = enhancer.prepare(slices, images, 2048)
        self.assertEqual((same[0].width, same[0].height), (1920, 1440))
        self.assertEqual(pictures[0].shape, images[0].shape)
        np.testing.assert_allclose(same[0].K, slices[0].K)
        # In between they grow part of the way, and the intrinsics follow the new size exactly.
        part, pictures = enhancer.prepare(slices, images, 4096)
        self.assertTrue(1920 < part[0].width < 3840)
        self.assertEqual(pictures[0].shape[:2], (part[0].height, part[0].width))
        self.assertAlmostEqual(part[0].K[0, 0] / slices[0].K[0, 0], part[0].width / 1920)
        self.assertAlmostEqual(part[0].K[1, 2] / slices[0].K[1, 2], part[0].height / 1440)

    def test_shots_that_keep_their_size_still_go_through_the_model(self):
        slices = Capture(self.root).slices()[:1]
        seen = []
        enhancer = se.Enhancer(lambda image: seen.append(image.shape) or twice(image), 2)
        enhancer.prepare(slices, ss.read_images(slices), 2048)
        self.assertTrue(seen)

    def test_enhanced_shots_stitch_to_the_same_panorama(self):
        slices = Capture(self.root).slices()
        big, pictures = se.Enhancer(twice, 2).prepare(slices, ss.read_images(slices), 4096)
        image, holes = ss.stitch(big, width=WIDTH, refine=False, images=pictures)
        self.assertLess(holes, 0.005)
        self.assertGreaterEqual(psnr(image, SPHERE, photographed(slices)), 30)

    def test_a_spot_too_large_to_enhance_is_left_alone(self):
        slices = Capture(self.root).slices()
        with patch.object(se, 'MAX_PIXELS', 5 * 1920 * 1440):
            self.assertIsNone(se.Enhancer(twice, 2).prepare(slices, ss.read_images(slices), 8192))

    def capture(self):
        made = Capture(self.root / 'made')
        (made.root / 'manifest.json').write_text(json.dumps(made.manifest))
        archive = self.root / 'capture.roomcapture'
        with tarfile.open(archive, 'w') as tar:
            tar.add(made.root / 'manifest.json', 'manifest.json')
            for frame in made.frames:
                tar.add(made.root / frame['file_path'], frame['file_path'])
        return archive

    def test_the_worker_stitches_enhanced_shots_and_keeps_the_plain_panorama(self):
        work = self.root / 'work'
        with patch.object(tw, 'PANORAMA_WIDTH', 1024):
            tw.reconstruct_spots(self.capture(), work, enhancer=se.Enhancer(twice, 2))
        shown = cv2.imread(str(work / 'result/panos/01.jpg'))
        plain = cv2.imread(str(work / 'result/plain/01.jpg'))
        self.assertEqual(shown.shape, (512, 1024, 3))
        self.assertEqual(plain.shape, (512, 1024, 3))
        display = json.loads((work / 'result/display.json').read_text())
        self.assertIn('enhanced', display['method'])
        self.assertLessEqual(len(display['method']), 180)

    def test_without_an_enhancer_the_worker_writes_one_panorama(self):
        work = self.root / 'work'
        with patch.object(tw, 'PANORAMA_WIDTH', 1024):
            tw.reconstruct_spots(self.capture(), work, enhancer=None)
        self.assertTrue((work / 'result/panos/01.jpg').exists())
        self.assertFalse((work / 'result/plain').exists())
        self.assertNotIn('enhanced', json.loads((work / 'result/display.json').read_text())['method'])

    def test_a_failing_enhancer_does_not_fail_the_tour(self):
        def broken(image):
            raise RuntimeError('out of memory')

        work = self.root / 'work'
        with patch.object(tw, 'PANORAMA_WIDTH', 1024):
            tw.reconstruct_spots(self.capture(), work, enhancer=se.Enhancer(broken, 2))
        self.assertTrue((work / 'result/panos/01.jpg').exists())
        self.assertFalse((work / 'result/plain').exists())
        self.assertNotIn('enhanced', json.loads((work / 'result/display.json').read_text())['method'])


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
                    ss.read_images(slices)

    def test_rejects_images_wider_than_the_app_saves(self):
        self.check(self.manifest([{'spot': 1, 'slices': ['images/00000.jpg']}], width=4800, height=3600))

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
