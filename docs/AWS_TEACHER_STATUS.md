# I See You: AWS teacher development snapshot

Status recorded 24 October 2026. This is a review snapshot of issue 3, not a completed automatic YOLO training system. The publication task does not redeploy infrastructure, start training, install an app, or change AWS resources.

## Implementation at a glance

| Area | Implemented | Still incomplete |
| --- | --- | --- |
| Terraform foundation | London S3 remote state, versioning, encryption, public-access blocking, TLS-only policy, native S3 state locking; repository-scoped GitHub OIDC | Deployment CI for the teacher stack is not configured; the OIDC role only has state access |
| Media ingestion | Private S3, signed image/MP4 uploads, SHA256 and size verification, immutable writes, completion receipts, version-pinned manifests | Single-device pilot token, not multi-user identity; no user-facing remote deletion workflow |
| Teacher worker | Encrypted SQS, Lambda, partial-batch retries, dead-letter queue, Nova Converse integration, explicit mock mode | Real Bedrock inference remains blocked; currently only the first image is analysed, not temporal video content |
| App teaching mode | Opt-in switch, utility-queue sampler, silent low-rate MP4 encoding, Wi-Fi uploads, bounded local queue, receipt/status display | Final normal Release installation, private device provisioning and live camera-to-cloud testing are pending |
| Nightly processing | EventBridge schedule, Step Functions, Lambda candidate inventory and an explicit training-skip result | Label verification, curated datasets, historical replay and conditional GPU training are not implemented |
| YOLO | Existing YOLO11n CoreML detection remains the live local path; export tooling and prediction metadata are retained | No retraining, new weights, held-out model evaluation or automatic model delivery has occurred |

## Infrastructure already deployed

The `abdul` profile was used from the Mac to deploy in **eu-west-2 (London)** before this publication task:

- Terraform state bucket: `iseeyou-terraform-state-885625664603-eu-west-2`.
- Private media bucket: `iseeyou-teacher-data-885625664603-eu-west-2`.
- Media prefixes: `raw/images/`, `raw/clips/`, `raw/manifests/`; results: `candidates/`; nightly inventories: `reviews/`.
- Encrypted sample queue and dead-letter queue, `iseeyou-teacher-worker` Lambda and a CloudWatch dead-letter alarm. The alarm has no notification subscription yet.
- `iseeyou-teacher-ingestion` Lambda behind an HTTP API and `iseeyou-teacher-uploads` DynamoDB table for upload tickets and the daily quota.
- `iseeyou-teacher-review` Lambda, `iseeyou-teacher-nightly` Step Functions state machine, and an EventBridge rule scheduled for **02:00 UTC daily**.
- IAM roles scoped to each service's work. No AWS credentials are distributed to the phone.

S3 raw media expires after seven days; candidates after thirty days; noncurrent versions after one day. These are asynchronous lifecycle policies, not immediate erasure. Versioned deletion requires removing all versions. Nightly inventory reports currently have no expiry rule.

## Terraform and GitHub Actions

`infra/bootstrap/` manages the foundation; `infra/teacher/` manages ingestion, worker and nightly inventory. Remote state keys are separate:

- `bootstrap/terraform.tfstate`
- `states/iseeyou/teacher.tfstate`

Native S3 lock files are enabled. State, plans, `.terraform/`, private variable files and device configuration are excluded from this commit. Provider lock files contain dependency checksums, not credentials.

The existing workflows are retained unchanged in this branch:

- `.github/workflows/aws-bootstrap-check.yml`: manual-only OIDC and private state-bucket round-trip test, restricted to `main`. [The recorded run passed](https://github.com/abdulsalamk/iseeyou/actions/runs/40039508994).
- `.github/workflows/ios-build.yml` and `.github/workflows/deployment-checks.yml`: historical workflows, both **disabled manually** in repository settings at the time of this snapshot.

Pushing this development branch does not automatically deploy the teacher stack, train YOLO or install the app. This PR does not enable workflows or merge to `main`.

The last teacher deployment included the upload API, explicit mock processing and nightly inventory. No new Terraform plan/apply is needed merely to preserve this snapshot. Future authorised deployments require the private `device_token_hash` input; the raw device token must never be put in Terraform variables or Git.

## Nova error and AWS Support

The live integration calls Bedrock Converse with `amazon.nova-lite-v1:0`. Direct testing outside Lambda using the configured account identity reproduced the same error in London and Ireland:

```text
An error occurred (ValidationException) when calling the Converse operation: Operation not allowed
```

The model-availability API returned:

```json
{
  "agreementAvailability": {"status": "AVAILABLE"},
  "authorizationStatus": "NOT_AUTHORIZED",
  "entitlementAvailability": "AVAILABLE",
  "regionAvailability": "AVAILABLE"
}
```

Nova Pro and Nova 2 Lite availability checks in London also returned `NOT_AUTHORIZED`. These observations point toward an account-access restriction but do not establish its underlying cause.

[AWS Support case 179282542400226](https://support.console.aws.amazon.com/support/home#/case/?displayId=179282542400226&language=en) was submitted under Account / Other Account Issues. Gmail received the automatic case-opening acknowledgement and correspondence notice. The latest checked case contained only our submission, with no agent answer; model access is unresolved. No support-plan upgrade was requested.

Terraform currently defaults to `teacher_mode="mock"`, with live model access unconfirmed. Queue processing is enabled for **mock** work; mock results explicitly say `MOCK_NO_INFERENCE`, have status `mock_complete`, have no invented discrepancy labels, and remain `training_eligible=false`. They cannot establish model accuracy or training readiness.

When access is resolved, an authorised operator must deliberately select live mode and confirm access before testing a real response. That change is outside this publication task. Current result deduplication uses the manifest version, so replaying an existing mock-completed manifest does not automatically replace it with live inference.

## Phone teaching mode and periodic capture

`ISeeYou/BackgroundTeacher.swift` and the camera-view integration are included for review:

- Sharing starts **off on every app launch**. Opening the app alone does not capture or upload teacher samples.
- Sampling requires the **Share camera samples with the teacher** switch, an active camera session, and a privately provisioned connection.
- Three low-rate camera frames form an approximately three-second silent MP4; a new clip starts roughly a minute after the previous capture finishes. This is sampled imagery, not full-frame-rate continuous recording.
- The first JPEG and its YOLO predictions accompany the clip. Metadata includes each sampled frame's timestamp, clip offset, source and normalized boxes. Timestamps are phone-side sampling times, not verified glasses sensor-capture times.
- A utility queue handles conversion, encoding and network work. At most one camera buffer waits for that work; frames are dropped rather than building an unbounded capture backlog. Sampling pauses at serious/critical thermal states.
- Up to four pending clips are stored in an application-support folder excluded from backup. Files use iOS data protection. Queued samples expire after 24 hours and are removed when the app next gets execution time; iOS suspension prevents an exact wall-clock deletion guarantee.
- Wi-Fi-only requests use checksum-bound, short-lived signed S3 URLs. The server verifies both durable object versions and checksums before local media is removed.
- Upload retries use backoff with a per-clip attempt limit. The API allows at most fifty new upload tickets per UTC day for this single-device pilot. This is not a monetary/token spend cap or protection for direct administrator uploads.
- The private connection is imported into the device Keychain from a one-time local handoff file. The handoff file is deleted only after successful Keychain storage. **The development device has not been provisioned as part of this publication task.** Never commit that file, token, signed URLs or local configuration.

Status meanings:

| Indicator | Meaning |
| --- | --- |
| Grey | Sharing off |
| Orange | Waiting, sampling, uploading, receipt pending, or explicitly labelled mock completion |
| Green | A real teacher response receipt was confirmed; it does not mean a correction is accurate |
| Red | Missing configuration or an upload/processing problem |

Switching sharing off stops new work; an in-flight request may finish. This is not a system-wide watcher, screen capture, microphone recording, or an always-running iOS daemon. Locked-phone/glasses behaviour and battery/latency overhead remain unverified. The new sampler has not yet been installed and accepted as the final normal Release build; physical tests used a test-host build.

## Verification already performed

These checks ran during development before the preservation task; no training or redeployment was performed to prepare this PR:

- Terraform validation passed for the deployed configuration.
- Ten focused Python tests passed, covering input/consent rejection, checksum rejection, cached results, queue partial failures, and mock separation from Bedrock.
- A generated three-second clip and JPEG completed authenticated HTTP ingestion, S3 checksum verification, idempotent completion/ticket retry, queue processing and retrieval of a `mock_complete` receipt with training disabled. Invalid authentication was rejected.
- A manual execution of the nightly Step Functions workflow succeeded, saved a candidate inventory and returned `training="skipped"`, `model_promoted=false`.
- The local iPhone Release build passed before the final encoder refinement. The existing 47 physical-device tests passed. A separate focused encoder test passed after refinement, verifying a decodable approximately three-second video, expected timestamps, no audio, and sharing disabled by default. These are not a single combined 48-test run.
- The initial encoder test assumed one encoded sample per input image and failed. The final test decodes frames and checks timestamps/duration rather than that codec-dependent assumption.

No real user camera footage has been uploaded during these tests; the AWS media fixture was generated. No new model weights have been trained, exported or promoted.

## Recommended next development steps

1. Review this PR, especially upload authentication, media lifecycle/deletion, source timestamps and queue behaviour. Keep model access unresolved in the status until a live test proves otherwise.
2. Resolve the AWS Support case and run one authorised live Nova test; keep mock results excluded from datasets.
3. Provision the device privately, build/install a normal local Release version, then test opt-in camera-to-cloud capture, errors, offline retries, app relaunch, interruption and receipt recovery. Measure battery, thermal, inference latency and frame drops on both camera sources.
4. Harden the single-device pilot: per-user/device authentication and revocation, queue/receipt recovery under multiple outstanding uploads, clearer quota feedback, deletion controls, spend limits and alarm notification routing.
5. Implement semantic and spatial annotation validation plus a versioned curated dataset and historical replay. The current lexical label-set comparison is not validated object matching.
6. Add sufficient-data checks, reproducible conditional YOLO training, a held-out benchmark and regression/performance gates. The nightly inventory currently performs none of those training/evaluation steps.
7. Implement signed staged CoreML delivery and rollback only after those gates exist and are tested. Do not automatically replace the working detector with mock or unvalidated outputs.
