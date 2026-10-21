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
- No numerical distance, calibration or depth inference is shipped. The limited hazard prototype adds a native speech service, disabled by default; live alerts abstain because validated pose, motion and ground contact are unavailable. Distance explicitly remains unavailable/uncalibrated. See [milestone 3 preparation](docs/DEPTH_PLAN.md).
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

Unit tests cover centre-region overlap, coordinate conversion, synthetic hazard evidence, temporal policy and cancellation. The new hazard tests have not been run in Xcode; see [hazard prototype validation](docs/HAZARD_ALERTS.md). Device checks: deny permission then enable in Settings; preview with missing model; add NMS model and verify a person/chair at left, centre and right; stop/start; background during inference; rotate phone (app stays portrait). Test different light levels and overlapping objects. Confirm no stale boxes after stopping and no saved media. Use Instruments for memory/energy and sustained thermal observations. Record device OS, model/package versions, elapsed time and lighting with each run. The app was built, signed, installed and launched on the connected iPhone 15 Pro. Geometry assertions passed on the Mac; the XCTest suite has not run on a device. No physical iPhone 16, model accuracy, 10+ FPS, subsecond alert latency or battery result is claimed yet.

Experimental research prototype only. **Not a mobility aid or collision-avoidance system**. Do not use for road crossing or navigation, or replace a white cane, guide dog or human assistance.


## Limited hazard-alert prototype (issue #1)

The cyan trapezoid is a **candidate** corridor derived from image geometry and the bottom edge of object boxes. It is uncalibrated and has no verified relationship to the user's walking path. The original yellow centre-region indicator and object overlays remain unchanged.

Modular assessment, temporal alert policy and native speech are included, with conservative/balanced sensitivity, speech off by default, and VoiceOver-readable decision explanations. **Turning speech on does not make the current camera pipeline issue warnings:** the baseline supplies unknown pose, motion and floor contact and therefore abstains. This is intentional: a teddy on a sofa cannot safely be distinguished from one on the floor using class and box geometry alone. There is no calibrated depth or surface detector; COCO also lacks a generic wall class. Synthetic tests demonstrate policy behaviour when trustworthy evidence is supplied, not detection capability.

Read [the capability gaps, test matrix and illustrative decision states](docs/HAZARD_ALERTS.md) before evaluating. This prototype does not provide reliable collision prevention. No new network use, storage, accounts, hardware or paid services are introduced.

### Try voice on the current iPhone camera

Tap **Test voice** to check native speech. Start the camera, then turn on **Speak object descriptions (preview)**. A supported object with at least 80% confidence whose bottom edge overlaps the candidate image corridor must persist for 0.7 seconds before it is described, for example “chair in front of the camera”. Descriptions repeat at most every eight seconds. This explicit preview mode describes objects; it does not establish floor contact, hazards, distance or safe walking space. It is separate from the hazard-warning mode described above, which still abstains without verified sensing. Enabling either mode switches the other off. Stop/background and audio interruption cancel speech. Camera migration to glasses is deferred.

The voice preview and test button have additional XCTest source coverage; compilation, audible output and device behaviour remain unverified in this environment.

## Camera startup troubleshooting

The control now shows **Cancel camera startup** while starting, then **Stop camera** after the capture session starts. Status and a received-video-frame counter appear above the preview. Object-model preparation runs separately, so a missing/failed detector can still show a camera preview. Camera permission errors provide an Open Settings action; interruption/runtime errors show retry guidance. Returning from the background still requires Start. A pending first-use permission request survives the temporary inactive permission alert.

See [camera startup findings and verification limits](docs/CAMERA_STARTUP.md). Physical-device UI tests require their own test-runner provisioning profile, in addition to the app's signing profile.

**Physical camera testing:** disconnect Device Hub interactive screen control before checking the real camera. Apple's [Device Hub documentation](https://developer.apple.com/documentation/xcode/interacting-with-your-app-in-device-hub) explains that apps may receive empty video while remote interaction is active. Here, disconnecting restored nonempty input and the user confirmed the app worked again. Frame counts alone do not prove that real images are arriving.
