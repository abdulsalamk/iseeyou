# Manual door-state experiment

This is an on-device **zero-shot scene comparison**, not a door-specific trained detector, semantic segmentation model, or validated navigation capability. There is no door bounding box, door-distance measurement, clear-opening measurement, lock-state inference, or automatic door warning. Existing object and surface distance descriptions remain separate.

## Use

1. Start either camera manually.
2. Locate **Check and speak door state**, now visible in the main controls.
3. Aim the centre of the image at one door and hold still.
4. Press **Check and speak door state**.

The app collects at least three consistent fresh observations spanning 0.8 seconds. It then speaks a tentative state: "Door may be closed", "Door may be partly open", or "Door may be open. Opening not verified." Ambiguity, missing model input, inconsistent results, a stale image, or an eight-second timeout yields "Door not established. State uncertain.". Stop/source changes invalidate pending results. No doorway photograph is stored or transmitted.

The scene model compares open/partly-open/closed prompts with wall, window, cabinet, mirror, screen, room, and curtain distractors. The provisional gate requires door similarity at least 0.25, separation from the strongest distractor at least 0.025, and separation from the second door state at least 0.03 for a specific state. If the first two gates pass but state separation fails, it says "Possible door. Open or closed uncertain." This does not weaken the thresholds for an open, partly open, or closed result. These cosine similarities and margins are **not calibrated confidence percentages**. The thresholds do not establish real-world accuracy. Classification uses a centre square crop; a door outside the crop may be missed, and a cabinet/window can still be mistaken for a door. No "safe", "go", "path clear", or "unlocked" decision is produced.

## Model and size

The model is the image tower of official **OpenAI CLIP ViT-B/32**, MIT licensed, converted to Core ML with FP16 computation and symmetric per-channel int8 weight compression. Source: https://github.com/openai/CLIP at commit d05afc436d78f1c48dc0dbf8e5980a9d471f35f6 . This is a general image-text model; the door phrases are not new supervised training.

The image weights occupy 88,162,624 bytes (about 88 MB decimal / 84 MiB). This is a substantial addition to the previous build. Only the image encoder and fixed text embeddings are bundled; the text encoder and original 338 MiB checkpoint are not installed on the phone. CPU/Neural Engine execution and software image preprocessing avoid GPU-only work. The model loads lazily when the manual check is requested; it does not run continuously by default.

Attribution: Copyright (c) 2021 OpenAI. MIT licence text is in models/licenses/CLIP-Model-MIT.txt; the copied OpenAI tokenizer has the same MIT licence in CLIP-Tokenizer-MIT.txt. Model transformation/provenance and SHA-256 values are in models/door-model-provenance.json. The first MobileCLIP candidate was rejected after reviewing its research-only restrictions; none of its weights or embeddings are bundled.

## Reproduction

Create a Python 3.11 environment and install scripts/door/requirements.txt. Clone the official CLIP repository, check out the pinned commit above, and put its root on PYTHONPATH. Use clip.load('ViT-B/32', device='cpu', jit=False, download_root=...) to download the official checkpoint; verify the SHA-256 in the provenance file.

Run scripts/door/export_door_image.py with --checkpoint pointing to ViT-B-32.pt and --output ISeeYou/Models/DoorSceneImage.mlpackage. Then run scripts/door/export_door_prompts.py with the same --checkpoint and --output ISeeYou/DoorPrompts.json. The original tokenizer and BPE vocabulary are included in scripts/door. No user images are needed for these preparation steps.

Three synthetic image conversion checks gave cosine agreement above 0.9996 between original PyTorch and compressed Core ML embeddings. Details: models/door-conversion-parity.json. This measures conversion differences, not door-state accuracy.

## Evaluation still required

Before relying on state descriptions, collect sighted, labelled checks on previously unseen doors: open, closed, and partly open; different opening angles; cabinet and wardrobe doors; windows; mirrors; glass doors; blank walls; door panels open beside the doorway; dim lighting; occlusion; and camera motion. Evaluate phone and glasses separately. Record false-open results, abstentions, total latency and memory/thermal behaviour. The current code/device tests cannot establish recognition accuracy, opening width, collision safety, or sustained glasses/background operation. The deferred locked-phone glasses test remains pending.

A dedicated door localisation/state model trained with representative data remains the intended next improvement. Public datasets found include DeepDoors2 (https://github.com/gasparramoa/DeepDoors2); review exact dataset/weight rights and use held-out doors before any future training or redistribution. Fixed-office CCTV models were not adopted as a general wearable solution.

## Current verification status

All **44 tests passed on Salam’s physical iPhone 15 Pro** after the phone was unlocked. These include model inference and blank-image abstention, ambiguous/non-door score rejection, repeated/fresh state confirmation, tentative spoken wording, and existing camera/depth/glasses checks. A one-microsecond comparison tolerance handles floating-point timing boundaries. The normal development-signed build was installed successfully after this passing run.

This is code and model-runtime validation, not a real-door accuracy result. Phone/glasses door-state evaluation and the deferred locked-phone glasses check remain outstanding. The compiled development build occupies about 155 MiB on the Mac; the exact iOS storage total can differ.

## Follow-up from real-door feedback

The user reports that a closed door was described generically and that a roughly 2 m surface was estimated near 3 m. This is an unresolved real-world recognition/accuracy failure, not covered by the passing runtime tests above. Generic automatic distance descriptions now pause while an explicit door assessment is pending, so they do not mask its result. No model weights or recognition thresholds were changed without image evidence.

The distance calibration panel now offers an explicit single-point measured correction (reported and measured values; defaults 3 m and 2 m reflecting this report). This saves a multiplicative factor for the selected camera source, with confirmation before clearing old bench samples. It applies consistently to displayed and spoken object/surface distances; a full multi-distance training profile takes precedence once collected. This reference alone cannot pass validation. It is not an automatic subtraction or a verified accuracy improvement.

The follow-up iOS build succeeded. After USB reconnection, all 45 physical-device tests passed (zero failures/skips), including measured-reference scaling, persistence, invalid input rejection and reset. The normal app was installed successfully. The correction remains opt-in in the calibration panel; no real-door recognition or corrected-distance accuracy pass is claimed. Test result: Test-UnitChecks-2026.10.22_09-59-49-+0100.xcresult.

## Door-feedback follow-up

The manual button and fixed two-line result are now outside the collapsed details panel. Door evidence with ambiguous state has its own tentative result, distinct from failure to establish a door. These changes do not retrain CLIP or establish that the user's previously missed closed door will now be recognised.

The details panel shows the four strongest cosine comparisons and local frame age. Stale results still abstain. A timeout and model error are distinguished in diagnostics. The latest completed check is saved to Library/Caches/last-door-check.json (overwritten each check); it contains date, camera source, outcome, score/timing text only, with no image, embedding, video, or audio. The user can also explicitly share the displayed diagnostic text. Existing camera-source calibration is preserved during app updates.

The follow-up iOS build passed and the app installed successfully on the paired iPhone. Native checks compiled the production Swift scoring/consensus source and passed specific-state, ambiguous-state, non-door, invalid-input, and temporal checks. The expanded physical-device XCTest run is still pending phone unlock (the initial run was cancelled at Xcode’s locked-device prompt). The prior 45-test pass applies to the previous build. No real-door recognition or distance-accuracy validation is claimed.
