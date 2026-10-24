"""Nightly inventory only: never treats mock/proposed labels as a verified dataset."""
import json
import os
from datetime import datetime, timezone


def handler(event, context):
    import boto3
    s3 = boto3.client('s3')
    bucket = os.environ['BUCKET']
    keys = []
    truncated = False
    for page in s3.get_paginator('list_objects_v2').paginate(Bucket=bucket, Prefix='candidates/'):
        for item in page.get('Contents', []):
            if len(keys) >= 1000:
                truncated = True
                break
            keys.append({'key': item['Key'], 'etag': item['ETag']})
        if truncated:
            break
    now = datetime.now(timezone.utc)
    report = {'schema_version': 1, 'reviewed_at': now.isoformat(), 'candidates': keys,
              'inventory_truncated': truncated, 'status': 'inventory_only',
              'training': 'skipped', 'reason': 'No spatially verified dataset and held-out benchmark configured',
              'model_promoted': False}
    key = 'reviews/' + now.strftime('%Y-%m-%d/') + context.aws_request_id + '.json'
    s3.put_object(Bucket=bucket, Key=key, Body=json.dumps(report).encode(),
                  ContentType='application/json', ServerSideEncryption='AES256')
    return {'review_key': key, 'candidate_count': len(keys), 'training': 'skipped', 'model_promoted': False}
