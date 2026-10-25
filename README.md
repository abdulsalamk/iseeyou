# I See You — iPhone 16 POC

Native SwiftUI, AVFoundation, Vision and Core ML application implementing milestones 1 and 2 of [the original brief](I-See-You-POC.md). This branch evaluates YOLO26n as a candidate for the YOLO11 baseline. People, vehicles, chairs and other supported classes are displayed; arbitrary hazards, surface changes and obstacles outside the trained vocabulary are not covered.

## Run in Xcode

1. Use a Mac with Xcode and the iOS SDK (built with Xcode 27.1). Deployment target: iOS 17+, iPhone only, portrait. No LiDAR or Pro-only hardware required.
2. Open `ISeeYou.xcodeproj`. Select the ISeeYou target, choose your development team in Signing & Capabilities, and change `com.iseeyou.research` to your own unique identifier.
3. Connect your standard iPhone 16, trust the Mac, enable Developer Mode and select it as the run destination. Press Cmd+R.
4. Tap **Start camera** and grant camera permission. Nothing is recorded or uploaded. Returning from the background requires tapping Start again.
5. This branch contains no YOLO11 model files. The YOLO26n package has now been exported locally and the signed iPhone Release build succeeds. Physical-device testing and installation are pending phone connectivity; see `docs/YOLO26_STATUS.md`. Other checkouts must export the model before building; without the package, object detection is paused. The YOLO11 baseline remains available on `main` and at `baseline/live-yolo11-2026-10-24` for restoration. Removing YOLO11 from this working tree does not delete that baseline.

## YOLO26n candidate model setup

The YOLO26 checkpoint is at `models/yolo26n.pt`; its locally exported package is at `ISeeYou/Models/yolo26n.mlpackage`. YOLO11 assets are intentionally absent from this branch; restore them from the baseline tag when a comparison requires them. See [model provenance and checksums](models/README.md). To export YOLO26, use a separate Python 3.11 environment on the Mac with at least 3 GB free disk space:

```sh
python3.11 -m venv .venv
source .venv/bin/activate
python -m pip install -r scripts/requirements-model.txt
python scripts/export_yolo.py
brew install xcodegen # only if not already installed
xcodegen generate
```

The script loads `models/yolo26n.pt`, exports a 640x640 FP16 Core ML package with **NMS enabled**, and copies it into `ISeeYou/Models/yolo26n.mlpackage`. Xcode compiles it to `yolo26n.mlmodelc`. Embedded NMS is selected to preserve the app's Vision recognized-object output interface; raw and NMS-free outputs are not accepted by the current app pipeline. Record installed package versions, weight hash and export logs for comparisons. YOLO26 recognition accuracy and physical iPhone performance remain unverified.

[Ultralytics Core ML export documentation](https://docs.ultralytics.com/integrations/coreml/) describes this workflow. Review [Ultralytics licensing](https://www.ultralytics.com/license) before distributing weights or an application containing them; do not assume a proprietary redistribution licence. The model and this POC implementation are distributed under AGPL-3.0; see [LICENSE](LICENSE) and [model provenance](models/README.md).

## Behaviour and limitations

- All supported object classes appear with labels and confidence. Orange boxes overlap the central 40% of the camera image; green boxes fall outside it. This region is an image-space approximation, not a ground-plane estimate or planned walking path.
- The rear wide camera captures 720p, rotated to portrait. Preview uses aspect fit in a 9:16 area. Vision uses the same portrait buffer, scales to the model input and returns normalized coordinates; overlays flip Vision's bottom-left origin.
- Serial background camera/inference queue, discarded late frames and one request per frame prevent an accumulating inference backlog. UI updates happen on the main thread.
- The minimum-confidence slider filters displayed and described results (40% by default). Below 50%, retained detections use **unknown object** on screen and in speech; exactly 50% and above retain the predicted name. This is a naming threshold, not a guarantee that higher-confidence labels are correct. Model NMS may impose an additional detection floor.
- Shows processed FPS, Vision inference duration, capture-to-result frame age and thermal state. Frame age excludes UI render time and is **not alert latency**. Performance targets remain unverified until measured on a physical iPhone 16.
- Indoor metric-depth estimates and a physical calibration/held-out validation screen are included. Estimates are explicitly unverified; spoken estimates are experimental, use the displayed raw/calibrated value, and are off by default. No physical distance accuracy or safe-navigation result is claimed. See [depth implementation and calibration](docs/DEPTH_PLAN.md).
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

Tap **Test voice** to check native speech. Start the camera and enable **Speak estimated distances (experimental)**. Retained objects in the candidate corridor must persist for 0.7 seconds before being described, for example “chair, approximately 1.5 metres”. Speech uses the same raw or calibration-corrected estimate shown on screen, including before physical calibration, at the user's explicit request. Estimates are unverified until measured checks pass; “approximately” does not establish accuracy. Missing, invalid, out-of-range or stale depth abstains instead of inventing a number. Descriptions repeat at most every eight seconds; under 0.5 m adds “very close”. Below 50% confidence the name becomes “unknown object”. Object descriptions do not establish hazards, floor contact or safe walking space. The separate hazard-warning mode still abstains without verified sensing. Stop/background and audio interruption cancel speech.

The voice preview and test button have additional XCTest source coverage; compilation, audible output and device behaviour remain unverified in this environment.

## Camera startup troubleshooting

The control now shows **Cancel camera startup** while starting, then **Stop camera** after the capture session starts. Status and a received-video-frame counter appear above the preview. Object-model preparation runs separately, so a missing/failed detector can still show a camera preview. Camera permission errors provide an Open Settings action; interruption/runtime errors show retry guidance. Returning from the background still requires Start. A pending first-use permission request survives the temporary inactive permission alert.

See [camera startup findings and verification limits](docs/CAMERA_STARTUP.md). Physical-device UI tests require their own test-runner provisioning profile, in addition to the app's signing profile.

**Physical camera testing:** disconnect Device Hub interactive screen control before checking the real camera. Apple's [Device Hub documentation](https://developer.apple.com/documentation/xcode/interacting-with-your-app-in-device-hub) explains that apps may receive empty video while remote interaction is active. Here, disconnecting restored nonempty input and the user confirmed the app worked again. Frame counts alone do not prove that real images are arriving.

### Experimental indoor distances

A second Core ML model, Depth Anything V2 Metric Hypersim Small, predicts indoor surface depth. Object labels distinguish confidence percentages from approximate metres. Expand **Measure and validate distances** to record physically measured samples and export the results. Experimental numerical speech can be enabled before held-out checks at the user’s request; it never substitutes invented numbers for absent readings. Under half a metre adds “very close”. Beeps are deferred. See the [full workflow, provenance and limits](docs/DEPTH_PLAN.md#implemented-indoor-prototype-physical-calibration-still-required).

The 50% naming fallback is verified by boundary and speech tests; all 31 unit tests passed on the paired physical iPhone. Confidently wrong object labels remain a limitation: the display threshold cannot verify a label or add a new class. The local learning workflow uses human-reviewed corrections and held-out evaluation before a replacement can be delivered.

## AWS teacher development status

See [AWS teacher implementation status](docs/AWS_TEACHER_STATUS.md) for the deployed infrastructure, verified live Nova access and previous Support blocker, opt-in phone sampler, live and mock pipeline tests, and unfinished YOLO training work. Publishing source does not deploy infrastructure or update the installed app.

## On-demand local learning

[The local learning workflow](docs/LOCAL_LEARNING.md) provides reviewed dataset curation, CPU YOLO retraining, baseline regression evaluation, CoreML export and signed model delivery from this Mac to the physical iPhone. It can run when requested without waiting for the nightly inventory. No correction-trained weights have been produced: complete reviewed examples, replay coverage, held-out tests and physical candidate acceptance are required first. Cloud responses remain silent proposals and never directly replace live detections.
