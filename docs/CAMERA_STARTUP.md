# Camera startup fix — 21 October 2026

## Findings

Investigated the published `main` revision `4e5ff8c42eb0c1a4f711b33f27235812b47014da` on the paired physical iPhone 15 Pro. Permission was already authorized (AVFoundation value 3). No matching app crash report was found. A diagnostic invocation of the existing Start action started the capture session and delivered frames; the originally reported button failure was therefore not fully reproduced. A subsequent stop was observed after the app was no longer foregrounded.

Code inspection identified concrete startup weaknesses: detector loading preceded camera startup with no progress state; a temporary inactive scene (including a first-use permission alert) cancelled a pending start; runtime/interruption errors were not surfaced; and inference synchronously queried the main queue.

## Changes

- Explicit starting/cancel state and status above the preview, plus received-frame count.
- Start/check the capture session independently of model preparation. Detector failure leaves preview available and reports its error.
- Separate capture-control and inference queues; remove inference's synchronous main-thread wait and use a locked lifecycle generation token.
- Preserve pending camera permission requests across transient inactivity, but stop on actual backgrounding or ordinary inactivity.
- Surface session runtime errors and interruptions with retry guidance.
- Debug-only, metadata-only startup and preview-layer logging. No camera images are saved. The temporary auto-start diagnostic launch path was removed: launch and foreground return never invoke Start. Only the explicit Start button requests capture.

## Checks and limits

- Development-signed device build: passed (team 8T28SGLM79).
- Native lifecycle checks: passed for the permission-alert exception, real background cancellation and active/inactive states. Equivalent XCTest cases are included.
- Physical-device installation and launch: passed over local-network/TCP.
- Corrected runtime: authorized permission, `session.isRunning == true`, `isInterrupted == false`, preview-layer `isPreviewing == true`, detector ready, and a received video frame were confirmed in device console output. This is functional device telemetry, not a claim that a human inspected the live picture.
- An on-phone UI test was added to tap Start, verify frames, stop and restart. It could not run: the Mac lacks an Apple developer account/provisioning profile for `com.iseeyou.ISeeYouUITests.xctrunner`. App signing/install uses the existing app profile and succeeds. No passing UI-test result is claimed.
- First-use permission UI, runtime-error recovery and the actual Start button still need manual confirmation; existing authorization was not revoked for testing.

## Manual-only launch correction

The earlier functional diagnostic used a launch argument to start capture automatically; the user explicitly rejected that behaviour. The auto-start code path was removed completely. The app is subsequently installed and launched without such an argument. Foreground return does not start capture. The permission-completion path only continues an existing explicit Start tap, never a new launch.

## Subsequent hands-on physical-device UI verification

After the user authorised direct screen interaction, Device Hub's `Salam’s iPhone` window was identified as the paired **physical iPhone 15 Pro** (distinct from its separate simulator entries and from the separate iPhone Mirroring application).

Using that physical screen, the operator verified:

- Normal launch showed Start camera, Camera stopped and zero received frames, with no active camera indicator.
- Clicking Start changed the button to Stop camera, displayed Camera active / object detection ready, enabled the green camera-use indicator and increased the received-frame count (81, then 535 observed).
- Clicking Stop returned Start camera / Camera stopped and removed the camera indicator.
- Starting again, pressing Device Hub Home and reopening I See You left capture stopped with the explicit inactive/resume message. It did not restart on foreground return.
- Apple's built-in Camera app was opened for comparison, without taking a photo. Its preview was similarly dark. The operator returned to I See You with capture stopped. A meaningful scene, correct object labels and inference accuracy were not established from this dark view.

These are direct operator UI checks correlated with device logs, not a claim that the blocked XCTest UI suite passed. First-use permission UI and runtime-error recovery remain untested physically. The camera auto-start diagnostic path remains removed.

## Dark video cause isolated: Device Hub camera conflict

Apple's official documentation states that camera/microphone access conflicts with interactive physical-device control in Device Hub, and affected apps may receive empty video:
https://developer.apple.com/documentation/xcode/interacting-with-your-app-in-device-hub

A metadata-only comparison confirmed the conflict here. While the remote screen was connected, samples from the app's 720x1280 BGRA frames had brightness min/mean/max all equal to 16. Quitting Device Hub ended interactive remote screen control; the same explicitly started capture session then delivered varied samples (for example min 62, mean 141, max 254). No image was saved by the diagnostic code. Console access remained available without a live remote screen.

The user subsequently confirmed the app appeared to be working again on the physical phone. Keep Device Hub/iPhone Mirroring interactive screen control disconnected for real camera evaluation. Do not infer real scene quality from a running session or frame count alone. The operator did not visually inspect a live picture after disconnection; restoration was established through numeric diagnostics plus the user's observation.

Debug builds include periodic sampled brightness logging to distinguish empty input from a preview-only issue. Ordinary launch and foreground return remain manual-start only. No distance accuracy or recognition-accuracy result is established by this incident.
