# Privacy

This document describes the behavior of the open-source ClimbTrack app in this
repository. A distributor who changes the app or adds services is responsible
for updating these disclosures.

## Data processing

- Camera frames are processed locally for preview, person detection, gesture
  recognition, tracking, digital zoom, and recording.
- YOLOX and Apple Vision inference run on the device.
- The app does not upload camera frames, recordings, detections, or model output.
- The app contains no account system, advertising SDK, analytics SDK, crash
  reporting SDK, or remote inference client.
- Compatible-controller discovery and motor commands use BLE locally.
- The selected controller identifier, controller name, and developer tuning
  preferences are stored locally using `UserDefaults`.
- Completed recordings are written to the user's Photos library. Temporary
  recording files are managed in the app's sandbox during processing.

## Permissions

ClimbTrack may request:

- **Camera:** live preview, detection, tracking, and video recording
- **Microphone:** optional audio recorded with video
- **Bluetooth:** discovery and control of a compatible motor controller
- **Add to Photos:** saving completed recordings

The camera-only features can be used without connecting a motor controller.
Recording requires the permissions needed for the selected recording options.

## Network access

The released source does not implement a network upload or analytics path. Links
in the Open Source screen open documentation in the user's browser when tapped.

## Reports

If you discover behavior inconsistent with this document, follow the private
reporting guidance in [SECURITY.md](SECURITY.md).
