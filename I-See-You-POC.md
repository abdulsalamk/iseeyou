# I See You — iPhone Hazard Detection POC

## Goal
Build a native iOS proof of concept for a **standard iPhone 16** that detects people directly in the walking path, estimates their distance, and speaks warnings. Development environment: Mac M3, 32 GB RAM, Xcode. Begin with the iPhone rear camera; Meta smart-glasses integration is a later phase.

## Stack
- Swift, SwiftUI, AVFoundation for live camera capture.
- Core ML and Vision for local inference.
- Pretrained **YOLO11n** for person detection (export to Core ML; check Ultralytics AGPL-3.0 licensing before distribution).
- Investigate **Depth Anything V2 Small Metric** or a comparable Core ML-compatible metric depth model. Standard Depth Anything V2 predicts relative depth; do not treat it as metres without validated calibration. Check model licence.
- AVSpeechSynthesizer for non-blocking voice alerts.
- No AWS or external APIs required for the initial POC.

## Functional requirements
1. Show a live rear-camera preview with person bounding boxes and inference timings.
2. Mark the central 40% of the image as the initial approximate walking-path region; note this is not a reliable ground-plane or future-path estimate.
3. For people overlapping the centre region, estimate distance using depth values in an appropriate region of the person detection; display the estimate and its validity state.
4. Speak 'Person ahead' when detected. Only speak approximate distance in metres after physical calibration demonstrates acceptable accuracy; otherwise avoid numerical claims.
5. Provide configurable warning thresholds and rate limiting so alerts do not repeat continuously.
6. Add a calibration/testing screen for measured 1, 2, 3, and 5 metre distances; record actual distance, predicted distance, absolute error, and latency.
7. Track processed frames per second, end-to-end alert latency, memory, thermal state, and battery impact. Targets: 10+ processed FPS and less than one second alert latency, subject to device benchmarking.
8. Keep camera inference and speech processing asynchronous; handle denied camera permission and missing model assets gracefully.

## Development milestones
1. Generate an Xcode SwiftUI project, permissions, README, and live AVFoundation camera preview.
2. Add Core ML YOLO11n person detection and on-screen bounding boxes.
3. Integrate a compatible metric depth model, document conversion/download steps and limitations.
4. Add calibration, on-screen estimated distances, and test logging.
5. Add spoken alerts and configurable thresholds.
6. Test on a physical standard iPhone 16; report latency, accuracy, and battery observations.
7. Investigate Meta glasses video-feed access separately; do not assume third-party continuous streaming is available.

## First acceptance test
Point the phone at a person at a physically measured distance of 3 metres. Confirm person detection, show estimated distance and error, and issue an appropriate audio alert. Repeat at 1, 2 and 5 metres in different lighting conditions. Never claim unverified distance accuracy.

## Safety
Experimental research prototype only. **Not a mobility aid or collision-avoidance system**. Do not rely on it for road crossing, traffic warnings, or navigation, and do not replace a white cane, guide dog, or human assistance. Camera-based depth may fail on reflective surfaces, low light, occlusions, motion and unfamiliar scenes.

## Codex task
Implement milestones 1 and 2 first, then prepare milestone 3 with documented model selection and conversion. Commit changes to a development branch and include clear setup instructions for Xcode and deployment to an iPhone 16.
