# YOLO26n installation preparation — 25 October 2026

## Completed on the Mac

- Official YOLO26n checkpoint verified against the recorded SHA256 checksum.
- Export tools installed in a dedicated local Python 3.11 environment using `scripts/requirements-model.txt`; pip's download cache was disabled for this installation.
- `scripts/export_yolo.py` successfully exported a 640×640 FP16 Core ML pipeline with embedded NMS.
- Generated package: `ISeeYou/Models/yolo26n.mlpackage`, 5,076,009 bytes. Its files are checksummed in `models/SHA256SUMS.json`. The generated model binaries are local artifacts and are not added to Git by this update.
- The model compiled, loaded and ran Vision inference on a generated uniform image using the Mac CPU. Its output is compatible with `VNRecognizedObjectObservation`; this checks the interface, not recognition accuracy.
- Local signed iPhone Release build succeeded, includes `yolo26n.mlmodelc`, and passed code-signature verification. Bundle identifier remains `com.iseeyou.research`.
- `UnitChecks` build-for-testing succeeded for physical iOS devices. The bundled-model test now checks loading YOLO26 and running a generated image, replacing the pre-export missing-model expectation.

## Not yet completed

- Physical-device test execution and normal app installation: the phone is away from the Mac and unavailable over paired-device connectivity.
- Calibration before/after comparison: the pre-install read could not reach the phone. Obtain a fresh snapshot before installing once it reconnects. No calibration was changed by this preparation.
- Live phone/glasses camera, speech, recognition, latency, thermal or battery acceptance. No improved accuracy or navigation capability is claimed.

The last confirmed installed detector remains YOLO11. The source baseline is retained on `main` and at `baseline/live-yolo11-2026-10-24`. Do not describe the prepared YOLO26 build as installed until device tools confirm installation.

## Resume when the phone is reachable

1. Check fresh device connectivity/unlocked state (paired same-network Wi-Fi or USB).
2. Preserve both available phone/glasses calibration files and run the focused `DetectorModelStoreTests` on the physical iPhone, not a simulator.
3. Install the already-prepared normal Release app, verify installed identity and unchanged calibration, then launch it.
4. With remote screen interaction disconnected, perform a manual camera/voice check. Verify the displayed detector is YOLO26n. Compare recognition on the same scenes rather than assuming an upgrade improved it.

No AWS resource changes, training jobs, model-learning promotion or GitHub-hosted builds were performed for this installation preparation.
