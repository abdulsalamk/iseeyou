# YOLO11n source checkpoint

`yolo11n.pt` is the official pretrained Ultralytics YOLO11n checkpoint used to generate the bundled Core ML package in `ISeeYou/Models/yolo11n.mlpackage`. It is included for reproducibility; iOS loads only the compiled Core ML package.

- Upstream weights: https://github.com/ultralytics/assets/releases/download/v8.3.0/yolo11n.pt
- Source/export implementation: https://github.com/ultralytics/ultralytics/tree/v8.3.161
- Model author: Ultralytics. No training or fine-tuning was performed for this POC.
- Export: 640x640, FP16, NMS enabled; see `scripts/export_yolo.py` and `scripts/requirements-model.txt`.
- Licence: GNU AGPL-3.0; see root `LICENSE`, https://www.ultralytics.com/license and the upstream notices. This POC implementation is distributed under AGPL-3.0 with its corresponding source and build/export scripts.
- `SHA256SUMS.json` records the exact checkpoint and exported package file hashes. No accuracy, calibration or safety validation is implied by inclusion.

Do not load `.pt` checkpoints from untrusted sources: PyTorch checkpoints can contain executable serialized data. This checkpoint is not loaded by the iOS app.
