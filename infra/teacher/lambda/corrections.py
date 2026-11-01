"""Correction intake only. Never invokes Nova, training, or model promotion."""
import base64
import hashlib
import json
import math
import re
import time
import uuid
from datetime import datetime, timezone


def validate(doc):
    if not isinstance(doc, dict) or type(doc.get('schemaVersion')) is not int or doc.get('schemaVersion') != 1:
        raise ValueError('correction_schema')
    identifier = str(uuid.UUID(doc['id'])).lower()
    prefix = f'corrections/{identifier}/'
    if doc.get('frameObjectKey') != prefix + 'frame.jpg' or doc.get('clipObjectKey') is not None:
        raise ValueError('correction_media_link')
    if doc.get('processingState') != 'awaiting_validation':
        raise ValueError('correction_state')
    label, transcript = doc.get('correctedLabel'), doc.get('transcriptText')
    if not isinstance(label, str) or not 1 <= len(label) <= 60 or not isinstance(transcript, str) or not 1 <= len(transcript) <= 300:
        raise ValueError('correction_text')
    normalized = ' '.join(re.sub(r'[,.;:!?]', ' ', transcript.lower()).split())
    if not normalized.startswith('correction this is '):
        raise ValueError('correction_command')
    proposed = normalized[len('correction this is '):].strip()
    proposed = re.sub(r'^[^\w]+|[^\w]+$', '', proposed)
    for article in ('a ', 'an ', 'the '):
        if proposed.startswith(article):
            proposed = proposed[len(article):]
            break
    if proposed != label or len(label.split()) > 6 or not all(c.isalpha() or c in ' -' for c in label):
        raise ValueError('correction_label_mismatch')
    if not isinstance(doc.get('modelVersion'), str) or not 1 <= len(doc['modelVersion']) <= 100:
        raise ValueError('correction_model')
    if doc.get('source') not in ('iPhone camera', 'Meta glasses'):
        raise ValueError('correction_source')
    if not re.fullmatch(r'[0-9a-f]{64}', str(doc.get('frameSHA256', ''))):
        raise ValueError('correction_checksum')
    dates = [datetime.fromisoformat(doc[k].replace('Z', '+00:00')) for k in ('capturedAt', 'triggeredAt')]
    if any(d.tzinfo is None for d in dates) or not 0 <= (dates[1] - dates[0]).total_seconds() <= 12:
        raise ValueError('correction_timing')
    if not -60 <= time.time() - dates[0].timestamp() < 86400:
        raise ValueError('correction_expired')
    detection = doc.get('originalDetection')
    if not isinstance(detection, dict) or not isinstance(detection.get('label'), str) or not 1 <= len(detection['label']) <= 100:
        raise ValueError('correction_detection')
    confidence = detection.get('confidence')
    if type(confidence) not in (float, int) or not math.isfinite(confidence) or not 0 <= confidence <= 1:
        raise ValueError('correction_confidence')
    box = detection.get('boundingBox', {})
    values = [box.get(k) for k in ('x', 'y', 'width', 'height')]
    if any(type(v) not in (float, int) or not math.isfinite(v) or not 0 <= v <= 1 for v in values):
        raise ValueError('correction_box')
    x, y, w, h = values
    if w <= 0 or h <= 0 or x + w > 1.000001 or y + h > 1.000001:
        raise ValueError('correction_box')
    return identifier


def handle(method, path, body, s3, db, bucket, table):
    if path == '/corrections' and method == 'POST':
        doc, size = body['correction'], body['image_size']
        identifier = validate(doc)
        if type(size) is not int or not 0 < size <= 3000000:
            raise ValueError('correction_size')
        payload = json.dumps({'correction': doc, 'image_size': size}, sort_keys=True, separators=(',', ':'))
        fingerprint = hashlib.sha256(payload.encode()).hexdigest()
        key = {'id': {'S': 'correction#' + identifier}}
        old = db.get_item(TableName=table, Key=key, ConsistentRead=True).get('Item')
        if old:
            if old['fingerprint']['S'] != fingerprint:
                return 409, {'error': 'correction_content_changed'}
            if int(old['expires_at']['N']) < time.time():
                return 410, {'error': 'correction_expired'}
        else:
            day = datetime.now(timezone.utc).strftime('%Y-%m-%d')
            db.update_item(TableName=table, Key={'id': {'S': 'correction-budget#' + day}},
                UpdateExpression='SET expires_at = :ttl ADD used_count :one',
                ConditionExpression='attribute_not_exists(used_count) OR used_count < :maximum',
                ExpressionAttributeValues={':ttl': {'N': str(int(time.time()) + 172800)}, ':one': {'N': '1'}, ':maximum': {'N': '50'}})
            db.put_item(TableName=table, Item={**key, 'doc': {'S': payload}, 'fingerprint': {'S': fingerprint},
                'expires_at': {'N': str(int(time.time()) + 86400)}}, ConditionExpression='attribute_not_exists(id)')
        checksum = base64.b64encode(bytes.fromhex(doc['frameSHA256'])).decode()
        headers = {'Content-Type': 'image/jpeg', 'x-amz-server-side-encryption': 'AES256',
                   'x-amz-checksum-sha256': checksum, 'If-None-Match': '*'}
        url = s3.generate_presigned_url('put_object', Params={'Bucket': bucket, 'Key': doc['frameObjectKey'],
            'ContentLength': size, 'ContentType': 'image/jpeg', 'ServerSideEncryption': 'AES256',
            'ChecksumSHA256': checksum, 'IfNoneMatch': '*'}, ExpiresIn=900)
        return 201, {'url': url, 'headers': headers}
    match = re.fullmatch(r'/corrections/([0-9a-f-]{36})/complete', path)
    if method == 'POST' and match:
        identifier = str(uuid.UUID(match[1]))
        old = db.get_item(TableName=table, Key={'id': {'S': 'correction#' + identifier}}, ConsistentRead=True).get('Item')
        if not old:
            return 404, {'error': 'correction_missing'}
        if int(old['expires_at']['N']) < time.time():
            return 410, {'error': 'correction_expired'}
        payload = json.loads(old['doc']['S']); doc = payload['correction']
        head = s3.head_object(Bucket=bucket, Key=doc['frameObjectKey'], ChecksumMode='ENABLED')
        if head.get('ContentLength') != payload['image_size'] or head.get('ChecksumSHA256') != base64.b64encode(bytes.fromhex(doc['frameSHA256'])).decode():
            raise ValueError('correction_media_mismatch')
        data = json.dumps(doc, sort_keys=True, separators=(',', ':')).encode()
        object_key = f'corrections/{identifier}/correction.json'
        try:
            s3.put_object(Bucket=bucket, Key=object_key, Body=data, ContentType='application/json', ServerSideEncryption='AES256', IfNoneMatch='*')
        except Exception as exc:
            if getattr(exc, 'response', {}).get('Error', {}).get('Code') not in ('PreconditionFailed', '412'):
                raise
            existing = s3.get_object(Bucket=bucket, Key=object_key)['Body'].read(16001)
            if existing != data:
                return 409, {'error': 'correction_metadata_changed'}
        return 200, {'id': identifier, 'status': 'awaiting_validation', 'training_eligible': False}
    return 404, {'error': 'not_found'}
