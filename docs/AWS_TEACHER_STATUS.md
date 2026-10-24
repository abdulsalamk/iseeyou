# I See You: AWS teacher development snapshot

Status updated 24 October 2026 after enabling and testing live Nova Lite inference in London. This remains an issue 3 pilot, not a completed automatic YOLO training system. No phone installation, personal camera upload, training or model promotion was performed during live activation.

## Implementation at a glance

| Area | Implemented | Still incomplete |
| --- | --- | --- |
| Terraform foundation | London S3 remote state, versioning, encryption, public-access blocking, TLS-only policy, native S3 state locking; repository-scoped GitHub OIDC | Deployment CI for the teacher stack is not configured; the OIDC role only has state access |
| Media ingestion | Private S3, signed image/MP4 uploads, SHA256 and size verification, immutable writes, completion receipts, version-pinned manifests | Single-device pilot token, not multi-user identity; no user-facing remote deletion workflow |
| Teacher worker | Encrypted SQS, Lambda, partial-batch retries, dead-letter queue, verified live Nova Lite inference, explicit mock mode, bounded response correction | Currently only the first image is analysed, not temporal video content; labels and boxes remain unverified proposals |
| App teaching mode | Opt-in switch, utility-queue sampler, silent low-rate MP4 encoding, Wi-Fi uploads, bounded local queue, receipt/status display | Final normal Release installation, private device provisioning and live camera-to-cloud testing are pending |
| Nightly processing | EventBridge schedule, Step Functions, Lambda candidate inventory and an explicit training-skip result | Label verification, curated datasets, historical replay and conditional GPU training are not implemented |
| YOLO | Existing YOLO11n CoreML detection remains the live local path; export tooling and prediction metadata are retained | No retraining, new weights, held-out model evaluation or automatic model delivery has occurred |

## Infrastructure already deployed

The `abdul` profile was used from the Mac to deploy in **eu-west-2 (London)** for the teacher pilot:

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

The latest Terraform deployment enabled live processing and updated the shared Lambda package with the response-validation fix. No resources were added or destroyed. Future deployments require the private `device_token_hash` input; the raw device token must never be put in Terraform variables or Git. The local private variable file now also persists `teacher_mode="live"` and `model_access_ready=true`; repository defaults remain mock for unconfigured deployments.

## Live Nova access and previous AWS Support blocker

The live integration calls Bedrock Converse with `amazon.nova-lite-v1:0`. On 24 October, direct text and synthetic-image checks succeeded in London using `abdul`, and the deployed worker subsequently completed live image inference. The previous blocker is resolved for this model in London; other models and regions were not rechecked.

Earlier direct tests in London and Ireland failed with:

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

[AWS Support case 179282542400226](https://support.console.aws.amazon.com/support/home#/case/?displayId=179282542400226&language=en) was submitted under Account / Other Account Issues. Gmail received the automatic case-opening acknowledgement and correspondence notice. The earlier case check contained only our submission. Support correspondence and case closure were not rechecked during live activation; successful inference establishes current access independently. No support-plan upgrade was requested.

The deployed worker now uses **live** mode with queue consumption enabled. Repository defaults remain `teacher_mode="mock"` and `model_access_ready=false`. Mock results explicitly say `MOCK_NO_INFERENCE`, have status `mock_complete`, contain no invented discrepancy labels, and remain `training_eligible=false`. Live results have status `proposed_only` and also remain `training_eligible=false`.

The initial live pipeline test exposed malformed JSON from Nova (an extra closing bracket). The worker now requests a concise JSON object and allows one correction attempt for malformed, truncated or invalid proposals. Both attempts must pass the existing geometry/schema validation; no heuristic JSON repair is applied. Token counts are summed across attempts and `inference_attempts` records zero for mock or one/two for live. Bedrock calls have a 45-second read timeout, a five-second connection timeout and no automatic SDK retries, keeping the two-call correction path bounded within the worker's 120-second execution budget. Exhausted correction attempts still fail for SQS retry/dead-letter handling.

Result deduplication still uses the manifest version. Replaying an existing mock-completed manifest does not replace it with live inference; a fresh manifest is required.

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

Prior development checks:

- Terraform validation passed for the deployed configuration.
- Ten focused Python tests passed, covering input/consent rejection, checksum rejection, cached results, queue partial failures, and mock separation from Bedrock.
- A generated three-second clip and JPEG completed authenticated HTTP ingestion, S3 checksum verification, idempotent completion/ticket retry, queue processing and retrieval of a `mock_complete` receipt with training disabled. Invalid authentication was rejected.
- A manual execution of the nightly Step Functions workflow succeeded, saved a candidate inventory and returned `training="skipped"`, `model_promoted=false`.
- The local iPhone Release build passed before the final encoder refinement. The existing 47 physical-device tests passed. A separate focused encoder test passed after refinement, verifying a decodable approximately three-second video, expected timestamps, no audio, and sharing disabled by default. These are not a single combined 48-test run.
- The initial encoder test assumed one encoded sample per input image and failed. The final test decodes frames and checks timestamps/duration rather than that codec-dependent assumption.

Live activation verification on 24 October 2026:

- All twelve focused Python tests passed, including one-correction recovery, aggregate token accounting, and rejection of repeatedly malformed, truncated or invalid-box responses without writing candidates. Terraform validation passed.
- Both sample and dead-letter queues were empty before live activation. Terraform first changed only worker mode, then updated the three functions that share the Lambda source archive after the response fix.
- A generated JPEG and silent three-second MP4 passed authenticated HTTP ingestion, signed uploads, checksum verification, ticket/completion retries, S3 notification, SQS processing and a real `proposed_only` receipt. Unauthenticated receipt access returned 401.
- Fresh sample `f86f06c8-496e-4b78-821c-ccf92a8f0803` produced candidate `61bf6b5aa2b082b50aebd0a74a288962f131d036f7e414f415059c1cf58e4f1f`, using 650 input and 47 output tokens. Nova described a red square on white. This simple fixture does not establish real-world recognition or box accuracy.
- The earlier synthetic sample that failed JSON parsing was recovered through a controlled worker invocation after the fix. Duplicate worker invocations for both completed samples returned no batch failures and left the candidate object versions unchanged; cached-result unit coverage verifies no repeat model invocation.
- No real camera capture or phone provisioning was performed. The deployed teacher still analyses only the accompanying JPEG, not video over time.

No real user camera footage has been uploaded during these tests; the AWS media fixture was generated. No new model weights have been trained, exported or promoted.

## Recommended next development steps

1. Review upload authentication, media lifecycle/deletion, source timestamps and queue behaviour. Live Nova access is now verified; recognition and annotation quality are not.
2. Keep mock results and unvalidated live proposals excluded from training datasets. Recheck the Support case separately if a closure update is needed.
3. Provision the device privately, build/install a normal local Release version, then test opt-in camera-to-cloud capture, errors, offline retries, app relaunch, interruption and receipt recovery. Measure battery, thermal, inference latency and frame drops on both camera sources.
4. Harden the single-device pilot: per-user/device authentication and revocation, queue/receipt recovery under multiple outstanding uploads, clearer quota feedback, deletion controls, spend limits and alarm notification routing.
5. Implement semantic and spatial annotation validation plus a versioned curated dataset and historical replay. The current lexical label-set comparison is not validated object matching.
6. Add sufficient-data checks, reproducible conditional YOLO training, a held-out benchmark and regression/performance gates. The nightly inventory currently performs none of those training/evaluation steps.
7. Implement signed staged CoreML delivery and rollback only after those gates exist and are tested. Do not automatically replace the working detector with mock or unvalidated outputs.
