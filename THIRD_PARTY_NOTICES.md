# Third-party notices

## Depth Anything V2 Small (Core ML)

- **File:** `ios/CuseSublets/Models/DepthAnythingV2SmallF16P6.mlpackage`, bundled in the iPhone app and used only on the device to draw the capture coverage overlay.
- **Source:** [apple/coreml-depth-anything-v2-small](https://huggingface.co/apple/coreml-depth-anything-v2-small), revision `cfef6f6f2a70783dedc0bfae40cecbc2052285d3`. This is Apple's Core ML conversion (Float16, 6-bit palettized weights) of the Depth Anything V2 Small model.
- **Model authors:** Lihe Yang, Bingyi Kang, Zilong Huang, Zhen Zhao, Xiaogang Xu, Jiashi Feng and Hengshuang Zhao, [Depth Anything V2](https://arxiv.org/abs/2406.09414) (2024).
- **License:** Apache License 2.0. The full text is in [`ios/CuseSublets/Models/LICENSE-Apache-2.0.txt`](ios/CuseSublets/Models/LICENSE-Apache-2.0.txt). Only the Small variant is Apache-2.0; the larger Depth Anything V2 variants use a non-commercial license and must not be substituted.
- **Integrity (SHA-256):**
  - `Data/com.apple.CoreML/model.mlmodel`: `ee53b8f7e1682a66857b5a3d54cf04a97d89a98cf7b5979b5d726aaf9c24ad70`
  - `Data/com.apple.CoreML/weights/weight.bin`: `3e9bcccc9e35ae6f9759551f481a3b77226510bd74536e059ee9780dda618381`
