# I See You — iPhone 16 POC

Native SwiftUI, AVFoundation, Vision and Core ML application implementing milestones 1 and 2 of [the original brief](I-See-You-POC.md). The subsequent user clarification expands detection from people to **all YOLO11n object classes**. People, vehicles, chairs and other supported classes are displayed; arbitrary hazards, surface changes and obstacles outside the trained vocabulary are not covered.

## Run in Xcode

1. Use a Mac with Xcode and the iOS SDK (built with Xcode 27.1). Deployment target: iOS 17+, iPhone only, portrait. No LiDAR or Pro-only hardware required.
2. Open `ISeeYou.xcodeproj`. Select the ISeeYou target, choose your development team in Signing & Capabilities, and change `com.iseeyou.research` to your own unique identifier.
3. Connect your standard iPhone 16, trust the Mac, enable Developer Mode and select it as the run destination. Press Cmd+R.
4. Tap **Start camera** and grant camera permission. Nothing is recorded or uploaded. Returning from the background requires tapping Start again.
5. The tested YOLO11n Core ML package is included, so detection works without installing Python or exporting a model. If you remove the model, preview still works and displays missing-model guidance.

## YOLO11n model setup

The bundled model is at `ISeeYou/Models/yolo11n.mlpackage` and its original checkpoint is at `models/yolo11n.pt`. See [model provenance and checksums](models/README.md). To regenerate it, move the existing package outside the repo first (the export script refuses to overwrite it). Use a separate Python 3.11 environment on the Mac with at least 3 GB free disk space. Pinned packages avoid the conversion failure observed with PyTorch 2.14.1:

```sh
python3.11 -m venv .venv
source .venv/bin/activate
python -m pip install -r scripts/requirements-model.txt
python scripts/export_yolo.py
brew install xcodegen # only if not already installed
xcodegen generate
```

The script downloads official `yolo11n.pt`, exports a 640x640 FP16 Core ML package with **NMS enabled**, and copies it into `ISeeYou/Models/yolo11n.mlpackage`. An optional build phase compiles it into the bundled `yolo11n.mlmodelc`. The app requires Vision recognized-object output from the NMS export, not raw prediction tensors. Record the installed package versions, weight hash and export logs for any benchmark; The pinned export has been verified on this Mac; recognition accuracy and physical iPhone 16 performance remain unverified.

[Ultralytics Core ML export documentation](https://docs.ultralytics.com/integrations/coreml/) describes this workflow. Review [Ultralytics licensing](https://www.ultralytics.com/license) before distributing weights or an application containing them; do not assume a proprietary redistribution licence. The model and this POC implementation are distributed under AGPL-3.0; see [LICENSE](LICENSE) and [model provenance](models/README.md).

## Behaviour and limitations

- All supported object classes appear with labels and confidence. Orange boxes overlap the central 40% of the camera image; green boxes fall outside it. This region is an image-space approximation, not a ground-plane estimate or planned walking path.
- The rear wide camera captures 720p, rotated to portrait. Preview uses aspect fit in a 9:16 area. Vision uses the same portrait buffer, scales to the model input and returns normalized coordinates; overlays flip Vision's bottom-left origin.
- Serial background camera/inference queue, discarded late frames and one request per frame prevent an accumulating inference backlog. UI updates happen on the main thread.
- Confidence slider filters displayed results. Model NMS may impose an additional minimum confidence floor.
- Shows processed FPS, Vision inference duration, capture-to-result frame age and thermal state. Frame age excludes UI render time and is **not alert latency**. Performance targets remain unverified until measured on a physical iPhone 16.
- No numerical distance, speech, calibration or depth inference is shipped in these first two milestones. Distance explicitly remains unavailable/uncalibrated. See [milestone 3 preparation](docs/DEPTH_PLAN.md).
- No microphone, photo library, networking or cloud services are used.

## Validation

```sh
xcodebuild -project ISeeYou.xcodeproj -scheme ISeeYou \
  -sdk iphoneos -configuration Debug -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO build
# Choose an installed simulator for geometry tests (camera requires a real device):
xcodebuild -project ISeeYou.xcodeproj -scheme ISeeYou \
  -destination 'platform=iOS Simulator,name=iPhone 16' test
```

Unit tests cover path-boundary overlap and conversion from Vision coordinates to the preview. Device checks: deny permission then enable in Settings; preview with missing model; add NMS model and verify a person/chair at left, centre and right; stop/start; background during inference; rotate phone (app stays portrait). Test different light levels and overlapping objects. Confirm no stale boxes after stopping and no saved media. Use Instruments for memory/energy and sustained thermal observations. Record device OS, model/package versions, elapsed time and lighting with each run. The app was built, signed, installed and launched on the connected iPhone 15 Pro. Geometry assertions passed on the Mac; the XCTest suite has not run on a device. No physical iPhone 16, model accuracy, 10+ FPS, subsecond alert latency or battery result is claimed yet.

Experimental research prototype only. **Not a mobility aid or collision-avoidance system**. Do not use for road crossing or navigation, or replace a white cane, guide dog or human assistance.
