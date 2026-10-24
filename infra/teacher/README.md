# Silent vision teacher pilot

Private uploads → versioned S3 → encrypted SQS → Lambda → explicitly marked mock response or Bedrock Nova → candidate results. EventBridge and Step Functions produce a nightly candidate inventory. Training is currently skipped; no model is promoted.

See [the implementation status and remaining work](../../docs/AWS_TEACHER_STATUS.md) before running or deploying anything. That document records the deployed resources, verified live Nova access, AWS Support case, phone opt-in behaviour, test evidence and known gaps.

## Source layout

- `main.tf`: private media bucket, queue, teacher Lambda, model/mode settings and alarms.
- `ingestion.tf`: upload API, ingestion Lambda, single-device token digest and daily ticket quota.
- `nightly.tf`: nightly inventory Lambda and EventBridge/Step Functions wiring.
- `lambda/teacher.py`: version-pinned first-image analysis; proposed-only results; explicit mock mode.
- `lambda/ingestion.py`: signed image/MP4 uploads, checksums, completion and processing receipts.
- `lambda/review.py`: candidate inventory and explicit skip-training result.
- `../../ISeeYou/BackgroundTeacher.swift`: opt-in phone sampler, queue, upload client and status.

## Configuration boundaries

The backend is defined by `backend.hcl`, separate from bootstrap state. The GitHub bootstrap role intentionally cannot deploy this stack. Deployment uses local AWS authentication and a private variable file containing the `device_token_hash` digest and deployment mode settings. The actual token and device handoff configuration stay outside Git; never put AWS credentials in the app.

Default mode is `mock`, with `model_access_ready=false`. The queue still processes mock work. `mock_complete` is not AI analysis, and no mock result is training eligible. The London pilot was deliberately switched to `live` with `model_access_ready=true` on 24 October 2026 after successful synthetic text/image tests. Keep those inputs in the private deployment variable file when maintaining that stack; the repository defaults remain mock. A fresh authenticated synthetic upload completed through SQS and returned a real `proposed_only` receipt. All results remain excluded from training.

The worker permits one validated correction attempt for malformed or incomplete model output and records cumulative usage and `inference_attempts`. Exhausted attempts fail rather than storing invalid proposals. Existing completed manifests are cached, including old mock results; use a fresh sample for a live test.

The original image-only manual uploader remains in `scripts/aws/upload_teacher_sample.py` for controlled tests. It requires explicit consent and a local AWS profile. It bypasses the phone API's ticket quota because it uses administrator-authorised AWS access; it is not a production ingestion client.

No deployment, training or model promotion is triggered by publishing this branch.
