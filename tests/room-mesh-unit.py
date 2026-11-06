"""Checks for the room mesh step. Needs NumPy; the fusion check also needs Open3D and is skipped
without it. Model inference is exercised by the documented offline run, not here."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

import numpy as np

spec = importlib.util.spec_from_file_location('room_mesh', 'processing/room_mesh.py')
rm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rm)


class ViewSelection(unittest.TestCase):
    def test_small_captures_keep_every_view(self):
        self.assertEqual(rm.select_views(30), list(range(30)))
        self.assertEqual(rm.select_views(60), list(range(60)))

    def test_large_captures_spread_the_limit_evenly_and_keep_both_ends(self):
        picked = rm.select_views(180)
        self.assertEqual(len(picked), rm.MAX_VIEWS)
        self.assertEqual((picked[0], picked[-1]), (0, 179))
        gaps = np.diff(picked)
        self.assertLessEqual(gaps.max() - gaps.min(), 1)


class DepthCleaning(unittest.TestCase):
    def test_keeps_a_wall_and_drops_range_confidence_and_edge_failures(self):
        depth = np.full((60, 80), 2.0, np.float32)
        depth[:, 40:] = 1.0  # an object edge: 2 m to 1 m
        depth[0, 0] = 9.0  # beyond the working range
        depth[5, 5] = np.nan
        conf = np.ones_like(depth)
        conf[50:, :10] = 0  # least confident pixels
        clean = rm.clean_depth(depth, conf, percentile=5)
        self.assertEqual(clean[30, 20], 2.0)
        self.assertEqual(clean[30, 60], 1.0)
        self.assertEqual(clean[0, 0], 0)
        self.assertEqual(clean[5, 5], 0)
        self.assertTrue((clean[50:, :10] == 0).all())
        self.assertTrue((clean[:, 38:42] == 0).all(), 'pixels across the edge would float in mid-air')
        self.assertFalse(np.shares_memory(clean, depth))


class PlyOutput(unittest.TestCase):
    def test_binary_ply_round_trips_vertices_colours_and_faces(self):
        vertices = np.array([[0, 0, 0], [1, 0, 0], [0, 1.5, -2]], np.float32)
        colors = np.array([[255, 0, 0], [0, 255, 0], [0, 0, 255]], np.uint8)
        faces = np.array([[0, 1, 2]])
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'mesh.ply'
            rm.write_ply(path, vertices, colors, faces)
            self.assertEqual(rm.read_ply_header(path), {'vertex': 3, 'face': 1})
            data = path.read_bytes()
            body = data[data.index(b'end_header\n') + len(b'end_header\n'):]
            vertex = np.frombuffer(body[:3 * 15], dtype=[('p', '<f4', 3), ('c', 'u1', 3)])
            face = np.frombuffer(body[3 * 15:], dtype=[('n', 'u1'), ('i', '<i4', 3)])
            np.testing.assert_array_equal(vertex['p'], vertices)
            np.testing.assert_array_equal(vertex['c'], colors)
            self.assertEqual(face['n'][0], 3)
            np.testing.assert_array_equal(face['i'][0], [0, 1, 2])

    def test_refuses_faces_that_point_past_the_vertices(self):
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaises(ValueError):
                rm.write_ply(Path(folder) / 'bad.ply', np.zeros((2, 3)), np.zeros((2, 3)), [[0, 1, 2]])
            with self.assertRaises(ValueError):
                rm.write_ply(Path(folder) / 'bad.ply', np.zeros((3, 3)), np.zeros((2, 3)), [[0, 1, 2]])


class ManifestPaths(unittest.TestCase):
    def write(self, folder, names, link=None):
        (folder / 'images').mkdir()
        for name in names:
            if name.startswith('images/'):
                (folder / name).write_bytes(b'jpeg')
        if link:
            (folder / 'images/00000.jpg').unlink()
            (folder / 'images/00000.jpg').symlink_to(link)
        (folder / 'manifest.json').write_text(json.dumps({'frames': [{'file_path': n} for n in names]}))

    def test_accepts_engine_image_names(self):
        with tempfile.TemporaryDirectory() as folder:
            self.write(Path(folder), ['images/00000.jpg', 'images/00001.jpg'])
            self.assertEqual(len(rm.load_frames(folder)), 2)

    def test_rejects_paths_that_could_leave_the_capture_folder(self):
        for names in (['../outside.jpg'], ['/etc/hosts'], ['images/../../x.jpg'], ['images/00001.jpg']):
            with tempfile.TemporaryDirectory() as folder, self.subTest(names=names):
                self.write(Path(folder), names)
                with self.assertRaises(ValueError):
                    rm.load_frames(folder)

    def test_rejects_a_symlinked_image(self):
        with tempfile.TemporaryDirectory() as folder, tempfile.NamedTemporaryFile() as target:
            self.write(Path(folder), ['images/00000.jpg'], link=target.name)
            with self.assertRaises(ValueError):
                rm.load_frames(folder)


@unittest.skipUnless(importlib.util.find_spec('open3d') and importlib.util.find_spec('PIL'), 'needs Open3D')
class Fusion(unittest.TestCase):
    def test_views_of_a_wall_fuse_into_a_flat_surface_at_the_right_distance(self):
        from PIL import Image
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            (folder / 'images').mkdir()
            frames, depths = [], {}
            w, h, f = 160, 120, 120.0
            for i, x in enumerate(np.linspace(-0.3, 0.3, 5)):
                name = f'images/{i:05d}.jpg'
                Image.new('RGB', (w, h), (180, 160, 140)).save(folder / name)
                pose = np.eye(4)
                pose[0, 3] = x
                frames.append({'file_path': name, 'transform_matrix': pose.tolist()})
                # Camera looks along -Z at a wall 2 m away.
                depths[i] = rm.ViewDepth(np.full((h, w), 2.0, np.float32), None, (f, f, w / 2, h / 2))
            (folder / 'manifest.json').write_text(json.dumps({'frames': frames}))
            mesh, used = rm.fuse(frames, folder, depths, voxel=0.02)
            mesh = rm.finish(mesh)
            z = np.asarray(mesh.vertices)[:, 2]
            self.assertEqual(used, 5)
            self.assertGreater(len(mesh.triangles), 1000)
            self.assertAlmostEqual(float(np.median(z)), -2.0, delta=0.02)
            self.assertLess(float(np.percentile(np.abs(z + 2), 95)), 0.02)


if __name__ == '__main__':
    unittest.main()
