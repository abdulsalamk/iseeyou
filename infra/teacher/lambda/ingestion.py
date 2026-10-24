"""Single-device pilot API. No AWS credentials are distributed to the phone."""
import base64
import hashlib
import hmac
import json
import os
import re
import time
import uuid
from datetime import datetime, timezone


def clients():
    import boto3
    from botocore.config import Config
    return (boto3.client('s3', endpoint_url='https://s3.' + os.environ.get('AWS_REGION', 'eu-west-2') + '.amazonaws.com', config=Config(signature_version='s3v4')),
            boto3.client('dynamodb'))


def reply(code, doc):
    return {'statusCode': code, 'headers': {'content-type': 'application/json', 'cache-control': 'no-store'},
            'body': json.dumps(doc)}


def start_workflow(arn, name, payload):
    import boto3
    return boto3.client('stepfunctions').start_execution(stateMachineArn=arn, name=name, input=json.dumps(payload))


def handler(event, context):
    token = event.get('headers', {}).get('authorization', '')
    if not token.startswith('Bearer ') or not hmac.compare_digest(
            hashlib.sha256(token[7:].encode()).hexdigest(), os.environ['TOKEN_HASH']):
        return reply(401, {'error': 'unauthorized'})
    s3, db = clients()
    table, bucket = os.environ['TABLE'], os.environ['BUCKET']
    method = event.get('requestContext', {}).get('http', {}).get('method')
    path = event.get('rawPath', '')
    try:
        if method == 'POST' and path == '/samples':
            body = event.get('body', '{}')
            if event.get('isBase64Encoded'):
                body = base64.b64decode(body).decode()
            if len(body) > 64000:
                return reply(413, {'error': 'manifest_too_large'})
            doc = json.loads(body)
            from teacher import validate_manifest
            sample = str(uuid.UUID(doc['sample_id']))
            image_key = f'raw/images/{sample}.jpg'
            doc.update(image_key=image_key, schema_version=1)
            session_id = doc.get('session_id')
            if session_id is not None and str(uuid.UUID(session_id)) != session_id:
                raise ValueError('invalid_session_id')
            clip_frames = doc.get('clip_frames', [])
            if not isinstance(clip_frames, list) or len(clip_frames) not in (0, 3):
                raise ValueError('invalid_clip_frames')
            frame_images = []
            for index, frame in enumerate(clip_frames):
                if not isinstance(frame, dict):
                    raise ValueError('invalid_frame')
                frame.update(image_key=image_key if index == 0 else f'raw/frames/{sample}-{index}.jpg')
                frame_images.append(frame)
            if frame_images and (frame_images[0].get('frame_id') != doc.get('frame_id')
                    or frame_images[0].get('image_size') != doc.get('image_size')
                    or frame_images[0].get('image_sha256') != doc.get('image_sha256')):
                raise ValueError('primary_frame_mismatch')
            doc['frame_images'] = frame_images
            validate_manifest(doc)
            for field, maximum in [('image_size', 3000000), ('clip_size', 6000000)]:
                if type(doc.get(field)) is not int or not 0 < doc[field] <= maximum:
                    raise ValueError('invalid_media_size')
            for field in ('image_sha256', 'clip_sha256'):
                if not re.fullmatch(r'[A-Za-z0-9+/]{43}=', doc.get(field, '')):
                    raise ValueError('invalid_checksum')
            if not 0 < float(doc.get('duration_seconds', 0)) <= 5:
                raise ValueError('clip_duration_limit')
            existing = db.get_item(TableName=table, Key={'id': {'S': 'sample#' + sample}}, ConsistentRead=True).get('Item')
            if existing:
                prior = json.loads(existing['doc']['S'])
                if any(doc.get(k) != prior.get(k) for k in ('image_sha256', 'clip_sha256', 'image_size', 'clip_size')):
                    return reply(409, {'error': 'sample_content_changed'})
                if prior['expires_at'] < time.time():
                    return reply(410, {'error': 'sample_expired'})
                doc = prior
            else:
                # New tickets consume a daily slot; identical retries reuse the ticket.
                day = datetime.now(timezone.utc).strftime('%Y-%m-%d')
                db.update_item(TableName=table, Key={'id': {'S': 'budget#' + day}},
                               UpdateExpression='SET expires_at = :ttl ADD used_count :one',
                               ConditionExpression='attribute_not_exists(used_count) OR used_count < :maximum',
                               ExpressionAttributeValues={':ttl': {'N': str(int(time.time()) + 172800)},
                                 ':one': {'N': '1'}, ':maximum': {'N': '50'}})
                doc['clip_key'] = f'raw/clips/{sample}.mp4'
                doc['expires_at'] = int(time.time()) + 86400
                item = {'id': {'S': 'sample#' + sample}, 'doc': {'S': json.dumps(doc)},
                        'expires_at': {'N': str(doc['expires_at'])}}
                if session_id:
                    item['session_id'] = {'S': session_id}
                db.put_item(TableName=table, Item=item,
                            ConditionExpression='attribute_not_exists(id)')
            def upload(key, size, checksum, kind):
                headers = {'Content-Type': kind, 'x-amz-server-side-encryption': 'AES256',
                           'x-amz-checksum-sha256': checksum}
                url = s3.generate_presigned_url('put_object', Params={'Bucket': bucket, 'Key': key,
                    'ContentType': kind, 'ContentLength': size, 'ChecksumSHA256': checksum,
                    'ServerSideEncryption': 'AES256', 'IfNoneMatch': '*'}, ExpiresIn=900)
                headers['If-None-Match'] = '*'
                return {'url': url, 'headers': headers}
            frame_uploads = [upload(frame['image_key'], frame['image_size'], frame['image_sha256'], 'image/jpeg')
                             for frame in doc.get('frame_images', [])[1:]]
            return reply(201, {'sample_id': sample,
                'image': upload(image_key, doc['image_size'], doc['image_sha256'], 'image/jpeg'),
                'clip': upload(doc['clip_key'], doc['clip_size'], doc['clip_sha256'], 'video/mp4'),
                'frames': frame_uploads})
        session_match = re.fullmatch(r'/sessions/([0-9a-f-]{36})(/complete)?', path)
        if session_match:
            session_id = str(uuid.UUID(session_match[1]))
            key = 'session#' + session_id
            if method == 'POST' and session_match[2]:
                body = event.get('body', '{}')
                if event.get('isBase64Encoded'):
                    body = base64.b64decode(body).decode()
                if len(body) > 16000:
                    return reply(413, {'error': 'session_too_large'})
                request = json.loads(body)
                if not isinstance(request, dict):
                    raise ValueError('invalid_session_request')
                sample_count = request.get('sample_count', 0)
                if type(sample_count) is not int or not 0 <= sample_count <= 2000:
                    raise ValueError('invalid_session_sample_count')
                record = {'id': {'S': key}, 'session_id': {'S': session_id},
                          'expected_samples': {'N': str(sample_count)}, 'status': {'S': 'closed'},
                          'expires_at': {'N': str(int(time.time()) + 30 * 86400)}}
                try:
                    db.put_item(TableName=table, Item=record, ConditionExpression='attribute_not_exists(id)')
                except Exception as exc:
                    if getattr(exc, 'response', {}).get('Error', {}).get('Code') != 'ConditionalCheckFailedException':
                        raise
                    prior = db.get_item(TableName=table, Key={'id': {'S': key}}, ConsistentRead=True).get('Item', {})
                    if int(prior.get('expected_samples', {}).get('N', '0')) != sample_count:
                        return reply(409, {'error': 'session_content_changed'})
                current = db.get_item(TableName=table, Key={'id': {'S': key}}, ConsistentRead=True).get('Item', {})
                current_status = current.get('status', {}).get('S', 'closed')
                if current_status not in ('closed', 'processing_queued'):
                    return reply(202, {'session_id': session_id, 'status': current_status})
                if sample_count == 0:
                    db.update_item(TableName=table, Key={'id': {'S': key}}, UpdateExpression='SET #s = :done',
                                   ExpressionAttributeNames={'#s': 'status'}, ExpressionAttributeValues={':done': {'S': 'no_samples'}})
                    return reply(200, {'session_id': session_id, 'status': 'no_samples'})
                workflow = os.environ.get('WORKFLOW_ARN')
                if not workflow:
                    raise RuntimeError('Session workflow is not configured')
                try:
                    start_workflow(workflow, session_id, {'session_id': session_id, 'attempt': 0})
                except Exception as exc:
                    if getattr(exc, 'response', {}).get('Error', {}).get('Code') != 'ExecutionAlreadyExists':
                        raise
                try:
                    db.update_item(TableName=table, Key={'id': {'S': key}}, UpdateExpression='SET #s = :queued',
                        ConditionExpression='#s = :closed OR #s = :queued',
                        ExpressionAttributeNames={'#s': 'status'},
                        ExpressionAttributeValues={':queued': {'S': 'processing_queued'}, ':closed': {'S': 'closed'}})
                except Exception as exc:
                    if getattr(exc, 'response', {}).get('Error', {}).get('Code') != 'ConditionalCheckFailedException':
                        raise
                return reply(202, {'session_id': session_id, 'status': 'processing_queued'})
            if method == 'GET' and not session_match[2]:
                item = db.get_item(TableName=table, Key={'id': {'S': key}}, ConsistentRead=True).get('Item')
                if not item:
                    return reply(404, {'error': 'session_not_found'})
                status = item.get('status', {}).get('S', 'closed')
                job = item.get('training_job', {}).get('S')
                if job:
                    import boto3
                    detail = boto3.client('sagemaker').describe_training_job(TrainingJobName=job)
                    sm_status = detail.get('TrainingJobStatus', '')
                    status = {'InProgress': 'training_running', 'Completed': 'training_complete',
                              'Failed': 'training_failed', 'Stopping': 'training_stopping',
                              'Stopped': 'training_stopped'}.get(sm_status, status)
                return reply(200, {'session_id': session_id, 'status': status, 'training_job': job,
                                   'model_uri': item.get('model_uri', {}).get('S'),
                                   'evaluation_status': item.get('evaluation_status', {}).get('S')})
            return reply(405, {'error': 'method_not_allowed'})
        if method == 'GET' and path == '/models/latest':
            latest = db.get_item(TableName=table, Key={'id': {'S': 'model-release#latest'}}, ConsistentRead=True).get('Item')
            if not latest:
                return reply(200, {'status': 'no_update'})
            version = latest.get('version', {}).get('S', '')
            release_key = latest.get('release_key', {}).get('S', '')
            if (not re.fullmatch(r'[A-Za-z0-9-]{1,80}', version)
                    or release_key != f'learning/releases/{version}/release.json'):
                raise ValueError('invalid_model_release_pointer')
            envelope = json.loads(s3.get_object(Bucket=bucket, Key=release_key)['Body'].read(100001))
            payload = json.loads(base64.b64decode(envelope['payload'], validate=True))
            files = payload.get('files')
            if payload.get('schema_version') != 1 or payload.get('version') != version or not isinstance(files, list) or not 1 <= len(files) <= 64:
                raise ValueError('invalid_model_release_manifest')
            total, downloads = 0, []
            for entry in files:
                relative = entry.get('path', '')
                parts = relative.split('/') if isinstance(relative, str) else []
                size, digest = entry.get('size'), entry.get('sha256')
                if (not parts or len(parts) > 12 or any(not re.fullmatch(r'[A-Za-z0-9_.-]{1,120}', part) or part in ('.', '..') for part in parts)
                        or type(size) is not int or not 0 < size <= 100_000_000 or not re.fullmatch(r'[0-9a-f]{64}', str(digest))):
                    raise ValueError('invalid_model_file_entry')
                total += size
                if total > 100_000_000:
                    raise ValueError('model_release_too_large')
                object_key = f'learning/releases/{version}/candidate.mlpackage/{relative}'
                url = s3.generate_presigned_url('get_object', Params={'Bucket': bucket, 'Key': object_key}, ExpiresIn=900)
                downloads.append({'path': relative, 'size': size, 'sha256': digest, 'url': url})
            return reply(200, {'status': 'available', 'version': version, 'release': envelope, 'files': downloads})
        feedback_match = re.fullmatch(r'/models/([A-Za-z0-9-]{1,80})/feedback', path)
        if method == 'POST' and feedback_match:
            version = feedback_match[1]
            release = db.get_item(TableName=table, Key={'id': {'S': 'model-release#' + version}}, ConsistentRead=True).get('Item')
            if not release:
                return reply(404, {'error': 'model_release_not_found'})
            body = event.get('body', '{}')
            if event.get('isBase64Encoded'):
                body = base64.b64decode(body).decode()
            if len(body) > 4096:
                return reply(413, {'error': 'feedback_too_large'})
            report = json.loads(body)
            actions = {'staged', 'activated', 'rollback', 'download_failed', 'activation_failed'}
            if not isinstance(report, dict) or report.get('action') not in actions:
                return reply(400, {'error': 'invalid_feedback'})
            active = report.get('active_model', '')
            app_version = report.get('app_version', '')
            error_code = report.get('error_code', '')
            if (not isinstance(active, str) or len(active) > 80 or not isinstance(app_version, str) or len(app_version) > 80
                    or error_code not in ('', 'download', 'signature', 'checksum', 'compile', 'compatibility', 'unknown')):
                return reply(400, {'error': 'invalid_feedback'})
            now = int(time.time())
            item = {'id': {'S': 'model-feedback#' + uuid.uuid4().hex}, 'version': {'S': version},
                    'action': {'S': report['action']}, 'active_model': {'S': active},
                    'app_version': {'S': app_version}, 'error_code': {'S': error_code},
                    'created_at': {'S': datetime.now(timezone.utc).isoformat()}, 'expires_at': {'N': str(now + 180 * 86400)}}
            db.put_item(TableName=table, Item=item)
            return reply(202, {'accepted': True})
        match = re.fullmatch(r'/samples/([0-9a-f-]{36})(/complete)?', path)
        if not match:
            return reply(404, {'error': 'unknown_route'})
        sample = str(uuid.UUID(match[1]))
        item = db.get_item(TableName=table, Key={'id': {'S': 'sample#' + sample}}, ConsistentRead=True).get('Item')
        if not item:
            return reply(404, {'error': 'sample_not_found'})
        doc = json.loads(item['doc']['S'])
        if int(doc['expires_at']) < time.time():
            return reply(410, {'error': 'sample_expired'})
        manifest_key = f'raw/manifests/{sample}.json'
        if method == 'POST' and match[2]:
            for media in ('image', 'clip'):
                head = s3.head_object(Bucket=bucket, Key=doc[media + '_key'], ChecksumMode='ENABLED')
                if head['ContentLength'] != doc[media + '_size'] or head.get('ChecksumSHA256') != doc[media + '_sha256']:
                    return reply(409, {'error': 'upload_not_verified'})
                doc[media + '_version'] = head['VersionId']
            for index, frame in enumerate(doc.get('frame_images', [])[1:], start=1):
                head = s3.head_object(Bucket=bucket, Key=frame['image_key'], ChecksumMode='ENABLED')
                if head['ContentLength'] != frame['image_size'] or head.get('ChecksumSHA256') != frame['image_sha256']:
                    return reply(409, {'error': 'frame_upload_not_verified'})
                frame['image_version'] = head['VersionId']
            if doc.get('frame_images'):
                doc['frame_images'][0]['image_version'] = doc['image_version']
            # A deterministic key and conditional put make completing the same upload idempotent.
            try:
                s3.put_object(Bucket=bucket, Key=manifest_key, Body=json.dumps(doc).encode(),
                              ContentType='application/json', ServerSideEncryption='AES256', IfNoneMatch='*')
            except Exception as exc:
                if getattr(exc, 'response', {}).get('Error', {}).get('Code') != 'PreconditionFailed':
                    raise
            return reply(202, {'sample_id': sample, 'status': 'queued'})
        if method == 'GET' and not match[2]:
            try:
                version = s3.head_object(Bucket=bucket, Key=manifest_key)['VersionId']
            except Exception as exc:
                if getattr(exc, 'response', {}).get('Error', {}).get('Code') in ('404', 'NoSuchKey', 'NotFound'):
                    return reply(200, {'status': 'awaiting_upload'})
                raise
            digest = hashlib.sha256((manifest_key + ':' + version).encode()).hexdigest()
            try:
                result = json.loads(s3.get_object(Bucket=bucket, Key='candidates/' + digest + '.json')['Body'].read(200000))
            except Exception as exc:
                if getattr(exc, 'response', {}).get('Error', {}).get('Code') in ('404', 'NoSuchKey', 'NotFound'):
                    return reply(200, {'status': 'queued'})
                raise
            additional, detector_only, frames = set(), set(), []
            for frame in result.get('frames', [])[:3]:
                comparison = frame.get('comparison', {})
                additional.update(x for x in comparison.get('teacher_only_labels', []) if isinstance(x, str) and len(x) <= 100)
                detector_only.update(x for x in comparison.get('detector_only_labels', []) if isinstance(x, str) and len(x) <= 100)
                proposal = frame.get('proposal', {})
                frames.append({'frame_id': str(frame.get('frame_id', ''))[:160],
                               'summary': str(proposal.get('summary', ''))[:240]})
            feedback = {'additional_labels': sorted(additional)[:30], 'detector_only_labels': sorted(detector_only)[:30],
                        'frames': frames, 'is_nova_pseudo_feedback': result.get('pseudo_label_eligible') is True}
            return reply(200, {'status': result['status'], 'training_eligible': False,
                               'teacher_model': result['teacher_model'], 'feedback': feedback})
        return reply(405, {'error': 'method_not_allowed'})
    except (ValueError, KeyError, TypeError):
        return reply(400, {'error': 'invalid_request'})
    except Exception as exc:
        code = getattr(exc, 'response', {}).get('Error', {}).get('Code', '')
        if code == 'ConditionalCheckFailedException':
            return reply(429, {'error': 'daily_budget_or_duplicate_sample'})
        print(json.dumps({'failure_type': type(exc).__name__, 'service_code': code}))
        return reply(503, {'error': 'temporarily_unavailable'})
