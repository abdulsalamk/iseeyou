# On-demand local detector learning

This workflow runs from the Mac immediately when requested. It does not wait for the nightly inventory, create cloud GPU resources, restore cloud iPhone builds, or automatically promote a model. Nova proposes annotations; a reviewer supplies complete spatial labels before training. Model delivery uses the connected physical iPhone and the existing bundle identifier. It is signed local delivery, not an OTA model service.

## Review and curate

Keep media, datasets, checkpoints and release artifacts outside Git. Use a private workspace with enough disk space:

```sh
mkdir -p "$HOME/.local/share/iseeyou-learning"
chmod 700 "$HOME/.local/share/iseeyou-learning"
python3 scripts/learning/pipeline.py fetch --output "$HOME/.local/share/iseeyou-learning/review-001"
```

`review.json` lists image checksums, pinned S3 source versions and Nova proposals. Fetch excludes mock completions and marked synthetic fixtures. For each real example, a reviewer must fill `reviewed_by`, `complete_annotation: true`, `group`, `split`, and `objects`. Objects use `{"label":"piano","box":[xmin,ymin,xmax,ymax]}` with normalized top-left coordinates. Label every visible supported object, not just the piano; use an empty list only for a reviewed negative image. Teacher boxes are suggestions, never copied into approved annotations automatically. Give frames from the same recording/session/scene the same group, and keep groups entirely within one split. Exact duplicate images are rejected even within a split. Visually near-identical frames and repeated views of the same piano must also be grouped by the reviewer.

Retain all 80 COCO class IDs, appending piano at ID 80. Merge independently reviewed historical/replay examples into the same workspace. Minimum distinct images per class: piano 20 train / 5 validation / 5 test; each existing class 5 / 2 / 3. These are minimum gates, not proof that a dataset is representative. Use different pianos, actual laptops and challenging scenes; a single piano filmed repeatedly does not establish generalization. No class is silently dropped to get a training run through.

```sh
python3 scripts/learning/pipeline.py curate --review "$HOME/.local/share/iseeyou-learning/review-001/review.json" --output "$HOME/.local/share/iseeyou-learning/dataset-001"
```

Curate rejects incomplete review, unsafe paths, invalid boxes, changed images, duplicate images, scene leakage and insufficient replay. The resulting dataset includes hashed files and a provenance copy. Treat a dataset version as immutable. Validation is for fitting/early stopping; test images are reserved for evaluation.

## Train, evaluate and export

Use the pinned Python 3.11 dependencies in `scripts/requirements-model.txt` in a dedicated virtual environment. Installing dependencies and real training require disk space; the runner refuses training below 5 GiB free and never deletes files to make room. It uses the trusted repository checkpoint and an explicit CPU device, deterministic seed 2026, 640px inputs and 30 epochs by default. No training is started simply by fetching or reviewing samples.

```sh
python scripts/learning/pipeline.py train --dataset /PRIVATE/dataset-001 --output /PRIVATE/run-001
python scripts/learning/pipeline.py evaluate --dataset /PRIVATE/dataset-001 --checkpoint /PRIVATE/run-001/fit/weights/best.pt --output /PRIVATE/evaluation-001.json
python scripts/learning/pipeline.py export --evaluation /PRIVATE/evaluation-001.json --checkpoint /PRIVATE/run-001/fit/weights/best.pt --output /PRIVATE/candidate-001.mlpackage
```

Training records checkpoint/dataset/baseline hashes, seed, epochs and installed package versions. Evaluation compares the candidate and bundled baseline on the same held-out images, using 101-point AP at IoU .5 and precision/recall at confidence .4. No existing class may regress more than three percentage points in AP50, precision or recall. Piano must improve over baseline, with AP50 >= .5, recall >= .6 and precision >= .8. Missing support or failed gates rejects the candidate. This evaluates object recognition; it does not establish safe navigation, door state, steps/kerbs or hazard performance.

Export requires a passing evaluation bound to the exact checkpoint. It produces the same 640px FP16 CoreML/NMS interface used by the app, with a .001 NMS score floor to allow held-out parity checks. It does not overwrite the bundled detector. The export sidecar binds its files to the evaluation. The resulting CoreML detector must still be checked on the physical iPhone: quantization/conversion can change results.

## Physical validation and signed delivery

Stage a candidate for shadow-only device checks; this does not replace the active detector:

```sh
python scripts/learning/pipeline.py stage-validation --package /PRIVATE/candidate-001.mlpackage --dataset /PRIVATE/dataset-001 --device PHYSICAL_DEVICE_ID
```

Use the optional `DetectorModelStoreTests/testStagedCandidateBenchmark` physical-device XCTest to compile the staged package and produce baseline/candidate predictions and timing for the held-out images. Export `Documents/ModelValidation/measurements.json` with `devicectl device copy from`. Review prediction parity against held-out annotations and perform the separate supervised camera, voice, rollback, thermal and battery checks. Static-frame timings alone cannot approve live camera overhead or recognition. The test never starts a camera or upload.

A separate private JSON device report must identify the exact `package_files_sha256` printed by staging and include:

```json
{
  "package_files_sha256": "HASH_PRINTED_BY_STAGE_VALIDATION",
  "reviewed_by": "reviewer",
  "physical_device": true,
  "duration_seconds": 300,
  "fps": 10,
  "p95_inference_ms": 500,
  "coreml_label_parity": false,
  "camera_alignment": false,
  "speech_regression": false,
  "rollback_tested": false,
  "thermal_acceptable": false,
  "battery_acceptable": false,
  "recognition_accepted": false
}
```

Replace measurements with actual observations and mark checks true only after they pass on the physical iPhone. Release refuses missing/failed checks, a changed export, <5 minutes of observations, <10 FPS or >500ms p95 inference. These release limits do not claim the prototype already meets them. The human report is an explicit operator attestation, not an automatically generated safety certification.

The initial private Ed25519 signing key is stored on this Mac at `~/.config/iseeyou-teacher/model-signing.key` (mode 0600). Only its public pin is bundled in the app. Back up that private key securely. Do not put it or device connection tokens in Git. For a fresh setup, `swift scripts/learning/sign.swift init PRIVATE_KEY ISeeYou/ModelSigningPublicKey.txt` creates a key/pin pair and refuses overwrites; changing the pin requires a locally signed app build.

```sh
python scripts/learning/pipeline.py release --package /PRIVATE/candidate-001.mlpackage --device-report /PRIVATE/device-report.json --version piano-001 --key "$HOME/.config/iseeyou-teacher/model-signing.key" --output /PRIVATE/release-001
python scripts/learning/pipeline.py deliver --release /PRIVATE/release-001 --device PHYSICAL_DEVICE_ID
```

After staging, stop the camera and tap **Detector updates → Install reviewed model update**. The app checks the pinned signature, file list, paths, sizes and SHA256 digests, compiles off the main thread, verifies Vision-compatible outputs, then atomically selects the model. It preserves the previous model and uses it or the bundle on load failure. Updates cannot be applied while starting/capturing, and Start is blocked during an update. Duplicate installed versions are rejected. **Use bundled detector** provides explicit rollback while stopped. Existing calibration and bundle ID are preserved. Uploaded metadata records the detector actually loaded, instead of always claiming the bundled version.

## Current boundary

The workflow is operator-invoked and local. Nightly AWS inventory remains inventory-only; it does not train. Review UI, automatic curation, cloud training, signed OTA downloads, automatic rollouts and a representative hazard/safety benchmark are not implemented by this workflow. Passing software checks does not mean a piano-trained model exists: no new weights are available until review, data coverage, training and physical acceptance are complete.

## Implementation verification (24 October 2026)

Eight learning workflow tests and twelve AWS worker/ingestion tests pass. The learning tests include curation, a mocked trainer/evaluator contract, split/duplicate leakage, class regressions, dataset tampering and refusal to release without physical evidence. No actual training or new CoreML export has been run. Debug and signed Release iPhone builds pass. A standalone Mac smoke test using the existing baseline package passed signature verification, on-device-format compilation, activation, loading and rollback in an isolated temporary store; it did not promote a phone model.

The first physical run passed 50 of 51 tests and exposed an Apple `/var` versus `/private/var` path-alias discrepancy in signed file enumeration. That bug is fixed and passes the Mac checks. The final rebuilt physical suite passed on the physical iPhone: 51 passed, 1 optional shadow benchmark skipped, 0 failed. The signed Release app was installed with the existing bundle ID. The skipped benchmark requires a staged evaluated candidate; separate physical camera/alignment/speech/thermal/battery acceptance remains necessary for any future candidate. The Mac had about 3.4 GiB free during implementation, below the training runner's 5 GiB minimum. No cleanup, GPU job or model promotion was started.
