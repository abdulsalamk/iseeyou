# I See You: AWS teacher development snapshot

Status updated 24 October 2026 after deploying the session-end learning path to the London teacher stack and installing the signed YOLO11 app build on the physical iPhone. Only generated synthetic fixtures were used for cloud workflow checks; no personal camera upload, SageMaker training job or model promotion was performed.

## Implementation at a glance

| Area | Implemented | Still incomplete |
| --- | --- | --- |
| Terraform foundation | London S3 remote state, versioning, encryption, public-access blocking, TLS-only policy, native S3 state locking; repository-scoped GitHub OIDC | Deployment CI for the teacher stack is not configured; the OIDC role only has state access |
| Media ingestion | Signed image/MP4 API plus session IDs, three individually uploaded camera frames, and an idempotent session-close endpoint | Current pilot still uses one device token |
| Teacher worker | Encrypted SQS/Lambda/Bedrock worker requests per-frame object boxes and compares Nova labels with detector outputs; Nova starts after session close | Nova labels are pseudo-labels; their class and spatial accuracy are unverified |
| App teaching mode | Opt-in sampler stores the three camera frames, uploads over Wi-Fi after Stop if needed, and closes that explicit session for background work; signed build is installed on the physical iPhone | Camera-to-cloud session behaviour still needs real-device verification |
| Session learning | Deployed session-indexed candidate aggregation, session-close dispatch, Nova receipts, data-coverage gates, asynchronous SageMaker AI training and a single-job lock | No training job has run |
| YOLO | Bundled YOLO11n remains the app's live model; SageMaker job writes a separate pseudo-label candidate to private S3 only | Automated labels are proxy targets; candidate evaluation is not ground truth and nothing is promoted or installed automatically |
| Budget | Deployed £8 monthly workflow reservation stop, a $12 AWS service budget with an automatic stop at 80%, and capped 15-minute single-instance jobs | This AWS account accepts USD budgets only; $12 was about £8.96 on 24 Oct 2026, and exchange rates/billing data can move |

## Infrastructure already deployed

The `abdul` profile was used from the Mac to deploy in **eu-west-2 (London)** for the teacher pilot:

- Terraform state bucket: `iseeyou-terraform-state-885625664603-eu-west-2`.
- Private media bucket: `iseeyou-teacher-data-885625664603-eu-west-2`.
- Media prefixes: `raw/images/`, `raw/frames/`, `raw/clips/`, `raw/manifests/`; results: `candidates/`; nightly inventories: `reviews/`; local-branch training outputs: `learning/`.
- Encrypted sample queue and dead-letter queue, `iseeyou-teacher-worker` Lambda and a CloudWatch dead-letter alarm. The alarm has no notification subscription yet.
- `iseeyou-teacher-ingestion` Lambda behind an HTTP API and `iseeyou-teacher-uploads` DynamoDB table for upload tickets and the daily quota.
- `iseeyou-teacher-review` Lambda, `iseeyou-teacher-nightly` Step Functions state machine, and an EventBridge rule scheduled for **02:00 UTC daily**.
- The session-end API, DynamoDB GSI, Step Functions/Lambda workflow, private SageMaker role, baseline checkpoint and budget stop are deployed in London. No training job has been submitted.
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

## On-demand learning implementation

The existing [local learning workflow](LOCAL_LEARNING.md) remains operator-invoked and human-reviewed. The app now records a persistent learning route per session. AWS sessions retain the existing behavior: the deployed session workflow starts Nova after explicit session close, then SageMaker may start a private shadow YOLO job after grouped data-coverage gates pass. The job stores a candidate only; it cannot update the detector used by the app. The nightly inventory schedule remains unchanged. Local Mac sessions write to the separate `local/raw/` prefix, excluded from the AWS worker's S3 notification, and session completion returns `queued_for_local_mac` without starting Step Functions. `scripts/learning/fetch_local_queue.py` downloads the retained local queue for on-Mac review.

On 25 October 2026, the routing updates were deployed from this Mac using the `abdul` profile: eight resources changed, none added or destroyed. A follow-up Terraform plan reported no drift. A synthetic-only end-to-end local-route smoke test confirmed the ticket, isolated S3 manifest and `queued_for_local_mac` receipt; the synthetic S3 versions, DynamoDB rows and daily quota increment were removed/restored. No Bedrock, Step Functions or SageMaker work was started. The signed app was installed on the physical iPhone 15 Pro, and its complete `UnitChecks` run passed 51 tests, failed 0 and skipped 1 (`testStagedCandidateBenchmark`, no staged candidate package).

The backend was applied using `AWS_PROFILE=abdul`; a synthetic-only session exercised the deployed Nova workflow and ended at `awaiting_more_pseudo_labels`, with no SageMaker job. The fixture media, candidates, session rows and inference locks were removed afterward; £0.15 of conservative inference reservations remains counted in the monthly ledger. The app was subsequently signed with the Xcode Personal Team profile and installed on the physical iPhone as `com.iseeyou.research` (version 1.0, build 1); it launched successfully. YOLO11n remains the live detector. The YOLO11 baseline is marked by the annotated Git tag `baseline/live-yolo11-2026-10-24`.

## Recommended next development steps

1. Verify explicit Stop closes a teacher session while lifecycle stops do not.
2. Keep model promotion disabled. Evaluate candidate checkpoints against a separately reviewed dataset before changing the app's active model.
