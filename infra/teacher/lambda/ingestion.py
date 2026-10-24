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
                db.put_item(TableName=table, Item={'id': {'S': 'sample#' + sample},
                            'doc': {'S': json.dumps(doc)}, 'expires_at': {'N': str(doc['expires_at'])}},
                            ConditionExpression='attribute_not_exists(id)')
            def upload(key, size, checksum, kind):
                headers = {'Content-Type': kind, 'x-amz-server-side-encryption': 'AES256',
                           'x-amz-checksum-sha256': checksum}
                url = s3.generate_presigned_url('put_object', Params={'Bucket': bucket, 'Key': key,
                    'ContentType': kind, 'ContentLength': size, 'ChecksumSHA256': checksum,
                    'ServerSideEncryption': 'AES256', 'IfNoneMatch': '*'}, ExpiresIn=900)
                headers['If-None-Match'] = '*'
                return {'url': url, 'headers': headers}
            return reply(201, {'sample_id': sample,
                'image': upload(image_key, doc['image_size'], doc['image_sha256'], 'image/jpeg'),
                'clip': upload(doc['clip_key'], doc['clip_size'], doc['clip_sha256'], 'video/mp4')})
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
            return reply(200, {'status': result['status'], 'training_eligible': False,
                               'teacher_model': result['teacher_model']})
        return reply(405, {'error': 'method_not_allowed'})
    except (ValueError, KeyError, TypeError):
        return reply(400, {'error': 'invalid_request'})
    except Exception as exc:
        code = getattr(exc, 'response', {}).get('Error', {}).get('Code', '')
        if code == 'ConditionalCheckFailedException':
            return reply(429, {'error': 'daily_budget_or_duplicate_sample'})
        print(json.dumps({'failure_type': type(exc).__name__, 'service_code': code}))
        return reply(503, {'error': 'temporarily_unavailable'})
