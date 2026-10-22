# Walls, doors, and unrecognised surfaces: investigation

Status: design investigation, 22 October 2026. No wall/door recogniser is installed. The glasses lock-screen retest is deferred until the user has the glasses.

## Why the current app misses them

The bundled pretrained YOLO11n detects COCO object classes, which do not include walls or doors. MetricDepthEstimator obtains a dense depth map for the entire frame but only samples it inside YOLO detection boxes. A wall with no detection box therefore produces no speech candidate. Lowering the confidence threshold does not create a missing class.

## Recommended progression

1. Expose a compact, same-frame depth summary independent of detector boxes. Detect a persistent nearby central surface using valid-pixel coverage and robust region statistics, rejecting invalid, mixed-depth and unstable readings. This can provide an experimental "surface ahead, approximately ..." description when object identity is unavailable. Depth alone must not label a wall or door, classify a floor, or declare a walking route clear. Start with a diagnostic overlay and stationary checks.
2. Evaluate a lightweight ADE20K semantic-segmentation model. NVIDIA's SegFormer B0 ADE checkpoint explicitly includes wall (0), floor (3), windowpane (8), door (14), and mirror (27). Segmentation assigns image regions rather than object boxes. Align its mask to the original frame and depth map; sample depth within the mask, not the enclosing rectangle. Use lower-rate segmentation with bounded work and measure total latency and thermal performance alongside the existing detector and depth model.
3. Combine identity and distance conservatively: "wall ahead, approximately 1.5 metres" or "door ahead, approximately 2 metres" only when mask confidence, region size, stability, and current depth support the description. Otherwise use "surface ahead" when geometric evidence exists, or abstain when it does not. Deduplicate surface and object announcements; retain the user's under-0.5-metre "very close" wording and deferred beeps.
4. Treat door state as a separate capability. The checkpoint has a generic door label, not open-door and closed-door classes. A visible door panel may be open beside the wearer; a doorway's background depth is not proof of a traversable opening. Add a door-state model or annotated training/evaluation set before saying "closed door" or giving an opening/navigation instruction.

## Candidate and constraints

SegFormer B0 is an evaluation candidate, not a confirmed Core ML/mobile deployment. The checkpoint is fine-tuned at 512 x 512; input changes and conversion need numerical and scene comparisons. Its upstream licence is research/evaluation, non-commercial; review the exact weights and redistribution terms before bundling or publishing. Do not assume it inherits the licence of the Transformers library. No weights have been downloaded for this investigation.

The first surface-only experiment can reuse the existing depth model, avoiding a third model initially. It cannot distinguish a floor, wall, glass pane, mirror, or dark opening reliably by itself. Semantic masks improve naming and floor rejection but do not establish safety. Standard iPhone 16 and Meta glasses do not supply a LiDAR depth map to this pipeline. Existing monocular depth remains experimental and glasses calibration is separate from phone calibration.

## Evaluation before speech

Use a sighted stationary tester and tape-measured distances at 0.5, 1, 1.5, 2, and 3 metres. Include blank and textured walls, closed/open/part-open doors, doors against similarly coloured walls, open door panels off centre, narrow corridors, floors when looking down, windows, mirrors and glass doors, dim/bright lighting, head motion, and partial occlusion. Evaluate phone and glasses separately.

Record surface recall, false announcements, wall/door/floor confusion, depth error, stale-frame rejection, end-to-end latency, and sustained processing/battery behaviour. No "path clear", "safe", "go", or "open the door" output should be inferred from a missing detection. Prioritise reliable generic surface descriptions over unsupported specific names. Synthetic tests validate sampling and alignment; they cannot establish real-world recognition or navigation safety.

## Primary sources

- Bundled model provenance: models/README.md; local implementation: ISeeYou/MetricDepthEstimator.swift and ISeeYou/HazardAssessment.swift.
- Official COCO class configuration: https://github.com/ultralytics/ultralytics/blob/main/ultralytics/cfg/datasets/coco.yaml
- NVIDIA checkpoint and model card: https://huggingface.co/nvidia/segformer-b0-finetuned-ade-512-512
- Exact label configuration: https://huggingface.co/nvidia/segformer-b0-finetuned-ade-512-512/blob/main/config.json
- Official SegFormer implementation and licensing statement: https://github.com/NVlabs/SegFormer
