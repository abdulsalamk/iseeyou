"""Session-end pseudo-label aggregation and bounded SageMaker YOLO job launch."""
import hashlib
import json
import os
import re
import time
from urllib.parse import quote_plus

from budget import reserve_gbp, release_gbp

COCO = ['person','bicycle','car','motorcycle','airplane','bus','train','truck','boat','traffic light','fire hydrant','stop sign','parking meter','bench','bird','cat','dog','horse','sheep','cow','elephant','bear','zebra','giraffe','backpack','umbrella','handbag','tie','suitcase','frisbee','skis','snowboard','sports ball','kite','baseball bat','baseball glove','skateboard','surfboard','tennis racket','bottle','wine glass','cup','fork','knife','spoon','bowl','banana','apple','sandwich','orange','broccoli','carrot','hot dog','pizza','donut','cake','chair','couch','potted plant','bed','dining table','toilet','tv','laptop','mouse','remote','keyboard','cell phone','microwave','oven','toaster','sink','refrigerator','book','clock','vase','scissors','teddy bear','hair drier','toothbrush']


def clients():
    import boto3
    return boto3.client('s3'), boto3.client('dynamodb'), boto3.client('sagemaker')


def split_for_group(group):
    bucket = int(hashlib.sha256(group.encode()).hexdigest()[:8], 16) % 10
    return 'train' if bucket < 7 else ('val' if bucket < 9 else 'test')


def build_training_manifest(results):
    """Build a stable session-grouped YOLO manifest and enforce coverage gates."""
    rows, groups = [], {}
    for result in results:
        if result.get('status') != 'pseudo_labeled' or result.get('pseudo_label_eligible') is not True:
            continue
        source = result.get('source', {})
        group = source.get('session_id') or source.get('sample_id')
        if not isinstance(group, str) or not group:
            continue
        for frame in result.get('frames', []):
            image_key, image_version = frame.get('image_key'), frame.get('image_version')
            objects = frame.get('proposal', {}).get('objects', [])
            if not image_key or not image_version or not objects:
                continue
            valid = []
            for obj in objects:
                box, label = obj.get('box'), obj.get('label')
                if (isinstance(label, str) and label.strip() and isinstance(box, list) and len(box) == 4
                        and all(type(x) in (int, float) and 0 <= x <= 1 for x in box)
                        and box[0] < box[2] and box[1] < box[3]):
                    valid.append({'label': label.strip(), 'box': box})
            if valid:
                rows.append({'frame_id': frame['frame_id'], 'group': group, 'split': split_for_group(group),
                             'image_key': image_key, 'image_version': image_version, 'objects': valid})
                groups[group] = True
    if not rows:
        return None, 'no_spatial_pseudo_labels'
    canonical = {name.casefold(): name for name in COCO}
    for row in rows:
        for obj in row['objects']:
            obj['label'] = canonical.get(obj['label'].casefold(), obj['label'].strip().casefold())
    extra = sorted({obj['label'] for row in rows for obj in row['objects']
                    if obj['label'].casefold() not in canonical}, key=str.casefold)
    names = COCO + extra
    counts = {split: {name: set() for name in names} for split in ('train', 'val', 'test')}
    observed_names = {obj['label'] for row in rows for obj in row['objects']}
    for row in rows:
        for label in {obj['label'] for obj in row['objects']}:
            match = next((name for name in names if name.casefold() == label.casefold()), None)
            if match:
                counts[row['split']][match].add(row['frame_id'])
    failures = []
    for name in observed_names:
        minimum = {'train': 20, 'val': 5, 'test': 5} if name not in COCO else {'train': 5, 'val': 2, 'test': 3}
        for split, required in minimum.items():
            if len(counts[split][name]) < required:
                failures.append(f'{split}/{name}')
    if failures:
        return None, 'coverage_gate:' + ','.join(failures[:12])
    return {'schema_version': 1, 'annotation_source': 'nova_pseudo_labels', 'names': names, 'frames': rows}, None


def _update_session(db, session_id, status, **fields):
    names = {'#status': 'status'}
    values = {':status': {'S': status}}
    setters = ['#status = :status']
    for index, (key, value) in enumerate(fields.items()):
        names['#f' + str(index)] = key
        values[':v' + str(index)] = {'S': str(value)}
        setters.append('#f' + str(index) + ' = :v' + str(index))
    db.update_item(TableName=os.environ['TABLE'], Key={'id': {'S': 'session#' + session_id}},
                   UpdateExpression='SET ' + ', '.join(setters), ExpressionAttributeNames=names,
                   ExpressionAttributeValues=values)


def _candidate_for_sample(s3, bucket, sample_id):
    manifest_key = f'raw/manifests/{sample_id}.json'
    try:
        version = s3.head_object(Bucket=bucket, Key=manifest_key)['VersionId']
    except Exception:
        return None
    digest = hashlib.sha256((manifest_key + ':' + version).encode()).hexdigest()
    key = 'candidates/' + digest + '.json'
    try:
        raw = s3.get_object(Bucket=bucket, Key=key)['Body'].read(300000)
    except Exception as exc:
        if getattr(exc, 'response', {}).get('Error', {}).get('Code') in ('404', 'NoSuchKey', 'NotFound'):
            return None
        raise
    return json.loads(raw)


def _session_samples(db, table, session_id):
    paginator = db.get_paginator('query')
    samples = []
    for page in paginator.paginate(TableName=table, IndexName='session-index',
            KeyConditionExpression='#session_id = :session_id AND begins_with(#sample_id, :prefix)',
            ProjectionExpression='#sample_id',
            ExpressionAttributeNames={'#session_id': 'session_id', '#sample_id': 'id'},
            ExpressionAttributeValues={':session_id': {'S': session_id}, ':prefix': {'S': 'sample#'}}):
        samples.extend(item['id']['S'].removeprefix('sample#') for item in page.get('Items', []))
    return samples


def _dispatch_nova(s3, session_id, sample_ids):
    """Start Nova only after the session-complete API has closed this session."""
    import boto3
    bucket = os.environ['BUCKET']
    worker = os.environ['WORKER_FUNCTION']
    invoke = boto3.client('lambda')
    for sample_id in sample_ids:
        key = f'raw/manifests/{sample_id}.json'
        version = s3.head_object(Bucket=bucket, Key=key)['VersionId']
        record = {'s3': {'bucket': {'name': bucket}, 'object': {
            'key': quote_plus(key, safe='/'), 'versionId': version}}}
        invoke.invoke(FunctionName=worker, InvocationType='Event',
                      Payload=json.dumps({'direct_s3_record': record}).encode())


def _list_candidates(s3, bucket):
    rows = []
    for page in s3.get_paginator('list_objects_v2').paginate(Bucket=bucket, Prefix='candidates/'):
        for item in page.get('Contents', []):
            if len(rows) >= 10000:
                raise ValueError('Candidate inventory limit reached; refusing partial training data')
            body = s3.get_object(Bucket=bucket, Key=item['Key'])['Body'].read(500000)
            rows.append(json.loads(body))
    return rows


def handler(event, context):
    session_id = event.get('session_id', '')
    import uuid
    if str(uuid.UUID(session_id)) != session_id:
        raise ValueError('Invalid session ID')
    s3, db, sm = clients()
    table, bucket = os.environ['TABLE'], os.environ['BUCKET']
    item = db.get_item(TableName=table, Key={'id': {'S': 'session#' + session_id}}, ConsistentRead=True).get('Item')
    if not item:
        raise ValueError('Unknown session')
    attempt = int(event.get('attempt', 0))
    expected = int(item.get('expected_samples', {}).get('N', '0'))
    sample_ids = _session_samples(db, table, session_id)
    if len(sample_ids) < expected:
        if attempt < int(os.environ.get('SESSION_WAIT_ATTEMPTS', '120')):
            _update_session(db, session_id, 'waiting_for_upload_index')
            return {'session_id': session_id, 'attempt': attempt + 1, 'wait': True, 'status': 'waiting_for_upload_index'}
        _update_session(db, session_id, 'processing_timeout')
        return {'session_id': session_id, 'attempt': attempt, 'wait': False, 'status': 'processing_timeout'}
    missing = [sample for sample in sample_ids if _candidate_for_sample(s3, bucket, sample) is None]
    if missing:
        # Re-dispatch on alternate poll attempts in case an async Lambda invoke
        # was throttled or lost; the worker deduplicates completed candidates.
        if attempt % 2 == 0:
            _dispatch_nova(s3, session_id, missing)
        if attempt < int(os.environ.get('SESSION_WAIT_ATTEMPTS', '120')):
            _update_session(db, session_id, 'waiting_for_nova')
            return {'session_id': session_id, 'attempt': attempt + 1, 'wait': True, 'status': 'waiting_for_nova'}
        _update_session(db, session_id, 'processing_timeout')
        return {'session_id': session_id, 'attempt': attempt, 'wait': False, 'status': 'processing_timeout'}
    existing_status = item.get('status', {}).get('S', '')
    existing_job = item.get('training_job', {}).get('S')
    if existing_job:
        return {'session_id': session_id, 'attempt': attempt, 'wait': False, 'status': existing_status, 'training_job': existing_job}
    lock = db.get_item(TableName=table, Key={'id': {'S': 'training-lock'}}, ConsistentRead=True).get('Item')
    if lock and int(lock.get('expires_at', {}).get('N', '0')) > int(time.time()):
        active_job = lock.get('training_job', {}).get('S', '')
        try:
            current = sm.describe_training_job(TrainingJobName=active_job)
            if current.get('TrainingJobStatus') in ('InProgress', 'Stopping'):
                if attempt < int(os.environ.get('SESSION_WAIT_ATTEMPTS', '120')):
                    _update_session(db, session_id, 'waiting_for_training_slot')
                    return {'session_id': session_id, 'attempt': attempt + 1, 'wait': True, 'status': 'waiting_for_training_slot'}
                _update_session(db, session_id, 'training_slot_timeout')
                return {'session_id': session_id, 'attempt': attempt, 'wait': False, 'status': 'training_slot_timeout'}
        except Exception as exc:
            if getattr(exc, 'response', {}).get('Error', {}).get('Code') not in ('ResourceNotFound', 'ValidationException'):
                raise
        db.delete_item(TableName=table, Key={'id': {'S': 'training-lock'}},
                       ConditionExpression='training_job = :job', ExpressionAttributeValues={':job': {'S': active_job}})
    candidates = _list_candidates(s3, bucket)
    manifest, reason = build_training_manifest(candidates)
    if manifest is None:
        _update_session(db, session_id, 'awaiting_more_pseudo_labels', detail=reason)
        return {'session_id': session_id, 'attempt': attempt, 'wait': False, 'status': 'awaiting_more_pseudo_labels', 'reason': reason}
    encoded = json.dumps(manifest, separators=(',', ':'), allow_nan=False).encode()
    digest = hashlib.sha256(encoded).hexdigest()
    manifest_key = f'learning/datasets/{digest}.json'
    s3.put_object(Bucket=bucket, Key=manifest_key, Body=encoded, ContentType='application/json', ServerSideEncryption='AES256')
    job_name = 'iseeyou-yolo-' + session_id.replace('-', '')[:32]
    try:
        sm.describe_training_job(TrainingJobName=job_name)
        _update_session(db, session_id, 'training_started', training_job=job_name)
        return {'session_id': session_id, 'attempt': attempt, 'wait': False, 'status': 'training_started', 'training_job': job_name}
    except Exception as exc:
        if getattr(exc, 'response', {}).get('Error', {}).get('Code') not in ('ResourceNotFound', 'ValidationException'):
            raise
    reserve = os.environ.get('TRAIN_JOB_RESERVE_GBP', '2.00')
    if not reserve_gbp(reserve, 'sagemaker:' + job_name):
        _update_session(db, session_id, 'budget_limited')
        return {'session_id': session_id, 'attempt': attempt, 'wait': False, 'status': 'budget_limited'}
    role = os.environ['TRAINING_ROLE_ARN']
    code_uri = f"s3://{bucket}/{os.environ['TRAINING_CODE_KEY']}"
    checkpoint_uri = f"s3://{bucket}/{os.environ['BASELINE_KEY']}"
    manifest_uri = f's3://{bucket}/{manifest_key}'
    try:
        db.put_item(TableName=table, Item={'id': {'S': 'training-lock'}, 'session_id': {'S': session_id},
            'training_job': {'S': job_name}, 'expires_at': {'N': str(int(time.time()) + 6 * 3600)}},
            ConditionExpression='attribute_not_exists(id)')
        sm.create_training_job(TrainingJobName=job_name, RoleArn=role,
            AlgorithmSpecification={'TrainingImage': os.environ['TRAINING_IMAGE'], 'TrainingInputMode': 'File'},
            InputDataConfig=[{'ChannelName': 'training', 'DataSource': {'S3DataSource': {
                'S3DataType': 'S3Prefix', 'S3Uri': manifest_uri, 'S3DataDistributionType': 'FullyReplicated'}}, 'ContentType': 'application/json'}],
            OutputDataConfig={'S3OutputPath': f's3://{bucket}/learning/models/'},
            ResourceConfig={'InstanceType': os.environ.get('TRAINING_INSTANCE', 'ml.g4dn.xlarge'), 'InstanceCount': 1, 'VolumeSizeInGB': 30},
            StoppingCondition={'MaxRuntimeInSeconds': int(os.environ.get('TRAINING_MAX_RUNTIME_SECONDS', '900'))},
            HyperParameters={'sagemaker_program': 'train.py', 'sagemaker_submit_directory': code_uri,
                'manifest_uri': manifest_uri, 'baseline_uri': checkpoint_uri, 'session_id': session_id, 'job_name': job_name,
                'epochs': os.environ.get('TRAINING_EPOCHS', '10')})
    except Exception as exc:
        try:
            db.delete_item(TableName=table, Key={'id': {'S': 'training-lock'}},
                           ConditionExpression='training_job = :job', ExpressionAttributeValues={':job': {'S': job_name}})
        except Exception:
            pass
        release_gbp(reserve)
        if getattr(exc, 'response', {}).get('Error', {}).get('Code') == 'ConditionalCheckFailedException':
            return {'session_id': session_id, 'attempt': attempt + 1, 'wait': True, 'status': 'waiting_for_training_slot'}
        raise
    _update_session(db, session_id, 'training_started', training_job=job_name, dataset_sha256=digest)
    return {'session_id': session_id, 'attempt': attempt, 'wait': False, 'status': 'training_started', 'training_job': job_name}
