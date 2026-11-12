"""Convert an official YOLOX COCO checkpoint to ClimbTrack's Core ML format.

Run from a clone of https://github.com/Megvii-BaseDetection/YOLOX at the source
revision recorded in Models/THIRD_PARTY_NOTICES.md, with torch and coremltools
installed. Example:

    PYTHONPATH=/path/to/YOLOX python Tools/convert_yolox_coreml.py \
      --name yolox-tiny --checkpoint yolox_tiny.pth \
      --output ClimbTrack_app_v2/Models/YOLOXTiny.mlpackage
"""

import argparse
import hashlib
import pathlib

import coremltools as ct
import torch


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--name", required=True, choices=(
        "yolox-nano", "yolox-tiny", "yolox-s"
    ))
    parser.add_argument("--checkpoint", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()

    from yolox.exp import get_exp

    exp = get_exp(None, args.name)
    model = exp.get_model()
    checkpoint = torch.load(args.checkpoint, map_location="cpu")
    model.load_state_dict(checkpoint["model"])
    model.eval()
    model.head.decode_in_inference = False

    height, width = exp.test_size
    example = torch.zeros(1, 3, height, width)
    with torch.no_grad():
        traced = torch.jit.trace(model, example, strict=True)
        expected_shape = tuple(traced(example).shape)
    candidate_count = sum(
        (height // stride) * (width // stride) for stride in (8, 16, 32)
    )
    if expected_shape != (1, candidate_count, 85):
        raise RuntimeError(f"Unexpected output shape {expected_shape}")

    package = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[ct.ImageType(
            name="image",
            shape=example.shape,
            color_layout=ct.colorlayout.BGR,
            scale=1.0,
        )],
        outputs=[ct.TensorType(name="predictions")],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS16,
    )
    package.author = "Megvii Base Detection (converted for ClimbTrack)"
    package.license = "Apache-2.0"
    package.short_description = (
        f"Official {args.name} COCO checkpoint converted to Core ML"
    )
    package.input_description["image"] = (
        "Top-left-letterboxed BGR image with pixel values in 0...255"
    )
    package.output_description["predictions"] = (
        f"Raw YOLOX output [1, {candidate_count}, 85]: xywh, objectness, "
        "80 COCO classes"
    )
    package.user_defined_metadata["source_repository"] = (
        "https://github.com/Megvii-BaseDetection/YOLOX"
    )
    package.user_defined_metadata["source_checkpoint_sha256"] = sha256(
        args.checkpoint
    )
    package.user_defined_metadata["conversion_coremltools"] = ct.__version__
    package.user_defined_metadata["conversion_torch"] = torch.__version__
    package.save(str(args.output))
    print(args.output)
    print("checkpoint_sha256", sha256(args.checkpoint))
    print("output_shape", expected_shape)


if __name__ == "__main__":
    main()
