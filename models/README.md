# YOLO detector checkpoints

`yolo11n.pt` is retained as the known-good comparison checkpoint from the live YOLO11 baseline. `yolo26n.pt` is the official pretrained Ultralytics YOLO26n checkpoint for this branch. Its Core ML package has not yet been exported into this checkout. iOS loads Core ML packages only.

- YOLO11 upstream weights: https://github.com/ultralytics/assets/releases/download/v8.3.0/yolo11n.pt
- YOLO26 upstream weights: https://github.com/ultralytics/assets/releases/download/v8.4.0/yolo26n.pt
- Source/export implementation: https://github.com/ultralytics/ultralytics/tree/v8.4.187
- Model author: Ultralytics. No training or fine-tuning was performed for this POC.
- Planned YOLO26 export: 640x640, FP16, embedded NMS for the existing Vision recognized-object interface; see `scripts/export_yolo.py` and `scripts/requirements-model.txt`.
- Licence: GNU AGPL-3.0; see root `LICENSE`, https://www.ultralytics.com/license and the upstream notices. This POC implementation is distributed under AGPL-3.0 with its corresponding source and build/export scripts.
- `SHA256SUMS.json` records the exact YOLO11 checkpoint/package and both source checkpoint hashes. Add the YOLO26 package hashes after export. Including YOLO26 weights does not imply accuracy, calibration, physical-device or safety validation; compare it against YOLO11 using the issue's acceptance gates before promotion.

Do not load `.pt` checkpoints from untrusted sources: PyTorch checkpoints can contain executable serialized data. This checkpoint is not loaded by the iOS app.
