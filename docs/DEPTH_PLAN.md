# Milestone 3: metric-depth preparation

## Candidate and licensing gate

Investigate **Depth Anything V2 Small Metric**, selecting the indoor Hypersim checkpoint for indoor experiments and outdoor Virtual KITTI checkpoint for outdoor experiments. These are separately fine-tuned metric models. The ordinary relative-depth checkpoint must never be labelled in metres.

Primary sources:

- [Official metric code, checkpoints and inference instructions](https://github.com/DepthAnything/Depth-Anything-V2/tree/main/metric_depth)
- [Outdoor Small Transformers checkpoint and model card](https://huggingface.co/depth-anything/Depth-Anything-V2-Metric-Outdoor-Small-hf)
- [Upstream licensing](https://github.com/DepthAnything/Depth-Anything-V2#license)
- [Core ML PyTorch conversion](https://apple.github.io/coremltools/docs-guides/source/convert-pytorch-workflow.html)

Upstream distinguishes Small and larger-model licensing. Check the exact metric checkpoint's licence, training-data conditions and redistribution terms rather than inheriting an assumption from the relative model. Record repository commit, checkpoint SHA-256, licence text and dependencies before distribution. No metric weights are bundled and no Core ML conversion has been validated here.

## Download and conversion experiment on Mac

1. Clone the official repository and pin its commit. Create a separate Python environment and install its metric_depth requirements, torch and coremltools versions compatible with one another.
2. Download the **Small metric** checkpoint linked in the official metric README (indoor or outdoor), record its hash and use the matching `vits` architecture and upstream maximum depth. Do not substitute a relative checkpoint.
3. First run the upstream PyTorch inference on fixed real images, retaining raw floating-point predictions; coloured/normalised depth visualisations are not metric data.
4. Wrap the network in eval mode so its forward returns a single `[1,H,W]` metric depth tensor. Trace or export with a fixed input, initially 518x518 (multiple of the encoder patch size 14). Use upstream RGB resize, aspect handling and channel normalisation exactly. Prefer a tensor input for the initial conversion; this avoids accidentally applying a second ImageType scale/normalisation.
5. Convert the traced wrapper using `coremltools.convert`, `convert_to="mlprogram"`, fixed float tensor input `[1,3,518,518]`, FP16 compute and an iOS 17 deployment target. Save to `MetricDepthSmall.mlpackage`. Unsupported operators, trace warnings or converter version conflicts need investigation; this is a proposed procedure, not a verified one-command export.
6. Compare raw Core ML output against PyTorch on the **same preprocessed tensor** on the Mac. Record median/max absolute difference, nonfinite values, output dimensions and unit convention. Check structured scenes and humans, not just random input. Then benchmark on a physical standard iPhone 16 before choosing resolution or inference frequency.

## Future integration contract

- Feed detector and depth estimator the same timestamped portrait camera frame. Track all resizing/padding transforms so a detector box maps back to the corresponding depth pixels. Never sample from a depth frame belonging to a different timestamp.
- Sample an inset central torso/object ROI, reject invalid/nonpositive values, and use a robust median with minimum valid coverage. Background leakage and occlusion can invalidate the estimate. Generic objects may need class-specific ROIs; a torso heuristic does not generalise to every hazard.
- Represent states explicitly: unavailable, invalid, uncalibrated metric prediction, validated estimate. Retain model identity, ROI coverage and frame age. Do not infer metres from bounding-box size or arbitrary relative-depth scale.
- Display predictions for calibration only until approved test criteria pass. Spoken warnings can say “Object ahead”; numerical speech stays disabled until physical calibration demonstrates acceptable error. Specify warning distance, confidence, cooldown and maximum frame age, and cancel speech/camera work on backgrounding.

## Calibration and acceptance work still required

Record timestamp, class, actual metres (1/2/3/5), raw predicted metres, absolute error, model/OS versions, inference and capture-to-alert latency, lighting, scene and validity. Collect repeated trials across people, other classes, clothes, orientations, occlusion and indoor/outdoor light. Separate calibration from held-out validation and agree an accuracy criterion before enabling numerical speech. The standard iPhone 16 has no LiDAR reference; measure distances physically.

Measure 10+ processed FPS target, less-than-one-second alert target, memory, thermal state, battery level/energy and sustained-run throttling on the phone. These are targets, not results. Do not use this POC for navigation or real hazard avoidance. Meta glasses remain a separate later investigation.
