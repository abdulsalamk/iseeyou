import hashlib
import importlib.util
import json
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

root = Path(__file__).parents[2] / 'infra/teacher/lambda'
for name in ('teacher', 'ingestion'):
    spec = importlib.util.spec_from_file_location(name, root / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
ingestion = sys.modules['ingestion']

class IngestionTests(unittest.TestCase):
    @patch.dict(os.environ, {'TOKEN_HASH': hashlib.sha256(b'test-token').hexdigest()})
    @patch.object(ingestion, 'clients')
    def test_unauthorized_cannot_touch_storage(self, clients):
        self.assertEqual(ingestion.handler({'headers': {'authorization': 'Bearer wrong'}}, None)['statusCode'], 401)
        clients.assert_not_called()

    @patch.dict(os.environ, {'TOKEN_HASH': hashlib.sha256(b'test-token').hexdigest(), 'TABLE': 'table', 'BUCKET': 'bucket'})
    @patch.object(ingestion, 'clients')
    def test_invalid_consent_never_issues_upload(self, clients):
        s3, db = Mock(), Mock(); clients.return_value = s3, db
        event = {'headers': {'authorization': 'Bearer test-token'}, 'rawPath': '/samples',
                 'requestContext': {'http': {'method': 'POST'}},
                 'body': json.dumps({'sample_id': '00000000-0000-0000-0000-000000000001', 'consent': False})}
        self.assertEqual(ingestion.handler(event, None)['statusCode'], 400)
        db.put_item.assert_not_called(); s3.generate_presigned_url.assert_not_called()

    @patch.dict(os.environ, {'TOKEN_HASH': hashlib.sha256(b'test-token').hexdigest(), 'TABLE': 'table', 'BUCKET': 'bucket'})
    @patch.object(ingestion, 'clients')
    def test_completion_rejects_checksum_mismatch(self, clients):
        s3, db = Mock(), Mock(); clients.return_value = s3, db
        db.get_item.return_value = {'Item': {'doc': {'S': json.dumps({'expires_at': 9999999999,
            'image_key': 'raw/images/a.jpg', 'image_size': 10, 'image_sha256': 'expected'})}}}
        s3.head_object.return_value = {'ContentLength': 10, 'ChecksumSHA256': 'wrong'}
        event = {'headers': {'authorization': 'Bearer test-token'},
                 'rawPath': '/samples/00000000-0000-0000-0000-000000000001/complete',
                 'requestContext': {'http': {'method': 'POST'}}}
        self.assertEqual(ingestion.handler(event, None)['statusCode'], 409)
        s3.put_object.assert_not_called()

if __name__ == '__main__': unittest.main()
