# ClimbTrack BLE controller protocol

This document describes the public interface expected by the iPhone app. It
does not prescribe a particular PCB, motor driver, mechanical design, or
firmware implementation.

## Advertising and GATT service

The local name `ClimbTrack` is recommended for display. Discovery is filtered
by the following service UUID, which is required:

| Role | UUID | Required properties |
| --- | --- | --- |
| Service | `7b9e0001-7c6b-4b6f-9f4f-2c9f4c000001` | Primary service |
| Command | `7b9e0002-7c6b-4b6f-9f4f-2c9f4c000002` | Write with response |
| Status | `7b9e0003-7c6b-4b6f-9f4f-2c9f4c000003` | Notify |

UUID comparison is case-insensitive. Commands and status messages are UTF-8
text without a required line terminator.

## Commands

| Command | Meaning |
| --- | --- |
| `ENABLE` | Enable both motor drivers. |
| `DISABLE` | Stop motion and disable both motor drivers. |
| `STOP` | Set both requested speeds to zero. |
| `MOVE <pan> <tilt>` | Set signed pan and tilt step rates. A new `MOVE` replaces the previous request. |
| `TESTPAN` | Run the controller's short pan diagnostic. |
| `TESTTILT` | Run the controller's short tilt diagnostic. |

`<pan>` and `<tilt>` are base-10 signed integers. Their safe range, physical
direction, acceleration behavior, and units are controller/mechanism concerns.
A compatible implementation must validate inputs and clamp them to its safe
limits rather than trusting the app.

## Status messages

The reference behavior uses human-readable notifications beginning with `OK `
or `ERR `. Examples include:

- `OK ENABLE`
- `OK DISABLE`
- `OK STOP`
- `OK MOVE <pan> <tilt>`
- `OK TESTPAN`
- `OK TESTTILT`
- `ERR MOTORS_DISABLED`
- `ERR BAD_MOVE_FORMAT`

The app displays the latest status and uses matching command text for diagnostic
latency when possible. A command's Core Bluetooth write completion only confirms
delivery to the peripheral stack; a status notification is the controller-level
acknowledgement.

## Connection and safety expectations

- The command characteristic must support writes with response.
- The status characteristic should notify after commands are processed.
- A controller should stop motion and disable drivers on disconnect or command
  timeout; it must not depend on the phone continuously behaving correctly.
- `DISABLE` and a physical power cutoff should remain available independently of
  automatic tracking.
- Implementations should start disabled after boot.

These values were verified against the finalized ClimbTrack ESP32 firmware and
the previous Xcode motor-control implementation before this document was added.
