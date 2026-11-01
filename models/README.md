# YOLO detector checkpoints

`yolo26n.pt` is the official pretrained Ultralytics YOLO26n checkpoint for this branch. Its FP16 Core ML package with embedded NMS was exported locally on 25 October 2026; the signed iPhone build is prepared, with device testing and installation pending connectivity. YOLO11 assets were removed from this working branch; restore the live baseline from tag `baseline/live-yolo11-2026-10-24` or download its upstream checkpoint when comparison is needed. iOS loads Core ML packages only.

- YOLO11 upstream weights: https://github.com/ultralytics/assets/releases/download/v8.3.0/yolo11n.pt
- YOLO26 upstream weights: https://github.com/ultralytics/assets/releases/download/v8.4.0/yolo26n.pt
- Source/export implementation: https://github.com/ultralytics/ultralytics/tree/v8.4.187
- Model author: Ultralytics. No training or fine-tuning was performed for this POC.
- YOLO26 export: 640x640, FP16, embedded NMS for the existing Vision recognized-object interface; see `scripts/export_yolo.py` and `scripts/requirements-model.txt`.
- Licence: GNU AGPL-3.0; see root `LICENSE`, https://www.ultralytics.com/license and the upstream notices. This POC implementation is distributed under AGPL-3.0 with its corresponding source and build/export scripts.
- `SHA256SUMS.json` records the YOLO26 source checkpoint hash. It also records the locally exported YOLO26 package hashes; the generated package itself is not added to Git in this update. Including YOLO26 weights does not imply accuracy, calibration, physical-device or safety validation; compare it against YOLO11 using the issue's acceptance gates before promotion.

Do not load `.pt` checkpoints from untrusted sources: PyTorch checkpoints can contain executable serialized data. This checkpoint is not loaded by the iOS app.
