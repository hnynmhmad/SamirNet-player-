# Wi-Fi Direct migration and repository audit

Audit date: 2026-10-19
Target branch: `fix/nearby-transfer-session`
Baseline at start: `dcea7538764e71d4353749f1da075884b81e3dbe`

## Scope inspected

- `lib/main.dart`: application shell and navigation (132,988 bytes).
- `lib/screens/nearby_devices_screen.dart`: device discovery, connection consent, QR scan, payload metadata, transfer progress, hashing and received-file finalization (74,216 bytes).
- `lib/screens/nearby_share_screen.dart`: transfer entry points, local HTTP/QR alternative (34,618 bytes).
- `lib/screens/transfer_media_picker_screen.dart`: media selection and folder/album selection (15,046 bytes).
- `lib/services/wifi_transfer_service.dart`: local authenticated HTTP receiver (4,535 bytes).
- `lib/services/media_session_service.dart`, `lib/services/vault_service.dart`.
- `pubspec.yaml`, `test/widget_test.dart`, `.github/workflows/android.yml`, `README.md`.

## Confirmed findings

1. The current nearby-device engine uses `nearby_connections` with `Strategy.P2P_POINT_TO_POINT`. That API does not guarantee use of Android's native `WifiP2pManager`; it may use other nearby transports. Wi-Fi enabled checks alone do not prove Wi-Fi Direct.
2. The nearby-device permission path explicitly requests Bluetooth permissions (and uses location on older Android versions). This is consistent with the current Nearby Connections implementation, not a pure Wi-Fi Direct-only engine.
3. `nearby_share_screen.dart` exposes a separate QR/local HTTP route. Its receiver requires both devices to be on the same local network or hotspot; this is not Wi-Fi Direct group formation and should not be presented as equivalent.
4. The nearby screen's existing file protocol sends a metadata BYTES payload beside each file payload. The receive side has logic to hide metadata from the visible transfer list and validate SHA-256 before finalizing received files. These behaviors must be preserved during engine migration.
5. The media picker has separate video/audio album loading and folder selection support. A migration must keep selected-file identity stable and must not enqueue sidecar/metadata protocol data as user files.
6. Android platform sources are generated in CI with `flutter create`; native Wi-Fi Direct code therefore needs to be generated/installed by the workflow or the project must begin tracking the Android platform directory. Adding a Kotlin file without wiring it into the generated `MainActivity`/Flutter engine would not implement the feature.
7. The workflow previously ran for the target branch through a pull request, but its push branch list omitted `fix/nearby-transfer-session`. The workflow trigger has now been updated to include this branch so branch commits can be checked.
8. The previously inspected Actions run `39230242320` completed successfully: Analyze, Test and Release APK build all succeeded, and artifact `samirnet-player-apk` was produced. This is a baseline build result only; it does not validate radio discovery, Wi-Fi Direct negotiation or phone-to-phone transfers.
9. The repository currently has one widget test, which checks the application shell. There are no focused tests for transfer framing, filename sanitization, checksum failures, duplicate payloads, or cancellation/retry behavior.

## Required migration design

- Implement a native Android bridge around `WifiP2pManager` and its peer/state/connection broadcasts.
- Discover peers and form a Wi-Fi Direct group without requiring Bluetooth or Internet access.
- Establish a TCP session over the negotiated Wi-Fi Direct group-owner address; exchange file frames with explicit lengths and safe filenames.
- Keep the session bidirectional so either phone can send additional files after the initial connection.
- Surface connection state, per-file progress, speed, completion, cancellation, and errors to Flutter.
- Require explicit peer consent/identity confirmation before accepting incoming content.
- Verify each completed file (SHA-256) and delete partial/corrupt files on failure.
- Keep QR as a pairing/identity aid; it must not silently fall back to an Internet/cloud route or imply that QR itself transports data.
- Request the Android-version-appropriate nearby Wi-Fi/location permissions and explain when system settings (Wi-Fi/location) must be enabled.
- Test protocol logic independently, then run Flutter analyze/tests and Release APK CI. Real Wi-Fi Direct discovery and transfer still require tests on at least two physical Android devices.

## Status

This document records the audit and migration requirements; it does not claim the native Wi-Fi Direct transport has been implemented. The engine remains the existing Nearby Connections implementation until the native bridge and Flutter integration are committed and verified.
