# YOLO26n installation and verification — 25 October 2026

## Completed on the Mac

- Official YOLO26n checkpoint verified against the recorded SHA256 checksum.
- Export tools installed in a dedicated local Python 3.11 environment using `scripts/requirements-model.txt`; pip's download cache was disabled for this installation.
- `scripts/export_yolo.py` successfully exported a 640×640 FP16 Core ML pipeline with embedded NMS.
- Generated package: `ISeeYou/Models/yolo26n.mlpackage`, 5,076,009 bytes. Its files are checksummed in `models/SHA256SUMS.json`. The generated model binaries are local artifacts and are not added to Git by this update.
- The model compiled, loaded and ran Vision inference on a generated uniform image using the Mac CPU. Its output is compatible with `VNRecognizedObjectObservation`; this checks the interface, not recognition accuracy.
- Local signed iPhone Release build succeeded, includes `yolo26n.mlmodelc`, and passed code-signature verification. Bundle identifier remains `com.iseeyou.research`.
- `UnitChecks` build-for-testing succeeded for physical iOS devices. The bundled-model test now checks loading YOLO26 and running a generated image, replacing the pre-export missing-model expectation.

## Completed on the physical iPhone

- The signed `com.iseeyou.research` app containing `yolo26n.mlmodelc` was installed and launched on the iPhone 15 Pro.
- After installation, the full `UnitChecks` suite ran on that phone (iOS 27.0.1): 52 tests, 51 passed, 0 failed, 1 skipped. `testStagedCandidateBenchmark` was skipped because no candidate package was staged. The bundled YOLO26 model load/inference test passed on generated input.

## Still to verify

- Manual live camera and voice behaviour, recognition on the same real scenes, latency, thermal and battery behaviour. The unit suite does not establish these results. No improved accuracy or navigation capability is claimed.
- A fresh calibration comparison has not been made. The update was installed over the existing app with the same bundle identifier; calibration was not intentionally changed.

The YOLO11 source baseline remains on `main` and at `baseline/live-yolo11-2026-10-24`. No AWS resource changes, training jobs, model-learning promotion or GitHub-hosted builds were performed for this installation.
