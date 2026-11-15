"""Optional: cleans up and enlarges a spot's slices with a super-resolution model before they
are stitched, so the panorama is crisper than the camera's video frames.

The model draws plausible detail; it does not recover what the camera missed. Edges and
surfaces come out cleaner, but small lettering and fine patterns can be changed, so the worker
keeps the panorama stitched from the untouched slices beside the enhanced one.

`load` needs PyTorch and spandrel (processing/requirements-enhance.txt) and a model file such
as Real-ESRGAN's RealESRGAN_x2plus.pth. Everything else here needs only NumPy and OpenCV. No
customer data is logged here.
"""
from dataclasses import replace

import numpy as np

# A spot with more slice pixels than this is stitched without the model, so a crafted capture
# cannot buy unbounded model time. The app's largest spot is 6 slices of 2880 × 2160.
MAX_PIXELS = 8 * 2880 * 2160
# Slices go through the model in tiles this wide, each with PAD more pixels around it that are
# thrown away afterwards, so the tiles join without lines.
TILE, PAD = 512, 16
# Slices are enlarged until they hold this many times the panorama's detail and no further:
# drawing them into the panorama resamples them, which keeps detail best from a finer source.
OVERSAMPLE = 1.25


def tiled(image, run, scale, tile=TILE, pad=PAD):
    """`run` applied to a BGR picture in overlapping tiles. `run` returns its input `scale`
    times larger; so does this."""
    height, width = image.shape[:2]
    out = np.zeros((height * scale, width * scale, 3), np.uint8)
    for top in range(0, height, tile):
        for left in range(0, width, tile):
            y0, y1 = max(0, top - pad), min(height, top + tile + pad)
            x0, x1 = max(0, left - pad), min(width, left + tile + pad)
            big = run(np.ascontiguousarray(image[y0:y1, x0:x1]))
            rows = (min(height, top + tile) - top) * scale
            columns = (min(width, left + tile) - left) * scale
            y, x = (top - y0) * scale, (left - x0) * scale
            out[top * scale:top * scale + rows, left * scale:left * scale + columns] = big[y:y + rows, x:x + columns]
    return out


class Enhancer:
    """A model as a function `run` from a BGR uint8 picture to the same picture `scale` times
    larger."""

    def __init__(self, run, scale):
        self.run, self.scale = run, int(scale)

    def prepare(self, slices, images, panorama_width):
        """The slices and their decoded pictures after the model, ready for `stitch`, or None
        if the spot is too large (see MAX_PIXELS).

        Every picture goes through the model. It is then kept only as large as a panorama
        `panorama_width` wide can show (see OVERSAMPLE), and never smaller than it came, so a
        slice that already holds enough detail is cleaned up at its own size."""
        import cv2
        if sum(s.width * s.height for s in slices) > MAX_PIXELS:
            return None
        better, pictures = [], []
        for s, image in zip(slices, images):
            wanted = min(self.scale, max(1.0, OVERSAMPLE * panorama_width / (2 * np.pi) / s.K[0, 0]))
            width, height = round(s.width * wanted), round(s.height * wanted)
            big = tiled(image, self.run, self.scale)
            if big.shape[:2] != (height, width):
                big = cv2.resize(big, (width, height), interpolation=cv2.INTER_AREA)
            grown = np.diag([width / s.width, height / s.height, 1.0])
            better.append(replace(s, K=grown @ s.K, width=width, height=height))
            pictures.append(big)
        return better, pictures


def load(path):
    """An Enhancer for the model file at `path`, on the machine's GPU when it has one. Raises
    if PyTorch or spandrel is missing or the file is not a colour image-to-image model."""
    import torch
    from spandrel import ImageModelDescriptor, ModelLoader
    model = ModelLoader().load_from_file(str(path))
    if not isinstance(model, ImageModelDescriptor) or (model.input_channels, model.output_channels) != (3, 3):
        raise ValueError('not a colour image-to-image model')
    name = 'mps' if torch.backends.mps.is_available() else 'cuda' if torch.cuda.is_available() else 'cpu'
    device = torch.device(name)
    model.to(device).eval()

    def run(image):
        rgb = np.ascontiguousarray(image[..., ::-1])
        tensor = torch.from_numpy(rgb).permute(2, 0, 1).float().div(255).unsqueeze(0).to(device)
        with torch.no_grad():
            big = model(tensor).clamp(0, 1)
        return (big[0].permute(1, 2, 0).cpu().numpy() * 255 + 0.5).astype(np.uint8)[..., ::-1]

    return Enhancer(run, model.scale)
