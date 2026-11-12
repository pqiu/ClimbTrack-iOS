# On-device detector model card

## Summary

ClimbTrack bundles float16 Core ML conversions of the official Megvii
YOLOX-Nano, YOLOX-Tiny, and YOLOX-S COCO checkpoints. The app
uses the selected model's person-class boxes for on-device target selection and
tracking. It does not perform face recognition or identify who a person is.

YOLOX-S accepts 640 × 640 images. YOLOX-Nano and YOLOX-Tiny accept 416 × 416
images. The app applies each model's native letterboxing and output
decode, filters person candidates, performs non-maximum suppression, and then
passes accepted boxes into the same tracking pipeline.

Exact provenance, license information, paths, and checksums are in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Intended use

- Filming assistance for recreational climbing
- Local, on-device person detection
- Evaluation and development of ClimbTrack's tracking behavior

## Out-of-scope use

Do not use this model or app for:

- fall detection, belaying, rescue, or other climbing safety decisions;
- medical diagnosis, treatment, rehabilitation decisions, or patient monitoring;
- surveillance, law enforcement, access control, or identity inference;
- autonomous machinery where a missed or incorrect detection could cause harm;
- inferring sensitive traits or intent.

## Limitations

- Small, distant, partially hidden, motion-blurred, or poorly lit people may be
  missed.
- Other objects may be incorrectly labeled as people.
- Crowds, crossings, occlusion, similar clothing, and people leaving the frame
  can cause target switching or loss.
- Camera angle, indoor climbing geometry, unusual poses, helmets, ropes, and
  harnesses may differ from the model's training distribution.
- Detection confidence is not a calibrated probability of correctness.
- Performance and error rates have not been validated across demographic groups,
  climbing environments, supported Apple devices, or accessibility scenarios.
- The tracking system adds its own failure modes beyond the detector.

## Privacy

Inference runs locally through Core ML. The released app does not transmit
frames or model outputs to Megvii or a remote inference service.

## License

The YOLOX models are distributed under Apache License 2.0. Exact terms,
attribution, and provenance are documented in the third-party notices. Review
the applicable terms before redistribution or use in another application.
