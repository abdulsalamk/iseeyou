# Validation record — 21 October 2026

- Xcode 27.1 / Swift 6.4 toolchain; application uses Swift 5 language mode and iOS 17 deployment target.
- Device build without weights: passed.
- Signed device build with YOLO11n compiled into the app: passed.
- Installed and launched on the connected **iPhone 15 Pro**. The requested standard iPhone 16 was not connected. No LiDAR or device depth APIs are used.
- Native Mac assertion harness using the production Detection.swift: passed centre-boundary overlap (including non-person objects) and Vision bottom-left to portrait-preview conversion. XCTest source is also included, but the XCTest suite was not executed; simulator test build encountered disk exhaustion. User requested physical-device work thereafter.
- YOLO11n FP16 / 640 / NMS Core ML export: passed with the pinned requirements-model.txt versions. PyTorch 2.14.1 with Core ML Tools 9 failed conversion; this is why the working torch 2.7.0 environment is pinned.
- Downloaded yolo11n.pt SHA-256: `0ebbc80d4a7680d14987a577cd21342b65ecfd94632bd9a8da63ae6417644ee1`.
- Weights and compiled models are local ignored artifacts. Source checkout builds without weights; its optional model compilation phase includes them when present.

Still unverified: visual box alignment on the phone, labelled recognition accuracy, unsupported hazard coverage, measured distances, calibration, speech, physical iPhone 16 throughput, capture-to-alert latency, thermal endurance and energy use. An installed/launchable build is not evidence of those properties. Follow README device checks and DEPTH_PLAN.md before progressing.
