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

## Implemented indoor prototype (physical calibration still required)

The app now runs **Depth Anything V2 Metric Hypersim Small** on the same portrait frame as YOLO11n. This is a second, depth-specific model; YOLO supplies object boxes and the metric model supplies estimated surface depth. It requires no LiDAR, preserving the standard iPhone 16 target. Neither model determines safe walking space.

Provenance:

- Official source commit: `a561b849ebae10a6f5ef49e26c83cbbcd36c71bf`.
- Official checkpoint: `depth_anything_v2_metric_hypersim_vits.pth`, stored as `models/metric_hypersim_small.pth`.
- Checkpoint SHA-256: `b782898d8a3e8be1f639de33837ed85e9b4b73e40f8f5e5cd99067588d722545`.
- Converted weights SHA-256: `312b4d1722145abdbf45b69f3c4439abd421d6107b475e3264facb75a72a3cad`.
- Exact checkpoint model card declares Apache-2.0; upstream Small uses Apache-2.0. License is preserved in `models/licenses/DepthAnythingV2-Apache-2.0.txt`. Hypersim is synthetic indoor training data; this is not an outdoor model or a validation of real scenes.
- Locked export packages: `models/requirements-depth-lock.txt`; minimal pins: `scripts/requirements-depth.txt`.

Export using Python 3.11 and the pinned source checkout:

```sh
python scripts/export_metric_depth.py --source /path/to/Depth-Anything-V2 \
  --checkpoint models/metric_hypersim_small.pth \
  --output ISeeYou/Models/MetricDepthSmall.mlpackage
```

The fixed portrait input is 294x518 RGB. This deliberately reduces resolution from upstream's default short-side 518 for mobile evaluation and introduces about 0.9% aspect stretching for a 720x1280 frame. It is an experimental preprocessing choice requiring physical calibration, not an exact reproduction of upstream default image resizing. RGB scaling is applied once by Core ML; ImageNet mean/std normalization is inside the network. Fixed positional embeddings are precomputed using upstream bicubic interpolation for this exact input, avoiding an unsupported runtime bicubic conversion operator. Output is `[1,518,294]` floating-point metric predictions, not a colourised depth image.

FP16 Core ML was compared with the original PyTorch positional-interpolation path on three deterministic random images and three upstream example photographs. All outputs were finite and shape-correct. Median absolute conversion differences ranged from 0.0045 to 0.0474 m; the largest pixel difference was 0.2328 m. Full results are in `models/metric-depth-parity.json`. These are **conversion differences**, not physical distance errors. No actual distance ground truth exists for these inputs. Source photographs are not copied into this repo.

`MetricDepthEstimator` maps an inset object ROI into the same frame's depth, using Vision's bottom-left coordinates correctly. It uses median depth, rejects less than 80% valid coverage, tiny boxes, nonfinite/out-of-range samples and excessive interquartile spread. These heuristics cannot remove all background leakage, transparent/reflective-surface failures, or class-specific errors. Estimates may be absent. Stale frames (over 500 ms) are never used for distance speech or calibration; stopped frames are also rejected. Depth/inference failure leaves camera preview available.

### Physical calibration workflow

Expand **Measure and validate distances**. Select one isolated object type in view with at least 80% detection confidence. Measure from the phone's rear camera to the visible object surface. Record calibration samples at 0.5, 1 and 2 m; a median multiplicative scale is fitted to those samples only. Scale outside 0.5–2 is rejected. Then freeze calibration by enabling **Held-out validation sample** and collect three separately positioned readings at **each** of 0.5, 1, 1.5, 2, 3 and 5 m. Use varied objects and lighting. Minimum two seconds between records prevents accidental duplicate taps; it does not independently prove the scene changed.

The preliminary bench acceptance limit is 10 cm or 15% of measured distance, whichever is larger, for all three most recent held-out readings at every range. This is an explicitly chosen research gate, not a clinically validated mobility standard. Profile and samples persist locally as JSON; CSV export includes timestamps, actual/raw/corrected distances, errors, model identity and latency. No images are recorded or uploaded. Calibration samples freeze once validation begins; reset is required to refit, and resetting immediately locks numerical speech again.

**Speak approximate distances (experimental)** is disabled until that gate passes and remains off unless explicitly enabled. It says, for example, “chair in front of you, about 1.5 metres”; below 0.5 m it adds “very close”. Missing/invalid/stale readings abstain; no distance is inferred from object-box size. Phone direction is still only an image-region proxy, not verified body direction or walking path. Existing stop/background/interruption cancellation applies. Beeps are deferred at the user's request. Distances below 0.15 m and beyond 5 m are outside this experimental speech range and are not announced.

No physical distance-accuracy, sustained thermal/energy, standard iPhone 16 performance or navigation-safety result is claimed yet. This prototype must be checked with a sighted tester and a physical tape measure while stationary before evaluating audio.
