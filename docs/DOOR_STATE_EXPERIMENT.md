# Manual door-state experiment

This is an on-device **zero-shot scene comparison**, not a door-specific trained detector, semantic segmentation model, or validated navigation capability. There is no door bounding box, door-distance measurement, clear-opening measurement, lock-state inference, or automatic door warning. Existing object and surface distance descriptions remain separate.

## Use

1. Start either camera manually.
2. Expand **Door-state experiment**.
3. Aim the centre of the image at one door and hold still.
4. Press **Check and speak door state**.

The app collects at least three consistent fresh observations spanning 0.8 seconds. It then speaks a tentative state: "Door may be closed", "Door may be partly open", or "Door may be open. Opening not verified." Ambiguity, missing model input, inconsistent results, a stale image, or an eight-second timeout yields "Door state uncertain". Stop/source changes invalidate pending results. No doorway photograph is stored or transmitted.

The scene model compares open/partly-open/closed prompts with wall, window, cabinet, mirror, screen, room, and curtain distractors. The provisional gate requires door similarity at least 0.25, separation from the strongest distractor at least 0.025, and separation from the second door state at least 0.03. These cosine similarities and margins are **not calibrated confidence percentages**. The thresholds do not establish real-world accuracy. Classification uses a centre square crop; a door outside the crop may be missed, and a cabinet/window can still be mistaken for a door. No "safe", "go", "path clear", or "unlocked" decision is produced.

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

The first physical-device run executed 44 checks: the model smoke test and blank-image abstention passed; 43 checks passed overall and a consensus timing-boundary assertion failed due to floating-point representation of 3.8 minus 3.0. A one-microsecond comparison tolerance fixes that boundary, and a native compiled policy check using the production source passes. The final full iPhone rerun is blocked by the locked phone and was cancelled to avoid an unattended test launch later. The new door build has not yet been installed; unlock the phone and rerun the checks before installation. No claim of 44 passing device tests or real-door accuracy is made yet.
