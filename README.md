# ClimbTrack

ClimbTrack is an open-source iPhone app that records and
automatically follows a climber. Person detection runs on the iPhone, while an
optional Bluetooth Low Energy (BLE) controller drives a motorized pan-tilt
mount.

## Features

- On-device person detection with selectable YOLOX-Nano, YOLOX-Tiny, YOLOX-S,
  and Apple Vision backends
- YOLOX-S selected by default based on ClimbTrack field testing
- Automatic Apple Vision fallback when a selected bundled model is unavailable
- Tap or hand-gesture target selection
- Automated digital zoom and BLE pan-tilt control
- Configurable detection, tracking, recording, and motor tuning controls
- Multiple recording output modes saved to the user's Photos library
- No account, analytics SDK, advertising SDK, or remote inference service

## Project status and safety

ClimbTrack is intended for recreational filming, not as a safety system.
Detection, tracking, and motor commands can be late, incorrect, or interrupted.
Never use it where unexpected mount motion could injure someone or damage
property.

When using a motorized mount:

- Keep people, hair, clothing, and climbing equipment clear of moving parts.
- Supervise the device while motors are enabled.
- Provide an accessible physical power cutoff or emergency stop.
- Test speed limits and direction mapping before normal use.
- Do not rely on person detection for fall protection, belaying, rescue, access
  control, medical decisions, or other safety-critical uses.

See the [detector model card](ClimbTrack_app_v2/Models/MODEL_CARD.md) for model
limitations.

## Requirements

- macOS with Xcode 26.5 or newer
- An iPhone running iOS 26.5 or newer
- An Apple development team for installation on a physical device
- A compatible BLE pan-tilt controller for motorized tracking

The camera, person detection, tracking, digital zoom, and recording features can
be explored without the external motor controller. A physical device is
recommended because camera, Core ML, Photos, and BLE behavior cannot be fully
validated in Simulator.

## Build and run

1. Clone or download this repository.
2. Open `ClimbTrack_app_v2.xcodeproj` in Xcode.
3. Select the `ClimbTrack_app_v2` target, then open **Signing & Capabilities**.
4. Select your development team.
5. Change the bundle identifier from `com.pengqiu.ClimbTrack` to a unique value
   you control if Xcode reports that the identifier is unavailable.
6. Select a physical iPhone and run the app.
7. Grant Camera, Microphone, Bluetooth, and Add to Photos access as needed.

No third-party package manager or network download is required to build. All
three Core ML models are included in the repository.

An unsigned command-line build can be used as a quick compile check:

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

## Using the app

The app opens to the camera view. Select a detected person to begin tracking.
Use the device-management screen to scan for a compatible controller and to
reach manual motor controls and developer tuning screens. Settings are stored
locally in `UserDefaults`.

Recordings remain in temporary app storage while being processed and are then
written to the user's Photos library. See [PRIVACY.md](PRIVACY.md) for the data
handling summary.

## Compatible motor controller

The public repository contains the iPhone app and its BLE interface, not the
PCB, mechanical design, or ESP32 firmware. A compatible controller must
implement the UUIDs and UTF-8 commands documented in
[docs/BLE_PROTOCOL.md](docs/BLE_PROTOCOL.md).

The protocol values in that document were verified against the finalized
ClimbTrack ESP32 firmware and the previous motor-control app before publication.

## Repository layout

- `ClimbTrack_app_v2/`: SwiftUI application source and bundled resources
- `ClimbTrack_app_v2/Bluetooth/`: BLE discovery, connection, and command queue
- `ClimbTrack_app_v2/Camera/`: capture, preview, recording, and export
- `ClimbTrack_app_v2/HumanDetection/`: detection, association, and tracking
- `ClimbTrack_app_v2/GestureRecognition/`: target-selection gestures
- `ClimbTrack_app_v2/MotorControl/`: manual and automatic pan-tilt control
- `ClimbTrack_app_v2/Models/`: Core ML models and model documentation
- `Tools/`: reproducible model-conversion tooling

## Privacy

Camera analysis and model inference run locally on the device. The app does not
upload camera frames, recordings, detections, or BLE data. It has no user
accounts, advertising, or analytics. Full details are in
[PRIVACY.md](PRIVACY.md).

## Contributing and security

Bug reports, reproducible field observations, documentation improvements, and
code contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) before
submitting a pull request. Please report security or safety-sensitive issues as
described in [SECURITY.md](SECURITY.md), rather than opening a public issue.

## Third-party software and model

The app bundles converted Megvii YOLOX models. Their attribution, license,
conversion descriptions, and checksums are in
[THIRD_PARTY_NOTICES.md](ClimbTrack_app_v2/Models/THIRD_PARTY_NOTICES.md).

The bundled YOLOX models are Apache-2.0 licensed. The ClimbTrack source code is
currently distributed under the repository license below.

## License

Copyright 2026 Peng Qiu

ClimbTrack is free software licensed under the
[Apache License 2.0](LICENSE). You may use, study, modify, and redistribute it,
including commercially, subject to the license terms. It is provided without
warranty.

The license does not grant permission to use the ClimbTrack name or visual
identity in a way that implies endorsement. See [TRADEMARKS.md](TRADEMARKS.md).
