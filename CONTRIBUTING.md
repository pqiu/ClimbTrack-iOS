# Contributing to ClimbTrack

Thank you for helping improve ClimbTrack. Safety, reproducibility, and focused
changes matter more than the size of a contribution.

## Before starting

For a bug, include the device model, iOS version, app revision, selected
detection backend, whether a BLE controller was connected, and steps that
reliably reproduce the behavior. Remove faces, recordings, device identifiers,
and other personal information from logs or attachments.

For a substantial feature or protocol change, open an issue first so the design
and scope can be discussed before implementation.

Do not include proprietary datasets, model weights, credentials, signing
profiles, or material that you do not have permission to redistribute.

## Development workflow

1. Create a focused branch.
2. Make the smallest coherent change.
3. Preserve on-device processing unless a proposal explicitly discusses the
   privacy and licensing impact of a network service.
4. Build with Xcode 26.5 or newer on a physical device when the change touches
   the camera, Core ML, Photos, gestures, or BLE.
5. Run an unsigned generic-device build before submitting:

```sh
xcodebuild \
  -project ClimbTrack_app_v2.xcodeproj \
  -scheme ClimbTrack_app_v2 \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/climbtrack-derived-data \
  CODE_SIGNING_ALLOWED=NO \
  build
```

6. Describe the verification performed and any remaining limitations in the
   pull request.

## Motor-control changes

Changes to BLE UUIDs, commands, signs, limits, command timing, or connection
behavior require evidence from a compatible controller implementation. Update
`docs/BLE_PROTOCOL.md` when changing the public interface. Test with motors
unloaded or mechanically isolated first, then at conservative speeds with an
accessible power cutoff.

## Model changes

A model contribution must include its source, exact version or checkpoint,
license, conversion procedure, input/output contract, checksums, and known
limitations. Update both the third-party notices and model card. Do not add a
model whose license is incompatible with AGPL-3.0 distribution.

## Contribution license

By submitting a contribution, you certify that you have the right to submit it
and agree that it may be distributed under the repository's GNU AGPL v3 license.
You retain copyright in your contribution. The project does not request
copyright assignment through this document.
