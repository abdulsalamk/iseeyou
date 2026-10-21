# Meta glasses development prototype

The phone camera remains the default. Select Meta glasses to use the glasses camera; detection and experimental depth processing remain on the iPhone. This is a development integration, not a verified navigation aid.

## Setup

- Meta Wearables DAT iOS SDK is pinned to 1.0.1; deployment target is iOS 17.2 or later.
- In Meta AI, open Settings > App info and tap App version five times. Enable Developer Mode after reviewing Meta's Wearables Developer Terms.
- If a glasses-side Install button is shown, complete its official setup.
- Wear the powered-on glasses with the arms open, connected to Meta AI.
- In I See You, select Meta glasses, tap Connect Meta glasses, acknowledge the unverified development app, then tap Allow glasses camera.
- Choose the glasses in Audio output. The app suppresses glasses-mode speech unless iOS reports a Bluetooth audio route; verify that the selected route is the glasses.
- Press Start camera manually. Stop and backgrounding end capture; returning to the app does not restart it.

Developer Mode uses the iseeyou custom URL scheme. This build contains no portal client token. SDK analytics and crash reporting are opted out. A production universal-link deployment requires separate association validation and suitable signing entitlements.

## Observed device results

On the paired iPhone 15 Pro, the original Meta AI "Internal error" was replaced by the normal app connection and camera permission prompts after Developer Mode was enabled. The app then confirmed camera permission granted. These results do not establish camera streaming or audio success.

The first physical Start attempts returned "No eligible device available". Device selection is now retained across starts, observed for readiness, and allowed up to five seconds for discovery before reporting no ready glasses. Actual streaming remains pending a physical retest. Keep remote phone screen control disconnected for camera evaluation.

The existing 32 device unit checks passed before this readiness change; the readiness change builds successfully. Unit checks do not validate glasses hardware streaming. Phone and glasses calibration profiles are separate; phone calibration must not be treated as glasses calibration.

## First streaming test

After installing the glasses-side DAT component in Meta AI (the user reported version 1.0.0.0), the user confirmed live glasses video and Test Voice in the glasses speakers. Automatic distance descriptions initially remained silent. Inspection showed a live preview with infinite frame age: the DAT sample timestamp could not be compared directly with the iPhone host clock.

For glasses only, the experimental description path now measures elapsed local time from SDK frame delivery through inference. The UI names this metric "Since delivery". It does not measure capture age or wireless transport latency; the existing 500 ms local processing limit and generation cancellation remain. Phone capture retains its host-clock timestamp check. Hazard speech still abstains because validated geometry is unavailable. This is not validation of glasses distance accuracy or end-to-end latency. Hardware speech retest is pending this update.
