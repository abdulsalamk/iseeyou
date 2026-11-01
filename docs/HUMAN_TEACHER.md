# Human-in-the-loop Teacher Mode (issue 6)

## Use

Teacher Mode is a separate switch from periodic sample sharing and starts off on every launch. Start the camera, enable **Teacher Mode — volunteer corrections**, grant Speech/Microphone permission, and aim at exactly one detected object. Say **“Correction, this is a piano”**. Other short object labels are accepted. Stop the camera to allow queued uploads while the app remains visible on Wi-Fi. Do not enable periodic sharing unless you also want the separate sampled-session workflow.

English (en-GB) on-device Speech recognition is required. Availability is checked; unsupported devices/languages display a message instead of sending microphone audio to a cloud service. No audio or clip is written or uploaded. This conservative first implementation rejects zero/multiple detections instead of guessing a target; missed-object annotation and selecting one of several objects are not implemented.

The microphone changes the active audio session to play-and-record only during listening. Alert speech retains priority and remains enabled; audio-session deactivation is suppressed while listening. Bluetooth input/output routes and actual simultaneous recognition/alert quality need manual verification on the intended equipment. Turning Teacher Mode off or making the app inactive stops listening. No always-running iOS watcher is promised.

## Capture and queue

YOLO passes its original detections and model version with the exact pixel buffer, before low-confidence display renaming. The inference path only claims a single bounded slot and dispatches to a utility queue. That queue keeps at most three 640px JPEG frames, sampled no faster than twice per second. The first partial “Correction…” recognition anchors a frame less than two seconds old. Final text must arrive within twelve seconds of that frame; stale/missing frames are rejected. Each final utterance is deduplicated before persistence. The original detection and JPEG come from the same frame; no later detection is substituted.

Each correction folder is `Application Support/HumanCorrections/<uuid>/`, excluded from backup. It contains `frame.jpg`, one atomic `correction.json`, and optional retry state. Files use complete iOS file protection. The queue caps at twenty corrections. Queued records expire after 24 hours when the app gets execution time; deletion cannot be guaranteed during suspension. Keep bystanders and private information out of view; this pilot has no face/text redaction.

Uploading requires a stopped camera and foreground app. Network work is serial, Wi-Fi-only, with bounded request/resource timeouts, exponential retry delay capped at one hour, and at most eight attempts. After eight failures the record remains until retention expiry; no infinite retries occur. A request already in flight may finish if the camera starts or the app becomes inactive; the next request is deferred. Switching Teacher Mode off stops capture but does not withdraw consent for already queued corrections. There is no background task/daemon guarantee.

## Contract and AWS

The existing private Keychain teacher connection is reused; no AWS credentials enter the phone. The API authenticates the existing bearer token. `POST /corrections` accepts `correction` plus `image_size`. It issues a 15-minute checksum-bound, encrypted, create-only S3 PUT URL. `POST /corrections/<uuid>/complete` verifies image size/checksum and writes one immutable `corrections/<uuid>/correction.json`. Identical ticket/completion retries are safe; changed contents conflict. The pilot allows fifty new correction tickets per UTC day. The separate existing session-upload daily quota is unchanged.

Schema version 1:

- `id`: UUID; the folder, media prefix and JSON identify this same correction.
- `capturedAt`, `triggeredAt`: ISO-8601 timestamps for the anchored frame and final accepted command.
- `transcriptText`, `correctedLabel`: only the correction command transcript and parsed label.
- `originalDetection`: original label, confidence, and normalized **bottom-left Vision** `boundingBox` (`x`, `y`, `width`, `height`). Downstream top-left conversion is `y_top = 1 - y - height`.
- `modelVersion`, `source`: exact detector version and camera source.
- `frameObjectKey`, `frameSHA256`: UUID-bound JPEG and hex SHA-256. Optional `clipObjectKey` is absent; the API currently rejects clips.
- `processingState`: `awaiting_validation`. This is not an approved training annotation.

Terraform adds the two authenticated routes, scoped correction-prefix S3 permissions and seven-day correction retention (old object versions expire after one day). Shared Lambda source archives are refreshed; worker/learning environment settings are unchanged. No new inference/training schedule is enabled. The unrelated pre-existing `learning.tf` edit was preserved and is not part of this feature commit.

## Downstream validation/training boundary

Correction intake does **not** invoke Nova or start training. Nova validation is a separate future consumer of `corrections/*/correction.json`, using the exact version/checksum-bound image and original detection to assess the proposed label and box. It must record agreement/disagreement/uncertainty, validator model/version, provenance and a separate validated state; uncertain/disagreed records must not become training data.

Before enabling a trainer, enforce at least **20 validated corrections** (not twenty duplicate frames), independent train/validation/test scene groups and existing-class replay, **at most one job per UTC day**, the existing monetary reservation guard, and a single-job lock. Merely receiving twenty uploads must not launch a job. Candidate weights remain private/shadow-only. Existing-class, path-object/hazard, Core ML parity and physical camera/voice/thermal regression checks must pass before a separately authorized model release. No automatic model deployment is implemented here.

## Verification — 1 November 2026

- Local signed app and physical-device test builds passed.
- Full UnitChecks on Salam’s physical iPhone: 57 passed, 0 failed, 1 skipped (58 total). The optional candidate benchmark was skipped because no candidate model is staged.
- New checks cover command parsing, ambiguous association, UUID/JSON linkage, retry/idle gates and synthetic camera-buffer capture with matching JPEG checksum/metadata on the utility queue.
- All 31 offline AWS tests passed. Existing worker tests were corrected to mock their DynamoDB lock client rather than attempting live AWS calls.
- Terraform formatting and validation passed (existing DynamoDB deprecation warnings remain).
- Reviewed targeted deployment: two routes added; correction S3 permissions/retention and shared Lambda packages updated. Worker/learning updates were package hashes only, not model/configuration changes.
- Live generated-image smoke test passed authentication rejection, ticket replay, upload, completion replay, content-change rejection and stored metadata/media linkage. Only one correction JSON object version was created. Synthetic objects/versions and their ticket were removed; the daily quota entry remains conservative. No real camera image, Nova invocation, training or model promotion was used in this smoke test.
- Final signed local Release installation succeeded. The required post-install complete UnitChecks run on the same physical iPhone passed: 57 passed, 0 failed, 1 skipped (no staged shadow candidate), result `/private/tmp/issue6-final-verified-tests.xcresult`. The test runner deploys the Debug host from the same source; no camera/microphone permissions were granted by automation.
- App launch succeeded after testing. Distance calibration matched the before-install backup byte for byte. Bundle identifier and icon display name remain unchanged.
- Manual voice/navigation acceptance was requested and remains pending. Speech permission, simultaneous alerts, Bluetooth/glasses route and real camera correction acceptance must not be inferred from synthetic tests.

Reproduce offline AWS checks in a separate virtual environment with `pip install -r tests/aws/requirements.txt`, then `python -m unittest discover -s tests/aws -p 'test_*.py'`. Tests mock service clients; do not supply live AWS credentials to the unit suite.

## Speech-capture follow-up — 1 November 2026

Real volunteer attempts produced no correction records. The first implementation waited for `SFSpeechRecognitionResult.isFinal`, which continuous recognition may withhold even after returning a complete command. The fix accepts a valid command after 1.2 seconds with unchanged recognized text, or immediately on a final result. Repeated partials do not postpone capture; revised text invalidates older pending captures; final/partial duplicates cannot create another correction. Only the command portion after the word “Correction” is retained, not preceding ambient conversation.

The screen now separates microphone buffers/sound detection, recognized command preview, and a persistent last correction outcome. A successful save vibrates and announces through VoiceOver when active. Audio remains on-device and is neither recorded nor uploaded. Metadata-only diagnostics (`HumanTeacherStatus.json` in Application Support, file-protected and excluded from backup) allow inspection without screen mirroring or restarting the camera. The diagnostics show errors/rejections; a “Listening” message alone is not proof of recognized speech.

Regression coverage includes unchanged partial results, revised commands, duplicate final results, incomplete commands, and a synthetic frame capture through the actual partial-transcript path without a final result. The first updated device suite passed 60 tests with zero failures and one unstaged-candidate benchmark skipped (61 total). Final installation and post-install results follow after completion. Real speech/navigation verification remains pending; the specific reason for the earlier live failures is not established solely by these synthetic checks.
