# Silent vision teacher — first server-side slice of issue 3

Private versioned S3 images and manifests → encrypted SQS → Lambda → regional Bedrock Converse → proposed comparisons in S3. No live app callbacks, speech, automatic training, or model promotion.

Deploy locally with `AWS_PROFILE=abdul terraform init -backend-config=backend.hcl`, `terraform plan`, then `terraform apply` in this directory. State is separate from bootstrap. The GitHub bootstrap role intentionally cannot deploy these resources.

The initial teacher is on-demand Amazon Nova Lite in London. The model ID is configurable; changing provider may require different invocation permissions or an inference profile. No cross-region inference is configured.

## Pilot uploads

The manual uploader uses the local AWS profile, requires explicit `--consent`, checks the account, uploads the image first, then the manifest, and pins both versions. It does not capture video or integrate with the iPhone. Keep the local original until confirmed upload; the uploader never deletes it.

Run from the repository root:

```sh
python3 scripts/aws/upload_teacher_sample.py --profile abdul --consent --image sample.png --metadata sample.json
```

Metadata:

```json
{"frame_id":"example-1","captured_at":"2026-10-24T00:00:00Z","model_version":"yolo11n","predictions":[{"label":"cabinet","confidence":0.8,"box":[0.1,0.1,0.9,0.9]}]}
```

Boxes use normalized xyxy coordinates. At most 100 predictions, a 64 KB manifest, and a 3 MB JPEG/PNG. Only manifest creation triggers processing. Results preserve source IDs, versions, original predictions, teacher proposals and token usage. Label-set differences are lexical candidates, not proven errors; synonyms, instance matching and spatial validation remain future work.

Partial queue failures retry up to three deliveries, then reach a dead-letter queue. Completed writes deduplicate retries; a crash between inference and writing can still repeat one inference. Concurrency is limited to two; this limits parallelism, not total daily cost. This pilot has no automatic camera uploads. Do not start bulk ingestion until per-user authentication and daily sample/token budgets exist.

Raw media expires after seven days; candidates after thirty; old versions after one day. Versioned delete markers are not permanent deletion: erase all versions when satisfying a deletion request. Logs contain error types and queue IDs, not images or model text. A CloudWatch dead-letter alarm exists but has no notification subscription yet.

## Remaining issue 3 work

- Opt-in bounded iPhone capture/queue and authenticated per-user upload issuance (no AWS credentials in the app).
- Daily upload/inference budgets and retention/deletion controls exposed to users.
- Semantic and spatial discrepancy validation; curated dataset and historical replay.
- EventBridge/Step Functions nightly review, conditional GPU training, held-out evaluation.
- Signed staged CoreML delivery, promotion gates and rollback.

A passing pipeline smoke test demonstrates connectivity only, not recognition accuracy or training readiness.

## Deployment verification

Terraform deployed the storage, queue, Lambda and monitoring in London. Six focused tests passed. A synthetic drawing upload reached Lambda and attempted Bedrock Converse; AWS returned `ValidationException: Operation not allowed`. The model availability API reports `authorizationStatus: NOT_AUTHORIZED` for Nova Lite, Nova Pro and Nova 2 Lite in this account/region. This is not a successful teacher inference.

Queue consumption is paused by default (`model_access_ready=false`) to avoid repeated rejected calls. Once the account is authorized for the selected model, set this variable to true, apply, and let the retained synthetic manifest retry. Verify its proposed result in S3 before enabling any real uploads. Do not upload a duplicate just to retry.

References: [Bedrock model access](https://docs.aws.amazon.com/bedrock/latest/userguide/model-access.html), [Converse images](https://docs.aws.amazon.com/bedrock/latest/userguide/conversation-inference.html), [SQS partial failures](https://docs.aws.amazon.com/lambda/latest/dg/services-sqs-errorhandling.html).
