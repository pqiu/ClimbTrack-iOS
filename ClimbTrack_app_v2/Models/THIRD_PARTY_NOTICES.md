# On-device model notices

## YOLOX-Nano, YOLOX-Tiny, and YOLOX-S

- Project: YOLOX by Megvii Base Detection
- Source: https://github.com/Megvii-BaseDetection/YOLOX
- Source revision used for conversion: `6ddff4824372906469a7fae2dc3206c7aa4bbaee`
- Checkpoints: official COCO `yolox_nano.pth`, `yolox_tiny.pth`, and `yolox_s.pth`
- Official release: https://github.com/Megvii-BaseDetection/YOLOX/releases/tag/0.1.1rc0
- License: Apache License 2.0
- License copy: `Models/YOLOX_LICENSE.txt`
- Conversion: Core ML float16 ML Program, BGR image input, raw YOLOX inference
  head; person confidence is objectness multiplied by COCO class-zero score

Official checkpoint SHA-256 checksums:

- `yolox_nano.pth`: `cd28f55fbbc1829f99d9ac9b38a16d259a22889739c8728ea877610201feff7b`
- `yolox_tiny.pth`: `9de513de589ac98bb92d3bca53b5af7b9acfa9b0bacb831f7999d0f7afaee8f0`
- `yolox_s.pth`: `f55ded7181e1b0c13285c56e7790b8f0e8f8db590fe4edb37f0b7f345c913a30`

Bundled Core ML package checksums:

| Package | File | SHA-256 |
| --- | --- | --- |
| `YOLOXNano.mlpackage` | `model.mlmodel` | `84ef6758aad3bc6aa6b1bd1fca98fa0ef39e065b4db3006cc7d6b832b996210d` |
| `YOLOXNano.mlpackage` | `weight.bin` | `1b5f0b262b486b6aefb8802ff8cd0c9c96d660f2be1ae3b33d40845580d78080` |
| `YOLOXNano.mlpackage` | `Manifest.json` | `b63d49420b6a14a2ebbf20107c6295b6a305e7952ebd5528b553e6a9547cc5ad` |
| `YOLOXTiny.mlpackage` | `model.mlmodel` | `fe5d1dae1ec53d0157c1470a1290c5efb70a393054a21cde348cceaae0fff994` |
| `YOLOXTiny.mlpackage` | `weight.bin` | `62c3fba41fb2e059e4d1f7e27ef39d44dbce694b28c17eea65fedf8fd415d28d` |
| `YOLOXTiny.mlpackage` | `Manifest.json` | `b76e3af13ec1d15e75c4f80aba5d15cd009fb7bf2c77d99c4d1fa30e59c56be4` |
| `YOLOXS.mlpackage` | `model.mlmodel` | `dd5425956c790cbf0c081626a0292c601d3db75ef238d276aebd4b54cf510147` |
| `YOLOXS.mlpackage` | `weight.bin` | `c4be8c9d9195d7f485981682766a1a7c30a0788b6ee9cabe5d653724f91bf974` |
| `YOLOXS.mlpackage` | `Manifest.json` | `a0932453a71450a313b91b047fd982059f999bcd382b4a1c01ff8157d3dbbb2e` |

The conversions preserve YOLOX's top-left letterbox placement, pixel range,
objectness/class scoring, grid/stride decode, and person-only NMS. The
conversion script is in `Tools/convert_yolox_coreml.py`. Inference runs locally
and does not contact Megvii or a remote service.
